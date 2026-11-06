$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RuntimeRoot = Join-Path $script:RepositoryRoot 'scripts'
$script:ModulePath = Join-Path $script:RuntimeRoot 'agent-environment-reconciler.psm1'
$script:ContractPath = Join-Path $script:RuntimeRoot 'skills-catalog-contract.psm1'
$script:TestPowerShellExecutable = (Get-Process -Id $PID).Path
$script:SecondaryVolumeRoot = $null
if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
    $primary=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
    $script:SecondaryVolumeRoot=@(Get-PSDrive -PSProvider FileSystem|Where-Object{$_.Root-and-not[string]::Equals([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($_.Root)),$primary,[StringComparison]::OrdinalIgnoreCase)}|Select-Object -ExpandProperty Root -First 1)
}

Import-Module $script:ContractPath -Force
Import-Module $script:ModulePath -Force

function New-TestDesiredState {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [string[]] $SkillIds = @('alpha'),
        [hashtable] $Aliases = @{},
        [hashtable] $Resources = @{}
    )
    $files = @()
    $catalogSkills = @()
    foreach ($skillId in $SkillIds) {
        $stagedRoot = Join-Path $Root $skillId
        New-Item -ItemType Directory -Force -Path $stagedRoot | Out-Null
        $stagedPath = Join-Path $stagedRoot 'SKILL.md'
        [System.IO.File]::WriteAllText($stagedPath,"---`nname: $skillId`ndescription: test`n---`n")
        $sourceId = if ($skillId -eq 'beta') { 'source-two' } else { 'source-one' }
        $sourceRepository = if ($sourceId -eq 'source-two') { 'https://github.com/example/source-two.git' } else { 'https://github.com/example/source-one.git' }
        $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedPath).Hash.ToLowerInvariant()
        $files += [pscustomobject][ordered]@{
            skillId=$skillId; sourceId=$sourceId; sourceRepository=$sourceRepository; sourceRef='main'
            sourceCommit='0123456789abcdef0123456789abcdef01234567'; sourceVersion='test'
            sourcePath=".agents/skills/$skillId/SKILL.md"; targetPath=".agents/skills/$skillId/SKILL.md"
            sha256=$sha; stagedPath=$stagedPath
        }
        $skillEntry=$files[-1]
        foreach($relative in $Resources.Keys) {
            $resourcePath=Join-Path $stagedRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path $resourcePath) | Out-Null
            [IO.File]::WriteAllBytes($resourcePath,[byte[]]$Resources[$relative])
            $resource=$skillEntry.PSObject.Copy()
            $resource.sourcePath=".agents/skills/$skillId/$relative"
            $resource.targetPath=$resource.sourcePath
            $resource.sha256=(Get-FileHash -LiteralPath $resourcePath).Hash.ToLowerInvariant()
            $resource.stagedPath=$resourcePath
            $files+=$resource
        }
        $skillAliases = if ($Aliases.ContainsKey($skillId)) { @($Aliases[$skillId]) } else { @() }
        $catalogSkills += [pscustomobject]@{ id=$skillId; lifecycle=[pscustomobject]@{ status='active'; aliases=$skillAliases } }
    }
    foreach ($alias in @($Aliases.Keys | Where-Object { $SkillIds -notcontains $_ })) {
        $catalogSkills += [pscustomobject]@{ id=$alias; lifecycle=[pscustomobject]@{ status='removed'; aliases=@() } }
    }
    $manifestFiles = @($files | ForEach-Object {
        [pscustomobject][ordered]@{
            skillId=$_.skillId; sourceId=$_.sourceId; sourceRepository=$_.sourceRepository; sourceRef=$_.sourceRef
            sourceCommit=$_.sourceCommit; sourceVersion=$_.sourceVersion; sourcePath=$_.sourcePath
            targetPath=$_.targetPath; sha256=$_.sha256
        }
    })
    return [pscustomobject][ordered]@{
        RuntimeRoot=$script:RuntimeRoot
        Catalog=[pscustomobject]@{ skills=$catalogSkills }
        SkillIds=$SkillIds
        Files=$files
        Manifest=[pscustomobject][ordered]@{
            schemaVersion=1; catalogRepository='https://github.com/example/ai-instructions.git'
            catalogCommit='89abcdef0123456789abcdef0123456789abcdef'; catalogId='example-agent-skills'
            lockSha256=('a' * 64); files=$manifestFiles
        }
    }
}

function New-TestProjectionDesiredState {
    param([Parameter(Mandatory=$true)][string]$Root)
    $catalog=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/skills-catalog-v3.example.json')|ConvertFrom-Json
    $catalog.projections=@($catalog.projections)+@([pscustomobject][ordered]@{id='user-copilot';scope='user';root='.copilot/skills'})
    $projectionContractSha256=Get-SkillsCatalogProjectionContractSha256 -Projections $catalog.projections
    $stageRoot=Join-Path $Root 'work-with-jira';New-Item -ItemType Directory -Force -Path $stageRoot|Out-Null
    $stagePath=Join-Path $stageRoot 'SKILL.md';[IO.File]::WriteAllText($stagePath,"---`nname: work-with-jira`ndescription: projection test`n---`n",[Text.UTF8Encoding]::new($false))
    $sha=(Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $payloadBytes=[Text.UTF8Encoding]::new($false).GetBytes("skills/work-with-jira/SKILL.md`t$sha`n")
    $algorithm=[Security.Cryptography.SHA256]::Create();try{$contentSha=([BitConverter]::ToString($algorithm.ComputeHash($payloadBytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    $catalogBytes=[Text.UTF8Encoding]::new($false).GetBytes(($catalog|ConvertTo-Json -Depth 20)+"`n")
    $algorithm=[Security.Cryptography.SHA256]::Create();try{$catalogSha=([BitConverter]::ToString($algorithm.ComputeHash($catalogBytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    $lock=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/skills-catalog-lock-v3.example.json')|ConvertFrom-Json
    $lock.catalogSha256=$catalogSha;$lock.projectionContractSha256=$projectionContractSha256
    @($lock.skills|Where-Object id -eq 'work-with-jira')[0].contentSha256=$contentSha
    $lockBytes=[Text.UTF8Encoding]::new($false).GetBytes(($lock|ConvertTo-Json -Depth 20)+"`n")
    $algorithm=[Security.Cryptography.SHA256]::Create();try{$lockSha=([BitConverter]::ToString($algorithm.ComputeHash($lockBytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    $files=@();$manifestFiles=@()
    foreach($projection in @([pscustomobject]@{id='user-agents';root='.agents/skills'},[pscustomobject]@{id='user-claude';root='.claude/skills'},[pscustomobject]@{id='user-copilot';root='.copilot/skills'})){
        $target="$($projection.root)/work-with-jira/SKILL.md"
        $file=[pscustomobject][ordered]@{skillId='work-with-jira';sourceId='agent-skills';sourceRepository='https://github.com/example/agent-skills-catalog.git';sourceRef='v1.0.0';sourceCommit='0123456789abcdef0123456789abcdef01234567';sourceVersion='1.0.0';sourcePath='skills/work-with-jira/SKILL.md';targetPath=$target;sha256=$sha;stagedPath=$stagePath;projectionId=$projection.id}
        $files+=$file;$entry=$file.PSObject.Copy();$entry.PSObject.Properties.Remove('stagedPath');$manifestFiles+=$entry
    }
    $manifest=[pscustomobject][ordered]@{schemaVersion=3;catalogRepository='https://github.com/example/SyuanTsai-AI-Instructions.git';catalogCommit='0123456789abcdef0123456789abcdef01234567';catalogId='example-agent-skills-v3';lockSha256=$lockSha;projectionContractSha256=$projectionContractSha256;generation=1;projections=@('user-agents','user-claude','user-copilot');files=$manifestFiles}
    Assert-UserSkillsManagedManifestBinding -Manifest $manifest -CatalogBytes $catalogBytes -LockBytes $lockBytes -ExpectedCatalogRepository $manifest.catalogRepository -ExpectedCatalogCommit $manifest.catalogCommit|Out-Null
    [pscustomobject][ordered]@{RuntimeRoot=$script:RuntimeRoot;Catalog=$catalog;Lock=$lock;SkillIds=@('work-with-jira');Files=$files;Manifest=$manifest;LicenseWarnings=@();CatalogBytes=$catalogBytes;LockBytes=$lockBytes;ProjectionIds=$manifest.projections}
}

function Set-TestProjectionDesiredPayload {
    param([Parameter(Mandatory=$true)][object]$Desired,[Parameter(Mandatory=$true)][string]$Text)
    $stagePath=[string]$Desired.Files[0].stagedPath
    [IO.File]::WriteAllText($stagePath,$Text,[Text.UTF8Encoding]::new($false))
    $sha=(Get-FileHash -Algorithm SHA256 -LiteralPath $stagePath).Hash.ToLowerInvariant()
    foreach($file in @($Desired.Files)){$file.sha256=$sha}
    foreach($file in @($Desired.Manifest.files)){$file.sha256=$sha}
    $payloadBytes=[Text.UTF8Encoding]::new($false).GetBytes("skills/work-with-jira/SKILL.md`t$sha`n")
    $algorithm=[Security.Cryptography.SHA256]::Create();try{$contentSha=([BitConverter]::ToString($algorithm.ComputeHash($payloadBytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    @($Desired.Lock.skills|Where-Object id -eq 'work-with-jira')[0].contentSha256=$contentSha
    $Desired.LockBytes=[Text.UTF8Encoding]::new($false).GetBytes(($Desired.Lock|ConvertTo-Json -Depth 20)+"`n")
    $algorithm=[Security.Cryptography.SHA256]::Create();try{$Desired.Manifest.lockSha256=([BitConverter]::ToString($algorithm.ComputeHash([byte[]]$Desired.LockBytes))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    Assert-UserSkillsManagedManifestBinding -Manifest $Desired.Manifest -CatalogBytes ([byte[]]$Desired.CatalogBytes) -LockBytes ([byte[]]$Desired.LockBytes) -ExpectedCatalogRepository $Desired.Manifest.catalogRepository -ExpectedCatalogCommit $Desired.Manifest.catalogCommit|Out-Null
}

function New-TestRecoveryJournal {
    param(
        [Parameter(Mandatory = $true)][string] $UserHome,
        [Parameter(Mandatory = $true)][string] $BackupRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $States,
        [string] $Phase = 'mutating',
        [string] $TransactionId = ([Guid]::NewGuid().ToString('N')),
        [string] $DesiredManifestSha256 = ('a' * 64),
        [string] $DesiredInventorySha256 = ('b' * 64)
    )
    return [pscustomobject][ordered]@{
        schemaVersion=1
        transactionId=$TransactionId
        userHome=[System.IO.Path]::GetFullPath($UserHome).TrimEnd([char[]]@('\','/'))
        backupPath=$BackupRoot
        phase=$Phase
        desiredManifestSha256=$DesiredManifestSha256
        desiredInventorySha256=$DesiredInventorySha256
        states=$States
    }
}

function Assert-TestRecoveryFailureResult {
    param([Parameter(Mandatory = $true)][object] $Result)
    $Result.outcome | Should Be 'failed'
    [int]$Result.exitCode | Should Be 1
    $Result.rollbackState | Should Be 'recovery-required'
    @($Result.failed).Count | Should Be 1
    @($Result.failureDetails).Count | Should Be 1
    $detail = @($Result.failureDetails)[0]
    $detail.code | Should Be 'recovery-required'
    $detail.path | Should Be '.agents/update-agent-environment.recovery.json'
    $detail.owner | Should Be 'transaction-journal'
    $detail.destructiveChangeAllowed | Should Be $false
    @($detail.remediation).Count | Should BeGreaterThan 0
    @($Result.ownership).Count | Should Be 1
    @($Result.ownership)[0].path | Should Be '.agents/update-agent-environment.recovery.json'
    @($Result.ownership)[0].operation | Should Be 'observe'
}

function Assert-TestRecoveryConcurrentResult {
    param([Parameter(Mandatory = $true)][object] $Result)
    $Result.outcome | Should Be 'concurrent'
    [int]$Result.exitCode | Should Be 3
    $Result.rollbackState | Should Be 'not-started'
    @($Result.failed).Count | Should Be 1
    @($Result.failureDetails).Count | Should Be 0
    @($Result.ownership).Count | Should Be 0
}

function New-TestInstallReadLeaseEvidence {
    $lockPath=Join-Path $script:RepositoryRoot 'ai-instructions-install.lock'
    $created=-not(Test-Path -LiteralPath $lockPath)
    if($created){[IO.File]::WriteAllText($lockPath,'')}
    $stream=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$evidence=New-AgentEnvironmentInstallReadLeaseEvidence -Lease $stream;$stream.Dispose();$stream=$null}
    catch{$stream.Dispose();throw}
    return [pscustomobject]@{Evidence=$evidence;Stream=$evidence.Stream;Path=$lockPath;Created=$created}
}

function Get-TestTreeSnapshot {
    param([Parameter(Mandatory=$true)][string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return '<missing>'}
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
    $entries=@(Get-ChildItem -Force -Recurse -LiteralPath $rootFull|Sort-Object FullName|ForEach-Object{
        $relative=$_.FullName.Substring($rootFull.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        if($_.PSIsContainer){[pscustomobject][ordered]@{path=$relative;kind=$(if(($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){'reparse-directory'}else{'directory'});sha256=$null}}
        else{[pscustomobject][ordered]@{path=$relative;kind=$(if(($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){'reparse-file'}else{'file'});sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()}}
    })
    return (@($entries)|ConvertTo-Json -Depth 5 -Compress)
}

function Copy-TestPlatformRuntimeClosure {
    param([Parameter(Mandatory=$true)][string]$Destination)
    $manifestPath=Join-Path $script:RuntimeRoot 'platform-runtime.psd1'
    $manifest=Import-PowerShellDataFile -LiteralPath $manifestPath
    foreach($relativePath in @($manifest.FileList)){
        $source=Join-Path $script:RuntimeRoot ([string]$relativePath)
        $target=Join-Path $Destination ([string]$relativePath)
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target))|Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

function Copy-TestRecoveryRuntimeDependencies {
    param([Parameter(Mandatory=$true)][string]$Destination)
    $contractSource=Join-Path $script:RuntimeRoot 'ai-instructions-runtime-contract.psm1'
    $contractDestination=Join-Path $Destination 'ai-instructions-runtime-contract.psm1'
    [IO.File]::Copy($contractSource,$contractDestination,$true)
    if(-not(Test-Path -LiteralPath $contractDestination -PathType Leaf)){throw 'Recovery runtime contract fixture copy did not materialize.'}
    Copy-TestPlatformRuntimeClosure -Destination $Destination
}

Describe 'user-scoped Agent Skills reconciliation' {
    # Scenario: Callers invoke public recovery while reconciliation alone already owns the USER lock.
    # Purpose: Keep lock reuse private so external callers cannot bypass USER lock acquisition.
    It 'UnitT01_keeps_ExistingLock_private_to_locked_recovery' {
        (Get-Command Invoke-UserSkillsRecovery).Parameters.ContainsKey('ExistingLock')|Should Be $false
        (Get-Module agent-environment-reconciler).ExportedCommands.ContainsKey('Invoke-UserSkillsRecoveryLocked')|Should Be $false
    }

    # Scenario: Production encounters a v3/v5 generation before the P7e gate and pins are installed.
    # Purpose: Keep the production refusal centralized and typed while function-level fixtures can exercise P8.
    It 'UnitT00_rejects_v3_before_agent_environment_mutation' {
        $errorRecord=$null
        try { Assert-UserProjectionRuntimeGate -RuntimeRoot $script:RuntimeRoot }
        catch { $errorRecord=$_ }
        $errorRecord | Should Not BeNullOrEmpty
        $errorRecord.Exception.Code | Should Be 'projection-runtime-unavailable'
        $errorRecord.Exception.Message | Should Match 'projection-runtime-unavailable'
    }

    # Scenario: The persisted manifest is redirected outside USER home through a reparse point.
    # Purpose: Reject the path boundary before the pre-lock manifest snapshot can read its content.
    It 'UnitT00_path_safety_precedes_the_pre_lock_manifest_read' {
        $userHome = Join-Path $TestDrive 'manifest-reparse-user'
        $agentsRoot = Join-Path $userHome '.agents'
        $manifestPath = Join-Path $agentsRoot 'catalog-skills.manifest.json'
        $outsideRoot = Join-Path $TestDrive 'manifest-reparse-outside'
        $outsideManifest = Join-Path $outsideRoot 'catalog-skills.manifest.json'
        $sentinel = 'outside-manifest-sentinel-must-not-be-read'
        New-Item -ItemType Directory -Force -Path $userHome,$agentsRoot,$outsideRoot | Out-Null
        [System.IO.File]::WriteAllText($outsideManifest,$sentinel,[System.Text.UTF8Encoding]::new($false))
        $usedDirectoryJunction = $false
        try {
            New-Item -ItemType SymbolicLink -Path $manifestPath -Target $outsideManifest -ErrorAction Stop | Out-Null
        }
        catch {
            if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
            if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw }
            Remove-Item -LiteralPath $agentsRoot -Force
            New-Item -ItemType Junction -Path $agentsRoot -Target $outsideRoot -ErrorAction Stop | Out-Null
            $usedDirectoryJunction = $true
        }
        $desired = New-TestDesiredState -Root (Join-Path $TestDrive 'manifest-reparse-staging')
        $message = $null
        $output = @()
        try { $output = @(& { Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply } 2>&1) }
        catch { $message = $_.Exception.Message }

        $message | Should Be $(if ($usedDirectoryJunction) { 'User .agents root must not be a reparse point.' } else { 'User Agent environment path crosses a reparse point: .agents/catalog-skills.manifest.json' })
        (($output | Out-String) + $message) | Should Not Match $sentinel
    }

    # Scenario: Apply encounters an existing projection-aware USER manifest.
    # Purpose: Fail closed before creating locks, journals, backups, or changing managed bytes.
    It 'UnitT00a_rejects_an_existing_v3_manifest_before_apply_mutation' {
        $userHome = Join-Path $TestDrive 'existing-v3-apply'
        $agentsRoot = Join-Path $userHome '.agents'
        $target = Join-Path $agentsRoot 'skills\work-with-jira\SKILL.md'
        $manifestPath = Join-Path $agentsRoot 'catalog-skills.manifest.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        $originalBytes = [byte[]]@(0,10,13,128,255)
        [System.IO.File]::WriteAllBytes($target,$originalBytes)
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v3.example.json') -Destination $manifestPath
        $desired = New-TestDesiredState -Root (Join-Path $TestDrive 'existing-v3-apply-staging')

        $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $result.outcome | Should Be 'failed'
        @($result.failureDetails)[0].code | Should Be 'downgrade-refused'

        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($target)) | Should Be ([Convert]::ToBase64String($originalBytes))
        Test-Path -LiteralPath (Join-Path $agentsRoot 'update-agent-environment.lock') | Should Be $true
        Test-Path -LiteralPath (Join-Path $agentsRoot 'update-agent-environment.recovery.json') | Should Be $false
    }

    # Scenario: Recovery encounters an existing projection-aware USER manifest and a retained journal.
    # Purpose: Fail closed before interpreting the journal or restoring any USER file.
    It 'UnitT00b_rejects_an_existing_v3_manifest_before_recovery_mutation' {
        $userHome = Join-Path $TestDrive 'existing-v3-recovery'
        $agentsRoot = Join-Path $userHome '.agents'
        $target = Join-Path $agentsRoot 'skills\work-with-jira\SKILL.md'
        $manifestPath = Join-Path $agentsRoot 'catalog-skills.manifest.json'
        $journalPath = Join-Path $agentsRoot 'update-agent-environment.recovery.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        $originalBytes = [byte[]]@(255,128,13,10,0)
        [System.IO.File]::WriteAllBytes($target,$originalBytes)
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v3.example.json') -Destination $manifestPath
        [System.IO.File]::WriteAllText($journalPath,'preserve-invalid-journal')

        $result=Invoke-UserSkillsRecovery -UserHome $userHome
        $result.outcome | Should Be 'failed'
        @($result.failureDetails)[0].code | Should Be 'recovery-required'

        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($target)) | Should Be ([Convert]::ToBase64String($originalBytes))
        [System.IO.File]::ReadAllText($journalPath) | Should Be 'preserve-invalid-journal'
        Test-Path -LiteralPath (Join-Path $agentsRoot 'update-agent-environment.lock') | Should Be $true
    }

    # Scenario: USER receives nested scripts, references and binary assets and then an updated resource inventory.
    # Purpose: Verify raw bytes, resource update/prune, complete ownership and a stable second apply in USER.
    It 'InterT01_reconciles_recursive_resources_and_binary_bytes_only_in_USER' {
        # Given
        $userHome=Join-Path $TestDrive 'resource-user'
        $initial=New-TestDesiredState -Root (Join-Path $TestDrive 'resource-initial') -Resources @{
            'assets/nested/data.bin'=[byte[]]@(0,10,13,128,255)
            'assets/removed.bin'=[byte[]]@(255,128,0,13,10)
            'references/details.md'=[Text.Encoding]::UTF8.GetBytes('reference v1')
            'scripts/probe.ps1'=[Text.Encoding]::UTF8.GetBytes('Write-Output sample')
        }
        # When / Then
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        foreach($entry in $initial.Files){ (Get-FileHash (Join-Path $userHome $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $next=New-TestDesiredState -Root (Join-Path $TestDrive 'resource-next') -Resources @{
            'assets/nested/data.bin'=[byte[]]@(255,0,10,128)
            'scripts/probe.ps1'=[Text.Encoding]::UTF8.GetBytes('Write-Output updated')
        }
        $updated=Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply
        $updated.outcome | Should Be 'applied'
        Test-Path (Join-Path $userHome '.agents/skills/alpha/references/details.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents/skills/alpha/assets/removed.bin') | Should Be $false
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $updated.backupPath '.agents/skills/alpha/assets/nested/data.bin'))) | Should Be ([Convert]::ToBase64String([byte[]]@(0,10,13,128,255)))
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $updated.backupPath '.agents/skills/alpha/assets/removed.bin'))) | Should Be ([Convert]::ToBase64String([byte[]]@(255,128,0,13,10)))
        foreach($entry in $next.Files){ (Get-FileHash (Join-Path $userHome $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $before=(Get-FileHash (Join-Path $userHome '.agents/catalog-skills.manifest.json')).Hash
        (Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply).outcome | Should Be 'current'
        (Get-FileHash (Join-Path $userHome '.agents/catalog-skills.manifest.json')).Hash | Should Be $before
    }

    # Scenario: USER home is multiple missing components below the nearest existing physical ancestor.
    # Purpose: Keep read-only modes side-effect free, then let Apply create USER home and .agents through platform-runtime before locking.
    It 'InterT101_creates_a_missing_USER_home_only_for_Apply' {
        $ancestor=Join-Path $TestDrive 'missing-user-home-ancestor'
        New-Item -ItemType Directory -Path $ancestor|Out-Null
        $caseHome=Join-Path $ancestor 'nested/user-home'
        $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'missing-user-home-stage')

        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode VerifyOnly).outcome|Should Be 'drift'
        Test-Path -LiteralPath $caseHome|Should Be $false
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode WhatIf).outcome|Should Be 'planned'
        Test-Path -LiteralPath $caseHome|Should Be $false

        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode Apply).outcome|Should Be 'applied'
        Test-Path -LiteralPath (Join-Path $caseHome '.agents/update-agent-environment.lock') -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $caseHome '.agents/skills/alpha/SKILL.md') -PathType Leaf|Should Be $true
    }

    # Scenario: One source pin is projected to all three legal USER roots in one coordinator generation.
    # Purpose: Prove exact byte/hash parity, ordered projections, monotonic generation, and idempotent current behavior.
    It 'InterT67_reconciles_three_USER_projections_as_one_generation' {
        $userHome=Join-Path $TestDrive 'projection-user';$desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-stage')
        $first=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $first.outcome | Should Be 'applied'
        $paths=@('.agents/skills/work-with-jira/SKILL.md','.claude/skills/work-with-jira/SKILL.md','.copilot/skills/work-with-jira/SKILL.md')
        $bytes=@($paths|ForEach-Object{[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $userHome $_)))})
        @($bytes|Select-Object -Unique).Count | Should Be 1
        $manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $userHome '.agents/catalog-skills.manifest.json')|ConvertFrom-Json
        [int64]$manifest.generation | Should Be 1
        (@($manifest.projections)-join ',') | Should Be 'user-agents,user-claude,user-copilot'
        $manifestBytesBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $userHome '.agents/catalog-skills.manifest.json')))
        $second=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $second.outcome | Should Be 'current'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $userHome '.agents/catalog-skills.manifest.json'))) | Should Be $manifestBytesBefore
        $desired.Manifest.catalogCommit=('f'*40)
        Set-TestProjectionDesiredPayload -Desired $desired -Text "---`nname: work-with-jira`ndescription: projection update`n---`n"
        $updated=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $updated.outcome | Should Be 'applied'
        foreach($path in $paths){Test-Path -LiteralPath (Join-Path $updated.backupPath $path) -PathType Leaf|Should Be $true}
        Test-Path -LiteralPath (Join-Path $updated.backupPath '.agents/catalog-skills.manifest.json') -PathType Leaf|Should Be $true
        $nextManifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $userHome '.agents/catalog-skills.manifest.json')|ConvertFrom-Json
        [int64]$nextManifest.generation | Should Be 2
        @($nextManifest.projections) -join ',' | Should Be 'user-agents,user-claude,user-copilot'
    }

    # Scenario: A mutation fails after the first of three projections is published.
    # Purpose: Roll every projection and the coordinator manifest back as one USER-home transaction.
    It 'InterT68_rolls_back_all_USER_projections_after_a_mid_transaction_failure' {
        $userHome=Join-Path $TestDrive 'projection-rollback-user';$desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-rollback-stage')
        $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -FailureAfterMutationCount 1
        $result.outcome | Should Be 'failed'
        foreach($path in @('.agents/skills/work-with-jira/SKILL.md','.claude/skills/work-with-jira/SKILL.md','.copilot/skills/work-with-jira/SKILL.md','.agents/catalog-skills.manifest.json')){Test-Path -LiteralPath (Join-Path $userHome $path)|Should Be $false}
        @(Get-ChildItem -Force -LiteralPath (Join-Path $userHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    # Scenario: An unexpected file appears inside a just-published projection subtree before commit.
    # Purpose: Compare the complete subtree inventory, refuse commit, and retain external evidence instead of accepting expected-file-only checks.
    It 'InterT68a_rejects_extra_files_in_a_published_projection_subtree' {
        $userHome=Join-Path $TestDrive 'projection-extra-user';$desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-extra-stage')
        $extra=Join-Path $userHome '.claude/skills/external.txt'
        $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -BeforeFinalVerificationAction {
            [IO.File]::WriteAllText($extra,'external')
        }
        $result.outcome|Should Be 'failed'
        $result.rollbackState|Should Be 'recovery-required'
        $result.failureDetails[0].evidence|Should Match 'subtree inventory verification failed|Rollback failed'
        [IO.File]::ReadAllText($extra)|Should Be 'external'
    }

    # Scenario: Claude already contains a personal Skill and a same-name candidate is observed.
    # Purpose: Preserve unrelated content, adopt exact bytes, and reject only differing same-name bytes.
    It 'InterT69_preserves_personal_Claude_content_and_rejects_only_different_same_name_bytes' {
        $userHome=Join-Path $TestDrive 'projection-personal-user';$personal=Join-Path $userHome '.claude/skills/personal/SKILL.md';New-Item -ItemType Directory -Force -Path (Split-Path $personal)|Out-Null;[IO.File]::WriteAllText($personal,'personal')
        $desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-personal-stage')
        $exact=@($desired.Files|Where-Object projectionId -eq 'user-claude')[0];$exactTarget=Join-Path $userHome $exact.targetPath;New-Item -ItemType Directory -Force -Path (Split-Path $exactTarget)|Out-Null;[IO.File]::Copy($exact.stagedPath,$exactTarget)
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        [IO.File]::ReadAllText($personal) | Should Be 'personal'
        Set-Content -LiteralPath $exactTarget -Value 'different'
        Remove-Item -LiteralPath (Join-Path $userHome '.agents/catalog-skills.manifest.json') -Force
        $collision=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $collision.outcome | Should Be 'failed'
        $collision.Code | Should BeNullOrEmpty
        @($collision.failureDetails|Where-Object code -eq 'unmanaged-collision').Count | Should BeGreaterThan 0
        [IO.File]::ReadAllText($personal) | Should Be 'personal'
    }

    # Scenario: A persisted v3 ownership manifest has an out-of-root entry, unknown projection, or duplicate target.
    # Purpose: Reject untrusted ownership before any replacement/removal and preserve personal Claude/Copilot content.
    It 'InterT69a_rejects_invalid_v3_ownership_manifests_without_mutation' {
        $userHome=Join-Path $TestDrive 'invalid-v3-user';$desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'invalid-v3-stage')
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome|Should Be 'applied'
        $personalClaude=Join-Path $userHome '.claude/skills/personal/SKILL.md';$personalCopilot=Join-Path $userHome '.copilot/skills/personal/SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path $personalClaude),(Split-Path $personalCopilot)|Out-Null
        [IO.File]::WriteAllText($personalClaude,'claude-personal');[IO.File]::WriteAllText($personalCopilot,'copilot-personal')
        $manifestPath=Join-Path $userHome '.agents/catalog-skills.manifest.json';$validJson=[IO.File]::ReadAllText($manifestPath)
        $managedPath=Join-Path $userHome '.agents/skills/work-with-jira/SKILL.md';$managedBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($managedPath))
        foreach($case in @('outside-root','unknown-projection','duplicate')){
            $invalid=$validJson|ConvertFrom-Json
            if($case-ceq'outside-root'){$invalid.files[0].targetPath='.claude/personal-escape/SKILL.md'}
            elseif($case-ceq'unknown-projection'){$invalid.files[0].projectionId='user-unknown'}
            else{$invalid.files=@($invalid.files)+@($invalid.files[0])}
            [IO.File]::WriteAllText($manifestPath,($invalid|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            {Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply|Out-Null}|Should Throw
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($managedPath))|Should Be $managedBefore
            [IO.File]::ReadAllText($personalClaude)|Should Be 'claude-personal'
            [IO.File]::ReadAllText($personalCopilot)|Should Be 'copilot-personal'
            @(Get-ChildItem -Force -LiteralPath (Join-Path $userHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
        }
    }
    BeforeEach {
        $userHome = Join-Path $TestDrive ('home-' + [Guid]::NewGuid().ToString('N'))
        $staging = Join-Path $TestDrive ('staging-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $userHome,$staging | Out-Null
    }

    # Scenario: A read-only reconciliation sees a nonempty USER install-transaction root.
    # Purpose: Return typed interrupted-install without cleanup, while Apply purges an orphan before starting one new transaction.
    It 'InterT70_fails_closed_read_only_and_auto_recovers_an_orphan_on_Apply' {
        $desired=New-TestDesiredState -Root (Join-Path $staging 'orphan-recovery')
        $orphan=Join-Path $userHome '.ai-instructions-txn\0123456789abcdef0123456789abcdef'
        New-Item -ItemType Directory -Force -Path $orphan|Out-Null

        $verify=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode VerifyOnly
        $verify.Code | Should Be 'interrupted-install'
        Test-Path -LiteralPath $orphan | Should Be $true
        $whatIf=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode WhatIf
        $whatIf.Code | Should Be 'interrupted-install'
        Test-Path -LiteralPath $orphan | Should Be $true

        $readLease=New-TestInstallReadLeaseEvidence
        try{(Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -InstallReadLease $readLease.Evidence).outcome | Should Be 'applied'}finally{$readLease.Stream.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}
        Test-Path -LiteralPath $orphan | Should Be $false
    }

    # Scenario: A direct caller presents a readable same-basename file from another directory.
    # Purpose: Bind USER recovery authority to the installed runtime lock, not a forgeable basename.
    It 'InterT70a_rejects_a_noncanonical_install_read_lease_without_mutation' {
        $desired=New-TestDesiredState -Root (Join-Path $staging 'wrong-read-lease')
        $orphan=Join-Path $userHome '.ai-instructions-txn/0123456789abcdef0123456789abcdef';New-Item -ItemType Directory -Force -Path $orphan|Out-Null
        $wrongRoot=Join-Path $TestDrive 'wrong-install-lock';New-Item -ItemType Directory -Path $wrongRoot|Out-Null
        $wrongPath=Join-Path $wrongRoot 'ai-instructions-install.lock';[IO.File]::WriteAllText($wrongPath,'')
        $wrong=[IO.File]::Open($wrongPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{$result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -InstallReadLease $wrong}finally{$wrong.Dispose()}
        $result.Code|Should Be 'interrupted-install'
        Test-Path -LiteralPath $orphan|Should Be $true
        Test-Path -LiteralPath (Join-Path $userHome '.agents/skills/alpha/SKILL.md')|Should Be $false
    }

    if(-not[string]::IsNullOrWhiteSpace([string]$script:SecondaryVolumeRoot)){
        # Scenario: One selected USER projection resolves through a junction to a second physical volume.
        # Purpose: Enforce the P8 same-volume limitation before transaction, lock, or target mutation.
        It 'InterT76_rejects_a_cross_volume_projection_before_mutation' {
            $userHome=Join-Path $TestDrive 'cross-volume-user';New-Item -ItemType Directory -Path $userHome|Out-Null
            $secondary=Join-Path $script:SecondaryVolumeRoot ('ai-instructions-p8-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $secondary 'skills') -Force|Out-Null
            try{
                New-Item -ItemType Junction -Path (Join-Path $userHome '.claude') -Target $secondary|Out-Null
                $desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'cross-volume-stage')
                $caught=$null;try{Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply|Out-Null}catch{$caught=$_}
                $caught|Should Not BeNullOrEmpty
                $caught.Exception.Code|Should Be 'capability-unavailable'
                Test-Path -LiteralPath (Join-Path $userHome '.agents')|Should Be $false
                Test-Path -LiteralPath (Join-Path $userHome '.ai-instructions-txn')|Should Be $false
            }finally{if(Test-Path -LiteralPath (Join-Path $userHome '.claude')){Remove-Item -LiteralPath (Join-Path $userHome '.claude') -Force};if(Test-Path -LiteralPath $secondary){Remove-Item -LiteralPath $secondary -Recurse -Force}}
        }

        # Scenario: The stable entry selects all USER projections while one root resolves to a second volume.
        # Purpose: Preserve the capability-unavailable Code and zero mutation through the public entry surface.
        It 'InterT76a_reports_cross_volume_capability_refusal_through_the_entry' {
            $entry=Join-Path $script:RepositoryRoot 'scripts/update-agent-environment.ps1';$codexHome=Join-Path $TestDrive 'cross-volume-entry-codex';$runtime=Join-Path $codexHome 'hooks/ai-instructions-runtime'
            New-Item -ItemType Directory -Force -Path $runtime,(Join-Path $runtime 'catalog')|Out-Null;Copy-Item -Path (Join-Path $script:RuntimeRoot '*') -Destination $runtime -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') -Destination (Join-Path $runtime 'catalog/skills-catalog.json');Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog-lock.json') -Destination (Join-Path $runtime 'catalog/skills-catalog-lock.json')
            Move-Item -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Destination (Join-Path $runtime 'agent-environment-reconciler-core.ps1')
            @'
. (Join-Path $PSScriptRoot 'agent-environment-reconciler-core.ps1')
function Get-UserSkillsDesiredState { param([string]$RuntimeRoot,[object]$Configuration,[string]$CatalogRepository,[string]$CatalogCommit,[string]$WorkingRoot) $state=Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'test-desired.clixml');$state.RuntimeRoot=$PSScriptRoot;return $state }
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
'@|Set-Content -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Encoding UTF8
            [IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-install.lock'),'');[IO.File]::WriteAllText((Join-Path $codexHome 'hooks/bootstrap-ai-instructions.ps1'),"param([switch]`$ValidateOnly)`nif(-not`$ValidateOnly){throw 'ValidateOnly required'}")
            $commit='89abcdef0123456789abcdef0123456789abcdef';@{schemaVersion=4;catalog=@{ref=$commit}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $codexHome 'ai-instructions-sync.json') -Encoding UTF8;@{schemaVersion=2;repository='https://github.com/example/ai-instructions.git';commit=$commit}|ConvertTo-Json|Set-Content (Join-Path $runtime 'runtime-bundle.json') -Encoding UTF8
            $desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'cross-volume-entry-stage');$desired|Export-Clixml (Join-Path $runtime 'test-desired.clixml')
            $userHome=Join-Path $TestDrive 'cross-volume-entry-user';New-Item -ItemType Directory -Path $userHome|Out-Null;$secondary=Join-Path $script:SecondaryVolumeRoot ('ai-instructions-p8-entry-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path (Join-Path $secondary 'skills') -Force|Out-Null
            try{
                New-Item -ItemType Junction -Path (Join-Path $userHome '.claude') -Target $secondary|Out-Null
                $output=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $userHome -Apply -OutputFormat Json);$LASTEXITCODE|Should Be 1
                ($output[-1]|ConvertFrom-Json).Code|Should Be 'capability-unavailable';Test-Path (Join-Path $userHome '.agents')|Should Be $false;Test-Path (Join-Path $userHome '.ai-instructions-txn')|Should Be $false
            }finally{if(Test-Path -LiteralPath (Join-Path $userHome '.claude')){Remove-Item -LiteralPath (Join-Path $userHome '.claude') -Force};if(Test-Path -LiteralPath $secondary){Remove-Item -LiteralPath $secondary -Recurse -Force}}
        }

        # Scenario: The last managed Skill is retired while one still-selected projection root is on a second volume.
        # Purpose: Check selected projection roots even when the desired file inventory is empty.
        It 'InterT76b_rejects_an_empty_selected_projection_on_a_second_volume' {
            $userHome=Join-Path $TestDrive 'cross-volume-empty-user';New-Item -ItemType Directory -Path $userHome|Out-Null
            $secondary=Join-Path $script:SecondaryVolumeRoot ('ai-instructions-p8-empty-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $secondary 'skills') -Force|Out-Null
            try{
                New-Item -ItemType Junction -Path (Join-Path $userHome '.claude') -Target $secondary|Out-Null
                $desired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'cross-volume-empty-stage')
                $desired.Files=@();$desired.Manifest.files=@();$desired.SkillIds=@()
                $caught=$null;try{Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply|Out-Null}catch{$caught=$_}
                $caught|Should Not BeNullOrEmpty
                $caught.Exception.Code|Should Be 'capability-unavailable'
                Test-Path -LiteralPath (Join-Path $userHome '.agents')|Should Be $false
                Test-Path -LiteralPath (Join-Path $userHome '.ai-instructions-txn')|Should Be $false
            }finally{if(Test-Path -LiteralPath (Join-Path $userHome '.claude')){Remove-Item -LiteralPath (Join-Path $userHome '.claude') -Force};if(Test-Path -LiteralPath $secondary){Remove-Item -LiteralPath $secondary -Recurse -Force}}
        }
    }

    # Scenario: Legacy recovery JSON and a new install-journal transaction residue coexist.
    # Purpose: Refuse before either recovery path mutates or removes its evidence.
    It 'InterT71_refuses_coexisting_legacy_and_new_transaction_evidence' {
        $desired=New-TestDesiredState -Root (Join-Path $staging 'coexisting-residue')
        $legacy=Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $new=Join-Path $userHome '.ai-instructions-txn\0123456789abcdef0123456789abcdef'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy),$new|Out-Null
        [IO.File]::WriteAllText($legacy,'{}')

        $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $result.Code | Should Be 'interrupted-install'
        Test-Path -LiteralPath $legacy | Should Be $true
        Test-Path -LiteralPath $new | Should Be $true
    }

    # Scenario: Apply starts with only a valid predecessor recovery JSON.
    # Purpose: Restore it under the same USER lock before committing the new install-journal transaction.
    It 'InterT72_auto_recovers_legacy_JSON_before_the_new_Apply_transaction' {
        $desired=New-TestDesiredState -Root (Join-Path $staging 'legacy-auto')
        $target=Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup=Join-Path $userHome '.agents\backups\legacy-auto\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup)|Out-Null
        [IO.File]::WriteAllText($target,'interrupted-applied')
        [IO.File]::WriteAllBytes($backup,[IO.File]::ReadAllBytes([string]$desired.Files[0].stagedPath))
        $appliedSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $backupRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journal=New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md';existed=$true;backupPath=$backup
            originalSha256=$originalSha;backupSha256=$originalSha;appliedSha256=$appliedSha
        })
        $legacy=Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $legacy -Encoding UTF8

        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        Test-Path -LiteralPath $legacy | Should Be $false
        (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant() | Should Be $desired.Files[0].sha256
    }

    # Scenario: The writer process dies at every P8 durable failpoint without running finally blocks.
    # Purpose: Require the next Apply, under an install read lease, to classify and recover each residue before reconciling.
    It 'InterT74_recovers_every_USER_reconciler_FailFast_boundary' {
        $childScript=Join-Path $TestDrive 'user-reconciler-failfast-child.ps1'
        @'
param([string]$ModulePath,[string]$DesiredPath,[string]$UserHome,[string]$Failpoint,[int]$FailureAfter)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$desired=Import-Clixml -LiteralPath $DesiredPath
$env:AI_INSTRUCTIONS_USER_RECONCILER_FAILFAST=$Failpoint
Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $UserHome -Mode Apply -FailpointName $Failpoint -FailureAfterMutationCount $FailureAfter|Out-Null
'@|Set-Content -LiteralPath $childScript -Encoding UTF8
        $failpoints=@(
            'after-staged-subtree-verification','after-journal-stage-flush','after-journal-rename','after-journal-publish',
            'after-operation-journal','after-original-rename','after-platform-rename','after-applied-rename','after-parent-flush',
            'during-rollback','after-rollback-action','before-committed-cleanup','before-committed-backup-export',
            'after-committed-backup-export','before-committed-transaction-cleanup','after-committed-transaction-cleanup'
        )
        $triggered=New-Object Collections.Generic.List[string]
        foreach($failpoint in $failpoints){
            $caseHome=Join-Path $TestDrive ("failfast-home-$failpoint")
            $caseStage=Join-Path $TestDrive ("failfast-stage-$failpoint")
            $caseCodex=Join-Path $TestDrive ("failfast-codex-$failpoint")
            $caseRuntime=Join-Path $caseCodex 'hooks/ai-instructions-runtime'
            New-Item -ItemType Directory -Force -Path $caseHome,$caseStage,$caseRuntime|Out-Null
            Copy-Item -LiteralPath $script:ModulePath -Destination (Join-Path $caseRuntime 'agent-environment-reconciler.psm1')
            Copy-Item -LiteralPath $script:ContractPath -Destination (Join-Path $caseRuntime 'skills-catalog-contract.psm1')
            Copy-TestRecoveryRuntimeDependencies -Destination $caseRuntime
            $initial=New-TestDesiredState -Root (Join-Path $caseStage 'initial')
            (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $caseHome -Mode Apply).outcome|Should Be 'applied'
            $desired=New-TestDesiredState -Root (Join-Path $caseStage 'next')
            [IO.File]::WriteAllText([string]$desired.Files[0].stagedPath,"---`nname: alpha`ndescription: failpoint $failpoint`n---`n",[Text.UTF8Encoding]::new($false))
            $nextSha=(Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$desired.Files[0].stagedPath)).Hash.ToLowerInvariant()
            $desired.Files[0].sha256=$nextSha;$desired.Manifest.files[0].sha256=$nextSha
            $desiredPath=Join-Path $TestDrive ("desired-$failpoint.clixml");$desired|Export-Clixml -LiteralPath $desiredPath
            $failureAfter=if($failpoint-in@('during-rollback','after-rollback-action')){1}else{0}
            if($failpoint-ceq'after-staged-subtree-verification'){Remove-Item -LiteralPath (Join-Path $caseHome '.agents/skills/alpha') -Recurse -Force}
            & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $childScript (Join-Path $caseRuntime 'agent-environment-reconciler.psm1') $desiredPath $caseHome $failpoint $failureAfter 2>$null
            if($LASTEXITCODE-eq0){throw "failpoint=$failpoint; child process unexpectedly succeeded."}
            if($failpoint-cne'after-committed-transaction-cleanup'-and@(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count-le0){throw "failpoint=$failpoint; expected retained transaction residue."}
            if($failpoint-ceq'after-original-rename'){
                if(Test-Path -LiteralPath (Join-Path $caseHome '.agents/skills/alpha/SKILL.md')){throw "failpoint=$failpoint; original target was not renamed into transaction backup."}
                if(@(Get-ChildItem -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -Filter 'backup-*' -Recurse -File).Count-le0){throw "failpoint=$failpoint; renamed original backup is missing."}
            }
            $triggered.Add($failpoint)
            foreach($moduleName in @('skills-selection.psm1','skills-source-routing.psm1','skills-source-retrieval.psm1','skills-source-acquisition.psm1','license-delivery.psm1','safe-zip.psm1')){Copy-Item -LiteralPath (Join-Path $script:RuntimeRoot $moduleName) -Destination $caseRuntime -Force}
            New-Item -ItemType Directory -Force -Path (Join-Path $caseRuntime 'catalog')|Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') -Destination (Join-Path $caseRuntime 'catalog/skills-catalog.json') -Force
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog-lock.json') -Destination (Join-Path $caseRuntime 'catalog/skills-catalog-lock.json') -Force
            Move-Item -LiteralPath (Join-Path $caseRuntime 'agent-environment-reconciler.psm1') -Destination (Join-Path $caseRuntime 'agent-environment-reconciler-core.ps1')
            Copy-Item -LiteralPath $desiredPath -Destination (Join-Path $caseRuntime 'test-desired.clixml')
            @'
. (Join-Path $PSScriptRoot 'agent-environment-reconciler-core.ps1')
function Get-UserSkillsDesiredState { param([string]$RuntimeRoot,[object]$Configuration,[string]$CatalogRepository,[string]$CatalogCommit,[string]$WorkingRoot) [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'desired-state-requested.marker'),'requested');$state=Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'test-desired.clixml');$state.RuntimeRoot=$PSScriptRoot;return $state }
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
'@|Set-Content -LiteralPath (Join-Path $caseRuntime 'agent-environment-reconciler.psm1') -Encoding UTF8
            [IO.File]::WriteAllText((Join-Path $caseCodex 'ai-instructions-install.lock'),'');[IO.File]::WriteAllText((Join-Path $caseCodex 'hooks/bootstrap-ai-instructions.ps1'),"param([switch]`$ValidateOnly)`nif(-not`$ValidateOnly){throw 'ValidateOnly required'}")
            $commit='89abcdef0123456789abcdef0123456789abcdef';@{schemaVersion=4;catalog=@{ref=$commit}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $caseCodex 'ai-instructions-sync.json') -Encoding UTF8;@{schemaVersion=2;repository='https://github.com/example/ai-instructions.git';commit=$commit}|ConvertTo-Json|Set-Content (Join-Path $caseRuntime 'runtime-bundle.json') -Encoding UTF8
            $entry=Join-Path $script:RepositoryRoot 'scripts/update-agent-environment.ps1';$beforeVerify=Get-TestTreeSnapshot $caseHome
            $desiredStateMarker=Join-Path $caseRuntime 'desired-state-requested.marker'
            $verifyOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $caseCodex -UserHome $caseHome -VerifyOnly -OutputFormat Json);$verifyExit=$LASTEXITCODE;$verifyResult=$verifyOutput[-1]|ConvertFrom-Json
            if($failpoint-ceq'after-committed-transaction-cleanup'){
                if($verifyExit-ne0-or[string]$verifyResult.outcome-cne'current'){throw "failpoint=$failpoint; VerifyOnly must report current after committed transaction cleanup."}
            }elseif($verifyExit-ne1-or[string]$verifyResult.Code-cne'interrupted-install'){
                throw "failpoint=$failpoint; VerifyOnly must report Code=interrupted-install while transaction residue remains."
            }
            if((Get-TestTreeSnapshot $caseHome)-cne$beforeVerify){throw "failpoint=$failpoint; VerifyOnly mutated the USER tree."}
            if($failpoint-cne'after-committed-transaction-cleanup'-and(Test-Path -LiteralPath $desiredStateMarker)){throw "failpoint=$failpoint; VerifyOnly loaded desired state before refusing transaction residue."}
            $applyOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $caseCodex -UserHome $caseHome -Apply -OutputFormat Json);$applyExit=$LASTEXITCODE;$result=$applyOutput[-1]|ConvertFrom-Json
            if($applyExit-ne0){throw "failpoint=$failpoint; Apply recovery exited with code $applyExit."}
            if([string]$result.outcome-cnotin@('applied','current')){throw "failpoint=$failpoint; Apply recovery returned outcome=$($result.outcome)."}
            if(@(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count-ne0){throw "failpoint=$failpoint; Apply recovery retained transaction residue."}
            $actualSha=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $caseHome '.agents/skills/alpha/SKILL.md')).Hash.ToLowerInvariant()
            if($actualSha-cne[string]$desired.Files[0].sha256){throw "failpoint=$failpoint; Apply recovery produced SHA-256 $actualSha instead of $($desired.Files[0].sha256)."}
        }
        $triggered.Count|Should Be $failpoints.Count
        foreach($failpoint in $failpoints){$triggered|Should Contain $failpoint}
    }

    # Scenario: Recovery has only journal.prev when a replacement journal is staged and the writer dies before publication.
    # Purpose: Keep the sole durable fallback authoritative until journal.json has been published and read back.
    It 'InterT82_retains_the_only_durable_journal_prev_across_stage_flush_FailFast' {
        $transactionId=[guid]::NewGuid().ToString('N')
        $transactionPath=Join-Path $TestDrive ".ai-instructions-txn/$transactionId"
        New-Item -ItemType Directory -Force -Path $transactionPath|Out-Null
        $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String
        $journal.transactionId=$transactionId;$journal.phase='prepared'
        foreach($operation in $journal.operations){$operation.state='pending'}
        $previousPath=Join-Path $transactionPath 'journal.prev'
        [IO.File]::WriteAllText($previousPath,($journal|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        $nextPath=Join-Path $TestDrive 'fallback-next-journal.clixml';$next=$journal.PSObject.Copy();$next.phase='applying';$next.operations=[object[]]@($next.operations);$next|Export-Clixml -LiteralPath $nextPath
        $childPath=Join-Path $TestDrive 'fallback-stage-flush-child.ps1'
        @'
param([string]$ModulePath,[string]$TransactionPath,[string]$JournalPath)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$module=Get-Module agent-environment-reconciler
& $module {
    param($RuntimeRoot,$TransactionPath,$JournalPath)
    Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot
    $lease=Open-PlatformDirectory -Root $TransactionPath -RootOnly
    try{
        $journal=Import-Clixml -LiteralPath $JournalPath
        $journal.operations=[object[]]@($journal.operations)
        $env:AI_INSTRUCTIONS_USER_RECONCILER_FAILFAST='after-journal-stage-flush'
        Write-AgentEnvironmentInstallJournal -TransactionPath $TransactionPath -TransactionLease $lease -Journal $journal
    }finally{$lease.Dispose()}
} (Split-Path -Parent $ModulePath) $TransactionPath $JournalPath
'@|Set-Content -LiteralPath $childPath -Encoding UTF8

        & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $childPath $script:ModulePath $transactionPath $nextPath 2>$null
        $LASTEXITCODE|Should Not Be 0
        Test-Path -LiteralPath $previousPath -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $transactionPath 'journal.json')|Should Be $false

        $module=Get-Module agent-environment-reconciler
        & $module {
            param($RuntimeRoot,$TransactionPath,$JournalPath)
            Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot
            $lease=Open-PlatformDirectory -Root $TransactionPath -RootOnly
            try{$journal=Import-Clixml -LiteralPath $JournalPath;$journal.operations=[object[]]@($journal.operations);Write-AgentEnvironmentInstallJournal -TransactionPath $TransactionPath -TransactionLease $lease -Journal $journal}finally{$lease.Dispose()}
        } $script:RuntimeRoot $transactionPath $nextPath
        Test-Path -LiteralPath (Join-Path $transactionPath 'journal.json') -PathType Leaf|Should Be $true
        Test-Path -LiteralPath $previousPath|Should Be $false
    }

    # Scenario: An attacker prepositions journal.stage as a hard link or directory junction.
    # Purpose: Reject the leaf through the transaction lease without truncating or changing the external target.
    It 'InterT95_rejects_unsafe_journal_stage_without_touching_external_bytes' {
        foreach($kind in @('hard-link','junction')){
            $transactionId=[guid]::NewGuid().ToString('N');$transactionPath=Join-Path $TestDrive "unsafe-stage-$kind/$transactionId";New-Item -ItemType Directory -Force -Path $transactionPath|Out-Null
            $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String;$journal.transactionId=$transactionId
            $outsideRoot=Join-Path $TestDrive "unsafe-stage-$kind-outside";New-Item -ItemType Directory -Force -Path $outsideRoot|Out-Null
            $outsideFile=Join-Path $outsideRoot 'sentinel.bin';[IO.File]::WriteAllBytes($outsideFile,[byte[]](1,3,5,7,9));$before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideFile))
            $stage=Join-Path $transactionPath 'journal.stage'
            if($kind-ceq'hard-link'){New-Item -ItemType HardLink -Path $stage -Target $outsideFile|Out-Null}else{New-Item -ItemType Junction -Path $stage -Target $outsideRoot|Out-Null}
            $module=Get-Module agent-environment-reconciler
            {& $module {param($RuntimeRoot,$TransactionPath,$Journal) Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot;$lease=Open-PlatformDirectory -Root $TransactionPath -RootOnly;try{Write-AgentEnvironmentInstallJournal -TransactionPath $TransactionPath -TransactionLease $lease -Journal $Journal}finally{$lease.Dispose()}} $script:RuntimeRoot $transactionPath $journal}|Should Throw
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideFile))|Should Be $before
            Test-Path -LiteralPath $stage|Should Be $true
        }
    }

    # Scenario: Another process prepositions file-1.stage as a hard link, or as a file symlink when Windows permits it, after the transaction directory becomes observable.
    # Purpose: Create transaction payloads exclusively through create-new platform leases so Apply cannot truncate external bytes or publish a partial projection.
    It 'InterT103_rejects_prepositioned_payload_stage_links_without_external_or_projection_mutation' {
        $linkKinds=New-Object Collections.Generic.List[string]
        $linkKinds.Add('hard-link')
        if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
            $probeTarget=Join-Path $TestDrive 'payload-stage-symlink-probe-target';$probeLink=Join-Path $TestDrive 'payload-stage-symlink-probe-link'
            [IO.File]::WriteAllText($probeTarget,'probe')
            try{New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeTarget -ErrorAction Stop|Out-Null;$linkKinds.Add('symbolic-link')}
            catch{}
            finally{if(Test-Path -LiteralPath $probeLink){Remove-Item -LiteralPath $probeLink -Force};if(Test-Path -LiteralPath $probeTarget){Remove-Item -LiteralPath $probeTarget -Force}}
        }
        foreach($linkKind in $linkKinds){
            $caseHome=Join-Path $TestDrive "payload-stage-$linkKind-home";$desired=New-TestDesiredState -Root (Join-Path $TestDrive "payload-stage-$linkKind-source")
            New-Item -ItemType Directory -Force -Path (Join-Path $caseHome '.agents/skills/alpha')|Out-Null
            $outsideFile=Join-Path $TestDrive "payload-stage-$linkKind-external.bin";$outsideBytes=[byte[]](0,17,34,51,68,85,102,119,136,153,170,187,204,221,238,255)
            [IO.File]::WriteAllBytes($outsideFile,$outsideBytes);$before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideFile))
            $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode Apply -BeforeTransactionPrivateWriteAction {
                param($transactionPath)
                $stage=Join-Path $transactionPath 'file-1.stage'
                if($linkKind-ceq'hard-link'){New-Item -ItemType HardLink -Path $stage -Target $outsideFile -ErrorAction Stop|Out-Null}
                else{New-Item -ItemType SymbolicLink -Path $stage -Target $outsideFile -ErrorAction Stop|Out-Null}
            }
            $result.outcome|Should Be 'failed'
            $result.rollbackState|Should Be 'recovery-required'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideFile))|Should Be $before
            Test-Path -LiteralPath (Join-Path $caseHome '.agents/skills/alpha/SKILL.md')|Should Be $false
            Test-Path -LiteralPath (Join-Path $caseHome '.agents/catalog-skills.manifest.json')|Should Be $false
            $retained=@(Get-ChildItem -Force -Directory -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue)
            $retained.Count|Should Be 1
            Test-Path -LiteralPath (Join-Path $retained[0].FullName 'file-1.stage')|Should Be $true
        }
    }

    # Scenario: journal.json is a hard link or a reparse-backed directory rather than one regular single-link file.
    # Purpose: Classify the transaction as malformed, retain it, and never read or mutate through the unsafe leaf.
    It 'InterT97_classifies_unsafe_journal_leaves_as_malformed_and_retains_evidence' {
        foreach($kind in @('hard-link','junction')){
            $caseHome=Join-Path $TestDrive "unsafe-journal-$kind-home";$transactionId=[guid]::NewGuid().ToString('N');$transactionPath=Join-Path $caseHome ".ai-instructions-txn/$transactionId";New-Item -ItemType Directory -Force -Path $transactionPath|Out-Null
            $outsideRoot=Join-Path $TestDrive "unsafe-journal-$kind-outside";New-Item -ItemType Directory -Force -Path $outsideRoot|Out-Null
            $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json');$outsideFile=Join-Path $outsideRoot 'journal.json';[IO.File]::WriteAllText($outsideFile,$journal,[Text.UTF8Encoding]::new($false));$before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideFile))
            $leaf=Join-Path $transactionPath 'journal.json';if($kind-ceq'hard-link'){New-Item -ItemType HardLink -Path $leaf -Target $outsideFile|Out-Null}else{New-Item -ItemType Junction -Path $leaf -Target $outsideRoot|Out-Null}
            $readLease=New-TestInstallReadLeaseEvidence
            try{$result=Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $readLease.Evidence}finally{$readLease.Evidence.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}
            $result.Code|Should Be 'interrupted-install'
            Test-Path -LiteralPath $transactionPath -PathType Container|Should Be $true
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($outsideFile))|Should Be $before
        }
    }

    # Scenario: A retained USER journal has exact directory evidence for an out-of-scope USER-home target.
    # Purpose: Reject the journal before recovery can lease, quarantine, or delete that unrelated directory.
    It 'InterT84_rejects_an_out_of_scope_directory_journal_without_target_mutation' {
        $transactionId=[guid]::NewGuid().ToString('N')
        $transactionPath=Join-Path $userHome ".ai-instructions-txn/$transactionId"
        $documentsPath=Join-Path $userHome 'Documents'
        $sentinelPath=Join-Path $documentsPath 'sentinel.txt'
        New-Item -ItemType Directory -Force -Path $transactionPath,$documentsPath|Out-Null
        [IO.File]::WriteAllText($sentinelPath,'preserve unrelated USER content',[Text.UTF8Encoding]::new($false))
        $module=Get-Module agent-environment-reconciler
        $applied=& $module {
            param($RuntimeRoot,$Home)
            Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot
            Get-AgentEnvironmentDirectoryJournalState -Home $Home -RelativePath 'Documents'
        } $script:RuntimeRoot $userHome
        $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String
        $journal.transactionId=$transactionId;$journal.phase='applying'
        $manifest=$journal.operations[0];$manifest.sequence=2;$manifest.state='pending'
        $directory=[pscustomobject][ordered]@{sequence=1;kind='create-directory';method='stage-rename';targetRelativePath='Documents';stageLeaf='directory.stage';backupLeaf=$null;quarantineLeaf='directory.quarantine';original=[pscustomobject][ordered]@{exists=$false;identity=$null;inventorySha256=$null;entryCount=$null};backupIdentity=$null;applied=$applied;permissions=$null;state='pending'}
        $journal.operations=@($directory,$manifest)
        [IO.File]::WriteAllText((Join-Path $transactionPath 'journal.json'),($journal|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))

        $readLease=New-TestInstallReadLeaseEvidence
        try{$result=Invoke-UserSkillsRecovery -UserHome $userHome -InstallReadLease $readLease.Evidence}
        finally{$readLease.Stream.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}

        $result.Code|Should Be 'interrupted-install'
        $result.failureDetails[0].path|Should Be '.ai-instructions-txn'
        Test-Path -LiteralPath $documentsPath -PathType Container|Should Be $true
        [IO.File]::ReadAllText($sentinelPath)|Should Be 'preserve unrelated USER content'
        Test-Path -LiteralPath (Join-Path $transactionPath 'journal.json') -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $transactionPath 'directory.quarantine')|Should Be $false
    }

    # Scenario: Apply, VerifyOnly, WhatIf, and explicit Recover see an out-of-scope install journal in a USER home that did not have .agents.
    # Purpose: Return the same interrupted-install refusal without touching the unrelated target or retained transaction evidence.
    It 'InterT85_classifies_fresh_home_transaction_residue_consistently_in_every_mode' {
        $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'fresh-home-mode-staging')
        $readLease=New-TestInstallReadLeaseEvidence
        try{
            foreach($mode in @('Apply','VerifyOnly','WhatIf','Recover')){
                $caseHome=Join-Path $TestDrive "fresh-home-$mode"
                $transactionId=[guid]::NewGuid().ToString('N')
                $transactionPath=Join-Path $caseHome ".ai-instructions-txn/$transactionId"
                $documentsPath=Join-Path $caseHome 'Documents'
                $sentinelPath=Join-Path $documentsPath 'sentinel.txt'
                New-Item -ItemType Directory -Force -Path $transactionPath,$documentsPath|Out-Null
                [IO.File]::WriteAllText($sentinelPath,"preserve-$mode",[Text.UTF8Encoding]::new($false))
                $module=Get-Module agent-environment-reconciler
                $applied=& $module {
                    param($RuntimeRoot,$Home)
                    Import-AgentEnvironmentRuntimeModules -RuntimeRoot $RuntimeRoot
                    Get-AgentEnvironmentDirectoryJournalState -Home $Home -RelativePath 'Documents'
                } $script:RuntimeRoot $caseHome
                $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String
                $journal.transactionId=$transactionId;$journal.phase='applying'
                $manifest=$journal.operations[0];$manifest.sequence=2;$manifest.state='pending'
                $directory=[pscustomobject][ordered]@{sequence=1;kind='create-directory';method='stage-rename';targetRelativePath='Documents';stageLeaf='directory.stage';backupLeaf=$null;quarantineLeaf='directory.quarantine';original=[pscustomobject][ordered]@{exists=$false;identity=$null;inventorySha256=$null;entryCount=$null};backupIdentity=$null;applied=$applied;permissions=$null;state='pending'}
                $journal.operations=@($directory,$manifest)
                $journalPath=Join-Path $transactionPath 'journal.json'
                [IO.File]::WriteAllText($journalPath,($journal|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
                Test-Path -LiteralPath (Join-Path $caseHome '.agents')|Should Be $false

                $result=switch($mode){
                    'Recover'{Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $readLease.Evidence}
                    default{Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode $mode -InstallReadLease $readLease.Evidence}
                }

                $result.Code|Should Be 'interrupted-install'
                $result.failureDetails[0].path|Should Be '.ai-instructions-txn'
                [IO.File]::ReadAllText($sentinelPath)|Should Be "preserve-$mode"
                Test-Path -LiteralPath $journalPath -PathType Leaf|Should Be $true
                Test-Path -LiteralPath (Join-Path $transactionPath 'directory.quarantine')|Should Be $false
            }
        }finally{$readLease.Stream.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}
    }

    # Scenario: An unmanaged file appears after planning and the first pre-transaction validation but before the journal snapshot.
    # Purpose: Bind the transaction snapshot to the planned absent state and preserve the newly created USER bytes without publishing a journal.
    It 'InterT86_rejects_an_unmanaged_file_created_before_the_transaction_snapshot' {
        $caseHome=Join-Path $TestDrive 'transaction-snapshot-create-race'
        $target=Join-Path $caseHome '.agents/skills/alpha/SKILL.md'
        $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'transaction-snapshot-create-stage')

        $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode Apply -BeforeTransactionSnapshotAction {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)|Out-Null
            [IO.File]::WriteAllText($target,'concurrent unmanaged bytes',[Text.UTF8Encoding]::new($false))
        }

        $result.outcome|Should Be 'concurrent'
        [IO.File]::ReadAllText($target)|Should Be 'concurrent unmanaged bytes'
        Test-Path -LiteralPath (Join-Path $caseHome '.agents/catalog-skills.manifest.json')|Should Be $false
        @(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: A managed file is customized after planning and the first pre-transaction validation but before the journal snapshot.
    # Purpose: Reject the stale replacement authorization, preserve the concurrent customization, and create no transaction journal.
    It 'InterT87_rejects_managed_bytes_changed_before_the_transaction_snapshot' {
        $caseHome=Join-Path $TestDrive 'transaction-snapshot-update-race'
        $initial=New-TestDesiredState -Root (Join-Path $TestDrive 'transaction-snapshot-update-initial')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $caseHome -Mode Apply).outcome|Should Be 'applied'
        $next=New-TestDesiredState -Root (Join-Path $TestDrive 'transaction-snapshot-update-next')
        [IO.File]::WriteAllText([string]$next.Files[0].stagedPath,"---`nname: alpha`ndescription: next`n---`n",[Text.UTF8Encoding]::new($false))
        $next.Files[0].sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$next.Files[0].stagedPath)).Hash.ToLowerInvariant()
        $next.Manifest.files[0].sha256=$next.Files[0].sha256
        $target=Join-Path $caseHome '.agents/skills/alpha/SKILL.md'

        $result=Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $caseHome -Mode Apply -BeforeTransactionSnapshotAction {
            [IO.File]::WriteAllText($target,'concurrent customization',[Text.UTF8Encoding]::new($false))
        }

        $result.outcome|Should Be 'concurrent'
        [IO.File]::ReadAllText($target)|Should Be 'concurrent customization'
        @(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: A committed transaction's predictable backup directory is replaced by a junction before recovery exports its original bytes.
    # Purpose: Reject every reparse-backed backup ancestor, preserve the journal, and never write through the junction target.
    It 'InterT88_rejects_a_junction_at_the_committed_backup_path' {
        $caseHome=Join-Path $TestDrive 'committed-backup-junction'
        $initial=New-TestDesiredState -Root (Join-Path $TestDrive 'committed-backup-junction-initial')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $caseHome -Mode Apply).outcome|Should Be 'applied'
        $next=New-TestDesiredState -Root (Join-Path $TestDrive 'committed-backup-junction-next')
        [IO.File]::WriteAllText([string]$next.Files[0].stagedPath,"---`nname: alpha`ndescription: committed next`n---`n",[Text.UTF8Encoding]::new($false))
        $next.Files[0].sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$next.Files[0].stagedPath)).Hash.ToLowerInvariant()
        $next.Manifest.files[0].sha256=$next.Files[0].sha256
        $failed=Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $caseHome -Mode Apply -FailpointName before-committed-cleanup
        $failed.rollbackState|Should Be 'recovery-required'
        $transactions=@(Get-ChildItem -Force -Directory -LiteralPath (Join-Path $caseHome '.ai-instructions-txn'))
        $transactions.Count|Should Be 1
        $transaction=$transactions[0]
        $outside=Join-Path $TestDrive 'committed-backup-junction-outside'
        $backupRoot=Join-Path $caseHome ".agents/backups/update-agent-environment-$($transaction.Name)"
        New-Item -ItemType Directory -Force -Path $outside|Out-Null
        if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){New-Item -ItemType Junction -Path $backupRoot -Target $outside|Out-Null}
        else{New-Item -ItemType SymbolicLink -Path $backupRoot -Target $outside|Out-Null}
        $readLease=New-TestInstallReadLeaseEvidence
        try{$recovery=Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $readLease.Evidence}
        finally{$readLease.Stream.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}

        $recovery.Code|Should BeNullOrEmpty
        $recovery.failureDetails[0].code|Should Be 'recovery-required'
        $recovery.failureDetails[0].path|Should Be '.ai-instructions-txn'
        Test-Path -LiteralPath (Join-Path $transaction.FullName 'journal.json') -PathType Leaf|Should Be $true
        @(Get-ChildItem -Force -LiteralPath $outside).Count|Should Be 0
    }

    # Scenario: An orphan transaction is enumerated before a malformed transaction in the same USER transaction root.
    # Purpose: Classify and validate every residue before purging anything, preserving both entries and USER target bytes on refusal.
    It 'InterT89_preserves_orphan_and_malformed_residue_until_the_complete_preflight_passes' {
        $caseHome=Join-Path $TestDrive 'recovery-preflight-orphan-malformed'
        $target=Join-Path $caseHome '.agents/skills/personal/SKILL.md'
        $orphan=Join-Path $caseHome '.ai-instructions-txn/00000000000000000000000000000000'
        $malformed=Join-Path $caseHome '.ai-instructions-txn/ffffffffffffffffffffffffffffffff'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),$orphan,$malformed|Out-Null
        [IO.File]::WriteAllText($target,'personal-before-recovery',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $malformed 'journal.json'),'{',[Text.UTF8Encoding]::new($false))
        $readLease=New-TestInstallReadLeaseEvidence
        try{$result=Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $readLease.Evidence}
        finally{$readLease.Stream.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}

        $result.Code|Should Be 'interrupted-install'
        Test-Path -LiteralPath $orphan -PathType Container|Should Be $true
        Test-Path -LiteralPath (Join-Path $malformed 'journal.json') -PathType Leaf|Should Be $true
        [IO.File]::ReadAllText($target)|Should Be 'personal-before-recovery'
    }

    # Scenario: A recoverable user-reconciler journal is enumerated before a valid journal owned by another component.
    # Purpose: Apply the F5 component scope to the complete residue set before recovering the first journal or changing USER targets.
    It 'InterT90_preserves_valid_and_foreign_residue_until_the_complete_preflight_passes' {
        $caseHome=Join-Path $TestDrive 'recovery-preflight-valid-foreign'
        $target=Join-Path $caseHome '.agents/skills/personal/SKILL.md'
        $validId='00000000000000000000000000000001';$foreignId='fffffffffffffffffffffffffffffffe'
        $valid=Join-Path $caseHome ".ai-instructions-txn/$validId";$foreign=Join-Path $caseHome ".ai-instructions-txn/$foreignId"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),$valid,$foreign|Out-Null
        [IO.File]::WriteAllText($target,'personal-before-foreign-refusal',[Text.UTF8Encoding]::new($false))
        foreach($fixture in @([pscustomobject]@{Path=$valid;Id=$validId;Owner='user-reconciler'},[pscustomobject]@{Path=$foreign;Id=$foreignId;Owner='installer'})){
            $journal=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String
            $journal.transactionId=$fixture.Id;$journal.owner.component=$fixture.Owner
            [IO.File]::WriteAllText((Join-Path $fixture.Path 'journal.json'),($journal|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        }
        $readLease=New-TestInstallReadLeaseEvidence
        try{$result=Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $readLease.Evidence}
        finally{$readLease.Stream.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}

        $result.Code|Should Be 'interrupted-install'
        Test-Path -LiteralPath (Join-Path $valid 'journal.json') -PathType Leaf|Should Be $true
        Test-Path -LiteralPath (Join-Path $foreign 'journal.json') -PathType Leaf|Should Be $true
        [IO.File]::ReadAllText($target)|Should Be 'personal-before-foreign-refusal'
    }

    # Scenario: Final inventory validation fails after publication while the transaction can still roll back completely.
    # Purpose: Preserve the post-install-integrity-failure detail classification without promoting it to the refusal-only top-level Code.
    It 'InterT91_classifies_rolled_back_final_inventory_failure_as_post_install_integrity_failure' {
        $caseHome=Join-Path $TestDrive 'post-install-integrity-classification'
        $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'post-install-integrity-stage')
        $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode Apply -BeforeFinalVerificationAction {
            $desired.Files[0].sha256='f'*64
        }

        $result.outcome|Should Be 'failed'
        $result.rollbackState|Should Be 'completed'
        $result.Code|Should BeNullOrEmpty
        $result.failureDetails[0].code|Should Be 'post-install-integrity-failure'
        Test-Path -LiteralPath (Join-Path $caseHome '.agents/skills/alpha/SKILL.md')|Should Be $false
        @(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: The stable entry receives a legacy-style general failure result whose top-level Code is not in D16.
    # Purpose: Filter the public entry surface while retaining the operational classification in failureDetails.
    It 'InterT92_filters_non_refusal_top_level_Code_at_the_stable_entry' {
        $entry=Join-Path $script:RepositoryRoot 'scripts/update-agent-environment.ps1'
        $codexHome=Join-Path $TestDrive 'entry-general-code-codex';$userHome=Join-Path $TestDrive 'entry-general-code-user'
        $runtime=Join-Path $codexHome 'hooks/ai-instructions-runtime'
        New-Item -ItemType Directory -Force -Path $runtime,(Join-Path $runtime 'catalog'),$userHome|Out-Null
        Copy-Item -Path (Join-Path $script:RuntimeRoot '*') -Destination $runtime -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') -Destination (Join-Path $runtime 'catalog/skills-catalog.json')
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog-lock.json') -Destination (Join-Path $runtime 'catalog/skills-catalog-lock.json')
        Move-Item -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Destination (Join-Path $runtime 'agent-environment-reconciler-core.ps1')
        @'
. (Join-Path $PSScriptRoot 'agent-environment-reconciler-core.ps1')
function Get-UserSkillsDesiredState { param($RuntimeRoot,$Configuration,$CatalogRepository,$CatalogCommit,$WorkingRoot) [pscustomobject]@{} }
function Invoke-UserSkillsReconciliation {
    param($DesiredState,$UserHome,$Mode,[switch]$ForceReinstallManagedSkills,[switch]$MigrateLegacyCatalogSkills,$InstallReadLease)
    [pscustomobject][ordered]@{schemaVersion=1;outcome='failed';exitCode=1;Code='mutation-failure';catalogCommit=$null;catalogLockSha256=$null;installed=@();updated=@();removed=@();preserved=@();failed=@('injected general failure');failureDetails=@([pscustomobject]@{code='mutation-failure';path='.ai-instructions-txn'});ownership=@();rollbackState='completed';backupPath=$null;licenseWarnings=@()}
}
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
'@|Set-Content -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Encoding UTF8
        $commit='89abcdef0123456789abcdef0123456789abcdef'
        [IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-install.lock'),'')
        [IO.File]::WriteAllText((Join-Path $codexHome 'hooks/bootstrap-ai-instructions.ps1'),"param([switch]`$ValidateOnly)`nif(-not`$ValidateOnly){throw 'ValidateOnly required'}")
        @{schemaVersion=4;catalog=@{ref=$commit}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $codexHome 'ai-instructions-sync.json') -Encoding UTF8
        @{schemaVersion=2;repository='https://github.com/example/ai-instructions.git';commit=$commit}|ConvertTo-Json|Set-Content (Join-Path $runtime 'runtime-bundle.json') -Encoding UTF8

        $output=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $userHome -Apply -OutputFormat Json)
        $LASTEXITCODE|Should Be 1
        $result=$output[-1]|ConvertFrom-Json
        $result.Code|Should BeNullOrEmpty
        $result.failureDetails[0].code|Should Be 'mutation-failure'
    }

    # Scenario: A caller opened the canonical install lock with delete sharing, then the path was replaced after trusted evidence was established but its owned shared lease was lost.
    # Purpose: Rebind every recovery mutation to the evidence identity and the current canonical lock identity before preserving or changing USER state.
    It 'InterT93_rejects_a_replaced_canonical_install_lock_before_recovery_mutation' {
        $caseHome=Join-Path $TestDrive 'replaced-install-lock-recovery'
        $target=Join-Path $caseHome '.agents/skills/personal/SKILL.md'
        $orphan=Join-Path $caseHome '.ai-instructions-txn/0123456789abcdef0123456789abcdef'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),$orphan|Out-Null
        [IO.File]::WriteAllText($target,'personal-before-install-lock-replacement',[Text.UTF8Encoding]::new($false))
        $lockPath=Join-Path $script:RepositoryRoot 'ai-instructions-install.lock'
        $existingBytes=if(Test-Path -LiteralPath $lockPath -PathType Leaf){[IO.File]::ReadAllBytes($lockPath)}else{$null}
        $deleteSharingStream=$null;$trustedEvidence=$null;$staleEvidence=$null
        try{
            [IO.File]::WriteAllText($lockPath,'original-install-lock',[Text.UTF8Encoding]::new($false))
            $deleteSharingStream=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete)
            $trustedEvidence=New-AgentEnvironmentInstallReadLeaseEvidence -Lease $deleteSharingStream
            [object]::ReferenceEquals($trustedEvidence.Stream,$deleteSharingStream)|Should Be $false
            $fileIdentity=[string]$trustedEvidence.FileIdentity
            $trustedEvidence.Dispose();$trustedEvidence=$null
            $staleEvidence=[SyuanTsai.AiInstructions.AgentEnvironmentTrustedInstallReadLease]::new($deleteSharingStream,$lockPath,$script:RuntimeRoot,$fileIdentity)
            [IO.File]::Delete($lockPath)
            [IO.File]::WriteAllText($lockPath,'replacement-install-lock',[Text.UTF8Encoding]::new($false))

            $result=Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $staleEvidence

            $result.Code|Should Be 'interrupted-install'
            Test-Path -LiteralPath $orphan -PathType Container|Should Be $true
            [IO.File]::ReadAllText($target)|Should Be 'personal-before-install-lock-replacement'
            Test-Path -LiteralPath (Join-Path $caseHome '.agents/update-agent-environment.lock')|Should Be $false
        }
        finally{
            if($null-ne$trustedEvidence){$trustedEvidence.Dispose()}
            if($null-ne$staleEvidence){$staleEvidence.Dispose()}
            if($null-ne$deleteSharingStream){$deleteSharingStream.Dispose()}
            if($null-eq$existingBytes){Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue}else{[IO.File]::WriteAllBytes($lockPath,[byte[]]$existingBytes)}
        }
    }

    # Scenario: A fresh-home subtree is durably staged and read back, then the writer dies before publishing its first journal.
    # Purpose: Prove pre-journal recovery sees only a removable orphan while verified payload bytes never reach the USER target.
    It 'InterT94_recovers_a_verified_staged_subtree_orphan_before_journal_publication' {
        $caseHome=Join-Path $TestDrive 'verified-subtree-orphan-home'
        $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'verified-subtree-orphan-stage')
        $desiredPath=Join-Path $TestDrive 'verified-subtree-orphan.clixml';$desired|Export-Clixml -LiteralPath $desiredPath
        $childPath=Join-Path $TestDrive 'verified-subtree-orphan-child.ps1'
        @'
param([string]$ModulePath,[string]$DesiredPath,[string]$UserHome)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$desired=Import-Clixml -LiteralPath $DesiredPath
$env:AI_INSTRUCTIONS_USER_RECONCILER_FAILFAST='after-staged-subtree-verification'
Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $UserHome -Mode Apply -FailpointName after-staged-subtree-verification|Out-Null
'@|Set-Content -LiteralPath $childPath -Encoding UTF8

        & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $childPath $script:ModulePath $desiredPath $caseHome 2>$null
        $LASTEXITCODE|Should Not Be 0
        $target=Join-Path $caseHome '.agents/skills/alpha/SKILL.md'
        Test-Path -LiteralPath $target|Should Be $false
        $transactions=@(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn'))
        $transactions.Count|Should Be 1
        Test-Path -LiteralPath (Join-Path $transactions[0].FullName 'journal.json')|Should Be $false
        $stageRoot=@(Get-ChildItem -Directory -LiteralPath $transactions[0].FullName -Filter 'directory-*')
        $stageRoot.Count|Should Be 1
        $stagedPayloads=@(Get-ChildItem -LiteralPath $stageRoot[0].FullName -Filter 'SKILL.md' -File -Recurse)
        $stagedPayloads.Count|Should Be 1
        $stagedPayload=$stagedPayloads[0].FullName
        (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedPayload).Hash.ToLowerInvariant()|Should Be $desired.Files[0].sha256

        $readLease=New-TestInstallReadLeaseEvidence
        try{$recovered=Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $readLease.Evidence}
        finally{if($null-ne$readLease-and$null-ne$readLease.Evidence){$readLease.Evidence.Dispose()};if($null-ne$readLease-and$readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}
        $recovered.outcome|Should Be 'recovered'
        @(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
        Test-Path -LiteralPath $target|Should Be $false
    }

    It 'installs a clean multi-source selection and becomes idempotent' {
        $desired = New-TestDesiredState -Root $staging -SkillIds @('alpha','beta')
        $first = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $first.outcome | Should Be 'applied'
        @($first.installed).Count | Should Be 2
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\alpha\SKILL.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\beta\SKILL.md') | Should Be $true
        $second = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $second.outcome | Should Be 'current'
        @($second.installed).Count | Should Be 0
        @($second.updated).Count | Should Be 0
    }

    # Scenario: Another installer replaces the legacy manifest with a v3 projection-aware manifest while this updater waits for its lock.
    # Purpose: Ensure the legacy reconciler rereads ownership under the lock and never overwrites the newer manifest or its managed files.
    It 'InterT57_rejects_a_v3_manifest_replaced_while_acquiring_the_lock_without_mutation' {
        $initial = New-TestDesiredState -Root (Join-Path $staging 'initial') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $next = New-TestDesiredState -Root (Join-Path $staging 'next') -SkillIds @('alpha','beta')
        $manifestPath = Join-Path $userHome '.agents\catalog-skills.manifest.json'
        $skillPath = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $v3Bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v3.example.json'))
        $skillBytesBefore = [System.IO.File]::ReadAllBytes($skillPath)
        $result=Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -BeforeLockAcquisitionAction {
                [System.IO.File]::WriteAllBytes($manifestPath,$v3Bytes)
            }
        $result.outcome | Should Be 'concurrent'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestPath)) | Should Be ([Convert]::ToBase64String($v3Bytes))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($skillPath)) | Should Be ([Convert]::ToBase64String($skillBytesBefore))
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\beta\SKILL.md') | Should Be $false
    }

    # Scenario: A projection-aware installer replaces the legacy manifest while recovery waits for the global lock.
    # Purpose: Ensure recovery rereads manifest ownership under the lock before it interprets a journal or restores files.
    It 'InterT57a_rejects_a_v3_manifest_replaced_while_acquiring_the_recovery_lock_without_mutation' {
        $userHome = Join-Path $TestDrive 'recovery-v3-lock-race'
        $desired = New-TestDesiredState -Root (Join-Path $TestDrive 'recovery-v3-lock-race-staging') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $agentsRoot = Join-Path $userHome '.agents'
        $target = Join-Path $agentsRoot 'skills\alpha\SKILL.md'
        $backupRoot = Join-Path $agentsRoot 'backups\recovery-v3-lock-race'
        $backup = Join-Path $backupRoot '.agents\skills\alpha\SKILL.md'
        $journalPath = Join-Path $agentsRoot 'update-agent-environment.recovery.json'
        $manifestPath = Join-Path $agentsRoot 'catalog-skills.manifest.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied bytes')
        [System.IO.File]::WriteAllText($backup,'original bytes')
        $originalSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $appliedSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
            originalSha256=$originalSha256; backupSha256=$originalSha256; appliedSha256=$appliedSha256
        })
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        $journalBytes = [System.IO.File]::ReadAllBytes($journalPath)
        $v3Bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v3.example.json'))
        $result=Invoke-UserSkillsRecovery -UserHome $userHome -BeforeLockAcquisitionAction {
                [System.IO.File]::WriteAllBytes($manifestPath,$v3Bytes)
            }
        $result.outcome | Should Be 'concurrent'
        [System.IO.File]::ReadAllText($target) | Should Be 'applied bytes'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($journalPath)) | Should Be ([Convert]::ToBase64String($journalBytes))
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestPath)) | Should Be ([Convert]::ToBase64String($v3Bytes))
    }

    It 'preserves an unmanaged personal Skill outside the Catalog' {
        $personal = Join-Path $userHome '.agents\skills\personal\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $personal) | Out-Null
        [System.IO.File]::WriteAllText($personal,'personal')
        $desired = New-TestDesiredState -Root $staging
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        [System.IO.File]::ReadAllText($personal) | Should Be 'personal'
    }

    It 'preserves an empty unmanaged personal Skill directory during managed cleanup' {
        $personal = Join-Path $userHome '.agents\skills\personal-empty'
        New-Item -ItemType Directory -Force -Path $personal | Out-Null
        $initial = New-TestDesiredState -Root (Join-Path $staging 'initial') -SkillIds @('alpha','beta')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $next = New-TestDesiredState -Root (Join-Path $staging 'next') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        Test-Path -LiteralPath $personal -PathType Container | Should Be $true
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\beta') | Should Be $false
    }

    # Scenario: A path named like a Catalog Skill already contains bytes with no managed-manifest or explicit legacy proof.
    # Purpose: Verify the collision is blocked and the result exposes ownership evidence and remediation before any mutation.
    It 'InterT35_reports_unmanaged_collision_and_requires_explicit_legacy_migration' {
        $legacy = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy) | Out-Null
        [System.IO.File]::WriteAllText($legacy,'legacy')
        $desired = New-TestDesiredState -Root $staging
        $blocked = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $blocked.outcome | Should Be 'failed'
        @($blocked.failureDetails).Count | Should Be 1
        $detail = @($blocked.failureDetails)[0]
        $detail.code | Should Be 'unmanaged-collision'
        $detail.classification | Should Be 'unmanaged-unknown'
        $detail.path | Should Be '.agents/skills/alpha/SKILL.md'
        $detail.destructiveChangeAllowed | Should Be $false
        @($detail.remediation).Count | Should BeGreaterThan 0
        [System.IO.File]::ReadAllText($legacy) | Should Be 'legacy'
        $migrated = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -MigrateLegacyCatalogSkills
        $migrated.outcome | Should Be 'applied'
        [System.IO.File]::ReadAllText($legacy) | Should Match 'name: alpha'
        Test-Path -LiteralPath $migrated.backupPath | Should Be $true
    }

    # Scenario: An explicit Catalog lifecycle alias points an old managed directory at the current Skill ID.
    # Purpose: Verify alias evidence permits only the proven legacy path to be removed and is retained in the result.
    It 'InterT45_reports_known_legacy_ownership_for_alias_replacement' {
        $legacy = Join-Path $userHome '.agents\skills\old-alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy) | Out-Null
        [System.IO.File]::WriteAllText($legacy,'legacy alias')
        $desired = New-TestDesiredState -Root $staging -Aliases @{ alpha=@('old-alpha') }
        $result = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -MigrateLegacyCatalogSkills
        $result.outcome | Should Be 'applied'
        Test-Path -LiteralPath $legacy | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\alpha\SKILL.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $result.backupPath '.agents\skills\old-alpha\SKILL.md') | Should Be $true
        $legacyEvidence = @($result.ownership | Where-Object { $_.path -ceq '.agents/skills/old-alpha/SKILL.md' })
        $legacyEvidence.Count | Should Be 1
        $legacyEvidence[0].classification | Should Be 'known-legacy'
        $legacyEvidence[0].owner | Should Be 'catalog-lifecycle'
        $legacyEvidence[0].destructiveChangeAllowed | Should Be $true
        $legacyEvidence[0].evidence | Should Match 'lifecycle-alias'
    }

    # Scenario: A controlled candidate exposes an absolute target path before user-environment mutation.
    # Purpose: Keep structured unsafe-path evidence schema-valid while preserving the raw rejected input for diagnosis.
    It 'InterT50_reports_a_schema_safe_path_for_an_unsafe_candidate' {
        $unsafePath = 'C:\outside\SKILL.md'
        $desired = New-TestDesiredState -Root $staging
        $desired.Files[0].targetPath = $unsafePath
        $desired.Manifest.files[0].targetPath = $unsafePath

        $result = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply

        $result.outcome | Should Be 'failed'
        @($result.failureDetails).Count | Should Be 1
        $detail = @($result.failureDetails)[0]
        $detail.code | Should Be 'unsafe-target-path'
        $detail.path | Should Be '.agents/skills/<rejected-target-path>'
        $detail.evidence | Should Match 'C:\\outside\\SKILL\.md'
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\alpha\SKILL.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\backups') | Should Be $false
    }

    # Scenario: The immutable candidate changes at its original staging path after reconciliation preflight has completed.
    # Purpose: Verify writes use the transaction-owned preflight snapshot instead of a mutable staging path.
    It 'InterT40_writes_from_a_transaction_owned_candidate_snapshot' {
        $desired = New-TestDesiredState -Root $staging
        $expectedSha = [string]$desired.Files[0].sha256
        $result = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -BeforeBackupValidationAction {
            [System.IO.File]::WriteAllText([string]$desired.Files[0].stagedPath,'candidate drift after preflight')
        }

        $result.outcome | Should Be 'applied'
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $userHome '.agents\skills\alpha\SKILL.md')).Hash.ToLowerInvariant() | Should Be $expectedSha
        (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$desired.Files[0].stagedPath)).Hash.ToLowerInvariant() | Should Not Be $expectedSha
    }

    # Scenario: The candidate inventory records one SHA-256 while its staged bytes are tampered before any target exists.
    # Purpose: Verify integrity failure is fail-closed, structured, and occurs before backup or consumer mutation.
    It 'InterT30_rejects_a_tampered_staged_candidate_before_target_mutation' {
        $desired = New-TestDesiredState -Root $staging
        [System.IO.File]::WriteAllText([string]$desired.Files[0].stagedPath,'tampered candidate')

        $result = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply

        $result.outcome | Should Be 'failed'
        @($result.failureDetails).Count | Should Be 1
        $detail = @($result.failureDetails)[0]
        $detail.code | Should Be 'staged-integrity-mismatch'
        $detail.classification | Should Be 'controlled-candidate'
        $detail.path | Should Be '.agents/skills/alpha/SKILL.md'
        $detail.destructiveChangeAllowed | Should Be $false
        $detail.backupCreated | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\alpha\SKILL.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\backups') | Should Be $false
    }

    # Scenario: The desired user manifest and candidate file inventory disagree on the same target hash.
    # Purpose: Verify manifest transition is blocked before consumer mutation instead of creating a self-inconsistent install.
    It 'InterT32_rejects_a_desired_manifest_inventory_mismatch' {
        $desired = New-TestDesiredState -Root $staging
        $desired.Manifest.files[0].sha256 = ('b' * 64)

        $result = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply

        $result.outcome | Should Be 'failed'
        @($result.failureDetails).Count | Should Be 1
        $detail = @($result.failureDetails)[0]
        $detail.code | Should Be 'desired-manifest-mismatch'
        $detail.path | Should Be '.agents/catalog-skills.manifest.json'
        $detail.destructiveChangeAllowed | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\alpha\SKILL.md') | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\backups') | Should Be $false
    }

    It 'fails closed without deleting an unmanaged file mixed into an explicit legacy migration' {
        $legacy = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $personal = Join-Path $userHome '.agents\skills\alpha\notes.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy) | Out-Null
        [System.IO.File]::WriteAllText($legacy,'legacy')
        [System.IO.File]::WriteAllText($personal,'personal notes')
        $desired = New-TestDesiredState -Root $staging

        $result = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -MigrateLegacyCatalogSkills

        $result.outcome | Should Be 'failed'
        ($result.failed -join [Environment]::NewLine) | Should Match 'unmanaged file.*notes\.md'
        [System.IO.File]::ReadAllText($legacy) | Should Be 'legacy'
        [System.IO.File]::ReadAllText($personal) | Should Be 'personal notes'
        Test-Path -LiteralPath (Join-Path $userHome '.agents\catalog-skills.manifest.json') | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\backups') | Should Be $false
    }

    It 'prunes a previously managed Skill without touching other directories' {
        $initial = New-TestDesiredState -Root (Join-Path $staging 'initial') -SkillIds @('alpha','beta')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $next = New-TestDesiredState -Root (Join-Path $staging 'next') -SkillIds @('alpha')
        $result = Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply
        $result.outcome | Should Be 'applied'
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\beta\SKILL.md') | Should Be $false
    }

    It 'requires force before replacing a customized managed file' {
        $desired = New-TestDesiredState -Root $staging
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $manifestPath = Join-Path $userHome '.agents\catalog-skills.manifest.json'
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        [System.IO.File]::WriteAllText($target,'customized')
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'failed'
        $forced = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -ForceReinstallManagedSkills
        $forced.outcome | Should Be 'applied'
        [System.IO.File]::ReadAllText($target) | Should Match 'name: alpha'

        # A target edit in the deterministic planning-to-backup gap must not become the rollback baseline.
        $next = New-TestDesiredState -Root (Join-Path $staging 'race-target')
        [System.IO.File]::AppendAllText([string]$next.Files[0].stagedPath,"`nchanged")
        $nextSha = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$next.Files[0].stagedPath)).Hash.ToLowerInvariant()
        $next.Files[0].sha256 = $nextSha
        $next.Manifest.files[0].sha256 = $nextSha
        $backupCount = @(Get-ChildItem -LiteralPath (Join-Path $userHome '.agents\backups') -Directory).Count
        { Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -BeforeBackupValidationAction {
            [System.IO.File]::WriteAllText($target,'concurrent target edit')
        } } | Should Throw
        [System.IO.File]::ReadAllText($target) | Should Be 'concurrent target edit'
        Test-Path -LiteralPath $journalPath | Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $userHome '.agents\backups') -Directory).Count | Should Be $backupCount

        # The manifest participates in the same observation contract.
        [System.IO.File]::WriteAllBytes($target,[System.IO.File]::ReadAllBytes([string]$desired.Files[0].stagedPath))
        $manifestBeforeRace = [System.IO.File]::ReadAllText($manifestPath)
        { Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -BeforeBackupValidationAction {
            [System.IO.File]::AppendAllText($manifestPath,' ')
        } } | Should Throw
        [System.IO.File]::ReadAllText($manifestPath) | Should Be ($manifestBeforeRace + ' ')
        [System.IO.File]::ReadAllText($target) | Should Match 'name: alpha'
        Test-Path -LiteralPath $journalPath | Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $userHome '.agents\backups') -Directory).Count | Should Be $backupCount
    }

    # Scenario: A transaction mutation fails after a managed target is prepared.
    # Purpose: Verify rollback restores the prior managed bytes, classifies the mutation failure, and removes the completed journal.
    It 'InterT25_rolls_back_when_a_mutation_fails_and_leaves_the_prior_manifest_valid' {
        $initial = New-TestDesiredState -Root (Join-Path $staging 'initial') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $before = [System.IO.File]::ReadAllText($target)
        $next = New-TestDesiredState -Root (Join-Path $staging 'next') -SkillIds @('alpha','beta')
        $failed = Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -FailureAfterMutationCount 1
        $failed.outcome | Should Be 'failed'
        $failed.rollbackState | Should Be 'completed'
        $failed.Code | Should BeNullOrEmpty
        @($failed.failureDetails | Where-Object { $_.code -eq 'mutation-failure' }).Count | Should Be 1
        [System.IO.File]::ReadAllText($target) | Should Be $before
        Test-Path -LiteralPath (Join-Path $userHome '.agents\update-agent-environment.recovery.json') | Should Be $false
    }

    # Scenario: Rollback restores every transaction state, but the transaction directory cannot be deleted.
    # Purpose: Verify retained journal evidence changes the result to recovery-required instead of falsely reporting completed rollback.
    Context 'InterT26 isolated transaction cleanup mock' {
    It 'InterT26_reports_recovery_required_when_rollback_journal_cleanup_fails' {
        $initial = New-TestDesiredState -Root (Join-Path $staging 'initial') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $next = New-TestDesiredState -Root (Join-Path $staging 'next') -SkillIds @('alpha','beta')
        Mock Remove-PlatformOwnedDirectoryTree { throw 'Injected transaction cleanup failure.' } -ModuleName agent-environment-reconciler
        $failed = Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -FailureAfterMutationCount 1

        $failed.outcome | Should Be 'failed'
        $failed.rollbackState | Should Be 'recovery-required'
        @($failed.failureDetails | Where-Object { $_.code -eq 'recovery-required' }).Count | Should Be 1
        ($failed.failureDetails[0].evidence) | Should Match 'Recovery journal cleanup failed'
        Test-Path -LiteralPath (Join-Path $failed.backupPath 'journal.json') -PathType Leaf | Should Be $true
    }
    }

    # Scenario: Rollback itself is interrupted after the mutation failure.
    # Purpose: Preserve the install journal and classify the result as recovery-required instead of claiming completed rollback.
    It 'InterT27_reports_recovery_required_when_install_journal_rollback_is_interrupted' {
        $initial = New-TestDesiredState -Root (Join-Path $staging 'rollback-initial') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $next = New-TestDesiredState -Root (Join-Path $staging 'rollback-next') -SkillIds @('alpha','beta')
        $failed = Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -FailureAfterMutationCount 1 -FailpointName during-rollback
        $failed.outcome | Should Be 'failed'
        $failed.rollbackState | Should Be 'recovery-required'
        ($failed.failureDetails[0].evidence) | Should Match 'Rollback failed'
        Test-Path -LiteralPath (Join-Path $failed.backupPath 'journal.json') -PathType Leaf | Should Be $true
    }

    It 'reports drift in VerifyOnly and a plan in WhatIf without writing' {
        $desired = New-TestDesiredState -Root $staging
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode VerifyOnly).outcome | Should Be 'drift'
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode WhatIf).outcome | Should Be 'planned'
        Test-Path -LiteralPath (Join-Path $userHome '.agents') | Should Be $false
    }

    # Scenario: Read-only reconciliation starts with either no .agents directory or a physical .agents directory without a lock leaf.
    # Purpose: Preserve the complete USER tree and never call the create-on-open lock primitive in VerifyOnly or WhatIf.
    It 'InterT96_keeps_read_only_lock_absence_zero_mutation' {
        $desired=New-TestDesiredState -Root (Join-Path $staging 'read-only-lock-absence')
        foreach($layout in @('no-agents','agents-without-lock')){
            foreach($mode in @('VerifyOnly','WhatIf')){
                $caseHome=Join-Path $TestDrive "read-only-$layout-$mode";New-Item -ItemType Directory -Path $caseHome|Out-Null
                if($layout-ceq'agents-without-lock'){New-Item -ItemType Directory -Path (Join-Path $caseHome '.agents')|Out-Null}
                $before=Get-TestTreeSnapshot $caseHome
                $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode $mode
                if($mode-ceq'VerifyOnly'){$result.outcome|Should Be 'drift'}else{$result.outcome|Should Be 'planned'}
                (Get-TestTreeSnapshot $caseHome)|Should Be $before
                Test-Path -LiteralPath (Join-Path $caseHome '.agents/update-agent-environment.lock')|Should Be $false
            }
        }
    }

    It 'returns concurrent when the global user-scope lock is already held' {
        $desired = New-TestDesiredState -Root $staging
        $agents = Join-Path $userHome '.agents'
        New-Item -ItemType Directory -Force -Path (Join-Path $agents 'skills') | Out-Null
        $lockPath=Join-Path $agents 'update-agent-environment.lock'
        [IO.File]::WriteAllText($lockPath,'')
        $before=Get-TestTreeSnapshot $userHome
        $stream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try { $result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply }
        finally { $stream.Dispose() }
        $result.outcome | Should Be 'concurrent'
        (Get-TestTreeSnapshot $userHome)|Should Be $before
    }

    # Scenario: The P8 platform lock is held before a legacy File.Open contender starts.
    # Purpose: Prove the unchanged Windows FileShare.None protocol excludes legacy callers in the reverse direction too.
    if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
        It 'InterT73_blocks_legacy_FileOpen_while_Enter_PlatformLock_is_held' {
        $agents=Join-Path $userHome '.agents'
        New-Item -ItemType Directory -Force -Path $agents|Out-Null
        Import-Module (Join-Path $script:RuntimeRoot 'platform-runtime.psm1') -Force
        $parent=$null;$platformLock=$null
        try {
            $parent=Open-PlatformDirectory -Root $userHome -RelativePath '.agents'
            $platformLock=Enter-PlatformLock -ParentLease $parent -Leaf 'update-agent-environment.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            { $legacy=[IO.File]::Open((Join-Path $agents 'update-agent-environment.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$legacy.Dispose() } | Should Throw
        }
        finally {
            if($null-ne$platformLock){$platformLock.Dispose()}
            if($null-ne$parent){$parent.Dispose()}
        }
        }

        # Scenario: Bootstrap native, legacy File.Open, and platform lock implementations contend in separate processes.
        # Purpose: Prove every pair is mutually exclusive in both holder/contender directions on the unchanged USER lock file.
        It 'InterT73a_proves_three_way_USER_lock_interop_in_both_directions' {
            $probe=Join-Path $TestDrive 'three-way-lock-probe.ps1'
            @'
param([string]$Protocol,[string]$Mode,[string]$UserHome,[string]$Bootstrap,[string]$PlatformManifest,[string]$Signal,[string]$Release)
$ErrorActionPreference='Stop';$agents=Join-Path $UserHome '.agents';New-Item -ItemType Directory -Force -Path $agents|Out-Null
function Open-ProbeLock([string]$Kind){
    if($Kind-ceq'legacy'){return [IO.File]::Open((Join-Path $agents 'update-agent-environment.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    if($Kind-ceq'platform'){Import-Module $PlatformManifest -Force;$parent=Open-PlatformDirectory -Root $UserHome -RelativePath '.agents';try{$stream=Enter-PlatformLock -ParentLease $parent -Leaf 'update-agent-environment.lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero);return [pscustomobject]@{Stream=$stream;Parent=$parent}}catch{$parent.Dispose();throw}}
    $text=[IO.File]::ReadAllText($Bootstrap);$end=$text.IndexOf('$syncStartPath = ',[StringComparison]::Ordinal);if($end-lt0){throw 'bootstrap prefix boundary missing'}
    $root=Split-Path -Parent $Bootstrap;$literal="'"+$root.Replace("'","''")+"'";$prefix=[scriptblock]::Create($text.Substring(0,$end).Replace('$PSScriptRoot',$literal));. $prefix -TargetRoot $UserHome -UserHome $UserHome -GitExecutable git|Out-Null
    return Open-UserSkillMigrationLock -UserHome $UserHome
}
$lease=$null
try{
    $lease=Open-ProbeLock $Protocol
    if($Mode-ceq'contender'){'acquired';exit 0}
    [IO.File]::WriteAllText($Signal,'held')
    $deadline=[DateTime]::UtcNow.AddSeconds(20);while(-not(Test-Path -LiteralPath $Release)){if([DateTime]::UtcNow-ge$deadline){throw 'release timeout'};Start-Sleep -Milliseconds 25}
}catch{if($Mode-ceq'contender'){'blocked';exit 3};throw}
finally{if($null-ne$lease){if($lease.PSObject.Properties['Stream']){$lease.Stream.Dispose();if($lease.PSObject.Properties['Guard']){$lease.Guard.Dispose()};if($lease.PSObject.Properties['Parent']){$lease.Parent.Dispose()}}else{$lease.Dispose()}}}
'@|Set-Content -LiteralPath $probe -Encoding UTF8
            $protocols=@('bootstrap','legacy','platform');$cases=@();foreach($holder in $protocols){foreach($contender in $protocols){if($holder-cne$contender){$cases+=,[pscustomobject]@{Holder=$holder;Contender=$contender}}}}
            foreach($case in $cases){
                $caseHome=Join-Path $TestDrive ("lock-$($case.Holder)-$($case.Contender)");$signal=Join-Path $caseHome 'held.signal';$release=Join-Path $caseHome 'release.signal';New-Item -ItemType Directory -Path $caseHome|Out-Null
                $holder=Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$probe,$case.Holder,'holder',$caseHome,(Join-Path $script:RuntimeRoot 'bootstrap-ai-instructions.ps1'),(Join-Path $script:RuntimeRoot 'platform-runtime.psd1'),$signal,$release) -WindowStyle Hidden -PassThru
                try{
                    $deadline=[DateTime]::UtcNow.AddSeconds(20);while(-not(Test-Path -LiteralPath $signal)){if($holder.HasExited){throw "holder exited: $($holder.ExitCode)"};if([DateTime]::UtcNow-ge$deadline){throw 'holder signal timeout'};Start-Sleep -Milliseconds 25}
                    $output=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $probe $case.Contender contender $caseHome (Join-Path $script:RuntimeRoot 'bootstrap-ai-instructions.ps1') (Join-Path $script:RuntimeRoot 'platform-runtime.psd1') $signal $release)
                    $LASTEXITCODE|Should Be 3
                    $output[-1]|Should Be 'blocked'
                }finally{[IO.File]::WriteAllText($release,'release');$holder.WaitForExit(20000)|Out-Null;if(-not$holder.HasExited){$holder.Kill()};$holder.Dispose()}
            }
        }
    }

    It 'rejects an unsafe lock path before reconciliation' {
        $desired = New-TestDesiredState -Root $staging
        $lockPath = Join-Path $userHome '.agents\update-agent-environment.lock'
        New-Item -ItemType Directory -Force -Path $lockPath | Out-Null
        { Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply } | Should Throw
    }

    It 'recovers an interrupted transaction from its persistent journal' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-test\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($backup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $backupRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
            originalSha256=$originalSha; backupSha256=$originalSha; appliedSha256=$appliedSha
        })
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        $result = Invoke-UserSkillsRecovery -UserHome $userHome
        $result.outcome | Should Be 'recovered'
        [System.IO.File]::ReadAllText($target) | Should Be 'original'
        Test-Path -LiteralPath $journalPath | Should Be $false
    }

    # Scenario: A runtime upgrade encounters a valid predecessor v1 recovery journal without current transaction metadata.
    # Purpose: Preserve crash recovery across runtime upgrades while retaining the current managed-path and backup-integrity boundaries.
    It 'InterT65_recovers_a_preupgrade_v1_journal_after_runtime_update' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-legacy-v1\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($backup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $backupRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=$backupRoot
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
                originalSha256=$originalSha; appliedSha256=$appliedSha
            })
        }
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        $result = Invoke-UserSkillsRecovery -UserHome $userHome

        $result.outcome | Should Be 'recovered'
        [System.IO.File]::ReadAllText($target) | Should Be 'original'
        Test-Path -LiteralPath $journalPath | Should Be $false
    }

    # Scenario: A runtime upgrade encounters a valid predecessor v1 recovery journal for a target that did not exist before mutation.
    # Purpose: Remove an interrupted first-install target without reading the absent legacy backupSha256 property under StrictMode.
    It 'InterT65b_recovers_a_preupgrade_v1_journal_for_an_absent_target' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backupRoot = Join-Path $userHome '.agents\backups\recovery-legacy-absent'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),$backupRoot | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=$backupRoot
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$false; backupPath=$null
                originalSha256=$null; appliedSha256=$appliedSha
            })
        }
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        $result = Invoke-UserSkillsRecovery -UserHome $userHome

        $result.outcome | Should Be 'recovered'
        Test-Path -LiteralPath $target | Should Be $false
        Test-Path -LiteralPath $journalPath | Should Be $false
    }

    # Scenario: Recovery restores the target but cannot remove the predecessor or current recovery journal.
    # Purpose: Verify recovery cleanup failures are structured as recovery-required instead of returning a false recovered success.
    It 'InterT66_reports_recovery_required_when_recovery_journal_cleanup_fails' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-cleanup-failure\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($backup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $backupRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
            originalSha256=$originalSha; backupSha256=$originalSha; appliedSha256=$appliedSha
        })
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        try {
            Mock Remove-AgentEnvironmentRecoveryJournal { throw 'Injected recovery journal cleanup failure.' } -ModuleName agent-environment-reconciler

            $result = Invoke-UserSkillsRecovery -UserHome $userHome
        }
        finally {
            Import-Module $script:ModulePath -Force
        }

        Assert-TestRecoveryFailureResult -Result $result
        [System.IO.File]::ReadAllText($target) | Should Be 'original'
        Test-Path -LiteralPath $journalPath -PathType Leaf | Should Be $true
    }

    It 'rejects a tampered recovery backup without replacing the applied target or deleting the journal' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-tampered\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($backup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($backup,'tampered')
        $backupRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
            originalSha256=$originalSha; backupSha256=$originalSha; appliedSha256=$appliedSha
        })
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        $result = Invoke-UserSkillsRecovery -UserHome $userHome
        Assert-TestRecoveryFailureResult -Result $result
        [System.IO.File]::ReadAllText($target) | Should Be 'applied'
        Test-Path -LiteralPath $journalPath | Should Be $true
    }

    It 'rejects a malformed journaled original hash before reading recovery backup bytes' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-corrupt-hash\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($backup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $backupRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
            originalSha256='not-a-sha256'; backupSha256='not-a-sha256'; appliedSha256=$appliedSha
        })
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        $result = Invoke-UserSkillsRecovery -UserHome $userHome
        Assert-TestRecoveryFailureResult -Result $result
        [System.IO.File]::ReadAllText($target) | Should Be 'applied'
        Test-Path -LiteralPath $journalPath | Should Be $true
    }

    It 'rejects string or array recovery state booleans without mutating the target or deleting the journal' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-boolean\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($backup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $backupRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $invalidBooleans = New-Object System.Collections.Generic.List[object]
        $invalidBooleans.Add('true')
        $invalidBooleans.Add([object[]]@($true))

        foreach ($invalidBoolean in $invalidBooleans) {
            $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$invalidBoolean; backupPath=$backup
                originalSha256=$originalSha; backupSha256=$originalSha; appliedSha256=$appliedSha
            })
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

            $result = Invoke-UserSkillsRecovery -UserHome $userHome
            Assert-TestRecoveryFailureResult -Result $result
            [System.IO.File]::ReadAllText($target) | Should Be 'applied'
            Test-Path -LiteralPath $journalPath | Should Be $true
        }
    }

    It 'rejects an empty recovery state array and preserves the journal' {
        $backupRoot = Join-Path $userHome '.agents\backups\recovery-empty'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @()
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        $result = Invoke-UserSkillsRecovery -UserHome $userHome
        Assert-TestRecoveryFailureResult -Result $result
        Test-Path -LiteralPath $journalPath | Should Be $true
    }

    It 'preserves a concurrent edit instead of overwriting it during recovery' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-drift\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'concurrent')
        [System.IO.File]::WriteAllText($backup,'original')
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $backupRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup)))
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $backupRoot -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
            originalSha256=$originalSha; backupSha256=$originalSha; appliedSha256=('2' * 64)
        })
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        $result = Invoke-UserSkillsRecovery -UserHome $userHome
        Assert-TestRecoveryFailureResult -Result $result
        [System.IO.File]::ReadAllText($target) | Should Be 'concurrent'
        Test-Path -LiteralPath $journalPath | Should Be $true
    }

    It 'rejects a recovery backup outside the Agent environment backup root' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $outsideBackup = Join-Path $userHome 'outside-backup.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Join-Path $userHome '.agents\backups') | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($outsideBackup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $outsideBackup).Hash.ToLowerInvariant()
        $journal = New-TestRecoveryJournal -UserHome $userHome -BackupRoot $userHome -States @([pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$outsideBackup
            originalSha256=$originalSha; backupSha256=$originalSha; appliedSha256=$appliedSha
        })
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        $result = Invoke-UserSkillsRecovery -UserHome $userHome
        Assert-TestRecoveryFailureResult -Result $result
        [System.IO.File]::ReadAllText($target) | Should Be 'applied'
        Test-Path -LiteralPath $journalPath | Should Be $true
    }

    # Scenario: An invalid recovery journal is present while the user-scope recovery lock is already held.
    # Purpose: Verify ordinary lock contention returns the documented concurrent result without interpreting or replacing the preserved journal.
    It 'InterT55_returns_concurrent_when_the_recovery_global_lock_is_already_held' {
        $backupRoot = Join-Path $userHome '.agents\backups\recovery-concurrent'
        $agentsRoot = Join-Path $userHome '.agents'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $journalPath = Join-Path $agentsRoot 'update-agent-environment.recovery.json'
        [System.IO.File]::WriteAllText($journalPath,'{}')
        $lockPath = Join-Path $agentsRoot 'update-agent-environment.lock'
        $stream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try {
            $result = Invoke-UserSkillsRecovery -UserHome $userHome
            Assert-TestRecoveryConcurrentResult -Result $result
        }
        finally { $stream.Dispose() }
        Test-Path -LiteralPath $journalPath -PathType Leaf | Should Be $true
    }

    # Scenario: Public legacy recovery sees retained residue while the managed manifest is malformed.
    # Purpose: Convert the pre-lock manifest snapshot failure into structured recovery evidence without creating a lock or mutating USER bytes.
    It 'InterT102_returns_structured_failure_for_a_malformed_prelock_manifest_snapshot' {
        $caseHome=Join-Path $TestDrive 'recovery-malformed-manifest'
        $agentsRoot=Join-Path $caseHome '.agents'
        New-Item -ItemType Directory -Force -Path $agentsRoot|Out-Null
        $manifestPath=Join-Path $agentsRoot 'catalog-skills.manifest.json'
        $journalPath=Join-Path $agentsRoot 'update-agent-environment.recovery.json'
        [IO.File]::WriteAllText($manifestPath,'{"schemaVersion":')
        [IO.File]::WriteAllText($journalPath,'{}')
        $before=Get-TestTreeSnapshot $caseHome

        $result=Invoke-UserSkillsRecovery -UserHome $caseHome

        Assert-TestRecoveryFailureResult -Result $result
        @($result.failed)[0]|Should Match 'managed manifest is not valid JSON'
        (Get-TestTreeSnapshot $caseHome)|Should Be $before
        Test-Path -LiteralPath (Join-Path $agentsRoot 'update-agent-environment.lock')|Should Be $false
    }
}

Describe 'user Skills managed manifest contract' {
    BeforeEach { Import-Module $script:ContractPath -Force }

    It 'accepts the checked-in example' {
        $example = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v1.example.json') | ConvertFrom-Json
        { Assert-UserSkillsManagedManifestV1 -Manifest $example } | Should Not Throw
    }

    It 'accepts_the_canonical_source_version_2_example_with_the_flat_runtime_target' {
        $example = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v2.example.json') | ConvertFrom-Json
        { Assert-UserSkillsManagedManifest -Manifest $example } | Should Not Throw
        @($example.files)[0].sourcePath | Should Match '^skills/work-with-jira/'
        @($example.files)[0].targetPath | Should Match '^\.agents/skills/work-with-jira/'
    }

    It 'rejects ownership outside the user Skills root' {
        $desired = New-TestDesiredState -Root (Join-Path $TestDrive 'contract')
        $desired.Manifest.files[0].targetPath = 'Documents/SKILL.md'
        { Assert-UserSkillsManagedManifestV1 -Manifest $desired.Manifest } | Should Throw
    }
}

Describe 'Agent environment stable entry point' {
    It 'returns one machine-readable failed result and a nonzero child process exit code for invalid switches' {
        $entry = Join-Path $script:RepositoryRoot 'scripts\update-agent-environment.ps1'
        $output = @(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -Apply -VerifyOnly -OutputFormat Json)
        $exitCode = $LASTEXITCODE

        $exitCode | Should Be 1
        $output.Count | Should Be 1
        $result = $output[0] | ConvertFrom-Json
        $result.outcome | Should Be 'failed'
        [int]$result.exitCode | Should Be 1
        @($result.failed).Count | Should Be 1
    }

    # Scenario: Installed generation metadata is invalid while the installer exclusively owns the canonical runtime lock.
    # Purpose: Use invalid metadata as a read sentinel and prove the stable entry attempts the read lock before touching either metadata file.
    It 'InterT99_acquires_the_runtime_read_lock_before_reading_generation_metadata' {
        $entry=Join-Path $script:RepositoryRoot 'scripts/update-agent-environment.ps1'
        $codexHome=Join-Path $TestDrive 'entry-lock-before-metadata'
        $runtimeRoot=Join-Path $codexHome 'hooks/ai-instructions-runtime'
        [void][IO.Directory]::CreateDirectory($runtimeRoot)
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'agent-environment-reconciler.psm1'),'# metadata-order fixture')
        [IO.File]::WriteAllText((Join-Path $codexHome 'hooks/bootstrap-ai-instructions.ps1'),'param([switch]$ValidateOnly)')
        [IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-sync.json'),'{')
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'runtime-bundle.json'),'{')
        $installLockPath=Join-Path $codexHome 'ai-instructions-install.lock'
        [IO.File]::WriteAllText($installLockPath,'')
        $exclusive=[IO.File]::Open($installLockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{$lockedOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome (Join-Path $TestDrive 'entry-lock-user') -VerifyOnly -OutputFormat Json);$lockedExit=$LASTEXITCODE}
        finally{$exclusive.Dispose()}

        $lockedExit|Should Be 1
        $lockedResult=$lockedOutput[-1]|ConvertFrom-Json
        $lockedResult.Code|Should BeNullOrEmpty
        $lockedResult.failed[0]|Should Match 'runtime is being installed'

        $metadataOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome (Join-Path $TestDrive 'entry-metadata-user') -VerifyOnly -OutputFormat Json)
        $LASTEXITCODE|Should Be 1
        ($metadataOutput[-1]|ConvertFrom-Json).Code|Should Be 'unsupported-version'
    }

    # Scenario: The installed recovery entry point reads an existing v2 manifest without a recovery journal.
    # Purpose: Ensure the reconciler loads its contract validator itself in a fresh PowerShell process.
    It 'InterT59_recovers_a_v2_manifest_without_a_preimported_contract_module' {
        $entry = Join-Path $script:RepositoryRoot 'scripts\update-agent-environment.ps1'
        $codexHome = Join-Path $TestDrive ('recovery-v2-codex-' + [Guid]::NewGuid().ToString('N'))
        $userHome = Join-Path $TestDrive ('recovery-v2-user-' + [Guid]::NewGuid().ToString('N'))
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        New-Item -ItemType Directory -Force -Path $runtimeRoot,(Join-Path $userHome '.agents') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-install.lock'),'')
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'), @'
[CmdletBinding()]
param([switch]$ValidateOnly)
if (-not $ValidateOnly) { throw 'Validation switch required.' }
'@)
        Copy-Item -LiteralPath $script:ModulePath -Destination (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Force
        Copy-Item -LiteralPath $script:ContractPath -Destination (Join-Path $runtimeRoot 'skills-catalog-contract.psm1') -Force
        Copy-TestRecoveryRuntimeDependencies -Destination $runtimeRoot
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v2.example.json') -Destination (Join-Path $userHome '.agents\catalog-skills.manifest.json') -Force
        $stderrPath = Join-Path $TestDrive ('recovery-v2-stderr-' + [Guid]::NewGuid().ToString('N') + '.log')

        $output = @(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry `
            -CodexHome $codexHome -UserHome $userHome -Recover -OutputFormat Json 2> $stderrPath)
        $exitCode = $LASTEXITCODE

        $exitCode | Should Be 0
        $output.Count | Should Be 1
        ($output[0] | ConvertFrom-Json).outcome | Should Be 'nothing-to-recover'
        ([System.IO.File]::ReadAllText($stderrPath)).Contains('is not recognized') | Should Be $false
    }

    # Scenario: The installed recovery entry point reads a valid v3 manifest without a recovery journal.
    # Purpose: Ensure recovery returns nothing-to-recover without validating the projection-aware manifest.
    It 'InterT59b_recovers_a_v3_manifest_without_a_recovery_journal' {
        $entry = Join-Path $script:RepositoryRoot 'scripts\update-agent-environment.ps1'
        $codexHome = Join-Path $TestDrive ('recovery-v3-codex-' + [Guid]::NewGuid().ToString('N'))
        $userHome = Join-Path $TestDrive ('recovery-v3-user-' + [Guid]::NewGuid().ToString('N'))
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        $agentsRoot = Join-Path $userHome '.agents'
        New-Item -ItemType Directory -Force -Path $runtimeRoot,$agentsRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-install.lock'),'')
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'), @'
[CmdletBinding()]
param([switch]$ValidateOnly)
if (-not $ValidateOnly) { throw 'Validation switch required.' }
'@)
        Copy-Item -LiteralPath $script:ModulePath -Destination (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Force
        Copy-Item -LiteralPath $script:ContractPath -Destination (Join-Path $runtimeRoot 'skills-catalog-contract.psm1') -Force
        Copy-TestRecoveryRuntimeDependencies -Destination $runtimeRoot
        $manifestPath = Join-Path $agentsRoot 'catalog-skills.manifest.json'
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v3.example.json') -Destination $manifestPath -Force
        $manifestBytesBefore = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestPath))

        $output = @(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry `
            -CodexHome $codexHome -UserHome $userHome -Recover -OutputFormat Json)
        $exitCode = $LASTEXITCODE

        $exitCode | Should Be 0
        $output.Count | Should Be 1
        ($output[0] | ConvertFrom-Json).outcome | Should Be 'nothing-to-recover'
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestPath)) | Should Be $manifestBytesBefore
    }

    # Scenario: The stable entry point receives a malformed recovery journal while recovery is explicitly requested.
    # Purpose: Verify the child process returns machine-readable recovery-required evidence and preserves the journal for operator remediation.
    It 'InterT60_returns_structured_recovery_evidence_and_preserves_an_invalid_recovery_journal' {
        $entry = Join-Path $script:RepositoryRoot 'scripts\update-agent-environment.ps1'
        $codexHome = Join-Path $TestDrive ('recovery-codex-' + [Guid]::NewGuid().ToString('N'))
        $userHome = Join-Path $TestDrive ('recovery-user-' + [Guid]::NewGuid().ToString('N'))
        $runtimeRoot = Join-Path $codexHome 'hooks\ai-instructions-runtime'
        New-Item -ItemType Directory -Force -Path $runtimeRoot,(Join-Path $userHome '.agents\backups\invalid') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-install.lock'),'')
        [System.IO.File]::WriteAllText((Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'), @'
[CmdletBinding()]
param([switch]$ValidateOnly)
if (-not $ValidateOnly) { throw 'Validation switch required.' }
'@)
        Copy-Item -LiteralPath $script:ModulePath -Destination (Join-Path $runtimeRoot 'agent-environment-reconciler.psm1') -Force
        Copy-Item -LiteralPath $script:ContractPath -Destination (Join-Path $runtimeRoot 'skills-catalog-contract.psm1') -Force
        Copy-TestRecoveryRuntimeDependencies -Destination $runtimeRoot

        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; transactionId=('a' * 32)
            userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=(Join-Path $userHome '.agents\backups\invalid'); phase='mutating'
            desiredManifestSha256=('a' * 64); desiredInventorySha256=('b' * 64)
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$true
                backupPath=(Join-Path $userHome '.agents\backups\invalid\alpha')
                originalSha256='invalid'; backupSha256='invalid'; appliedSha256=('c' * 64)
            })
        }
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        $output = @(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry `
            -CodexHome $codexHome -UserHome $userHome -Recover -OutputFormat Json)
        $exitCode = $LASTEXITCODE

        $exitCode | Should Be 1
        $output.Count | Should Be 1
        $result = $output[0] | ConvertFrom-Json
        $result.outcome | Should Be 'failed'
        $result.rollbackState | Should Be 'recovery-required'
        $result.failureDetails[0].code | Should Be 'recovery-required'
        $result.failureDetails[0].path | Should Be '.agents/update-agent-environment.recovery.json'
        $result.ownership[0].owner | Should Be 'transaction-journal'
        Test-Path -LiteralPath $journalPath -PathType Leaf | Should Be $true
    }

    # Scenario: Two installed entry points with different CODEX_HOME values update one USER home concurrently.
    # Purpose: Prove the USER lock, not CODEX_HOME, elects one writer and leaves a valid shared manifest/inventory.
    It 'InterT77_serializes_two_CODEX_HOME_entry_Apply_processes' {
        $entry=Join-Path $script:RepositoryRoot 'scripts/update-agent-environment.ps1';$userHome=Join-Path $TestDrive 'dual-codex-user';$barrier=Join-Path $TestDrive 'dual-codex-barrier';New-Item -ItemType Directory -Path $userHome,$barrier|Out-Null
        $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'dual-codex-stage');$desiredPath=Join-Path $TestDrive 'dual-codex-desired.clixml';$desired|Export-Clixml $desiredPath
        $codexHomes=@((Join-Path $TestDrive 'codex-one'),(Join-Path $TestDrive 'codex-two'))
        foreach($codexHome in $codexHomes){
            $runtime=Join-Path $codexHome 'hooks/ai-instructions-runtime';New-Item -ItemType Directory -Force -Path $runtime,(Join-Path $runtime 'catalog')|Out-Null
            Copy-Item -Path (Join-Path $script:RuntimeRoot '*') -Destination $runtime -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') -Destination (Join-Path $runtime 'catalog/skills-catalog.json')
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog-lock.json') -Destination (Join-Path $runtime 'catalog/skills-catalog-lock.json')
            Move-Item -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Destination (Join-Path $runtime 'agent-environment-reconciler-core.ps1')
            @'
. (Join-Path $PSScriptRoot 'agent-environment-reconciler-core.ps1')
$script:ActualInvoke=${function:Invoke-UserSkillsReconciliation}
function Get-UserSkillsDesiredState { param([string]$RuntimeRoot,[object]$Configuration,[string]$CatalogRepository,[string]$CatalogCommit,[string]$WorkingRoot) $state=Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'test-desired.clixml');$state.RuntimeRoot=$PSScriptRoot;return $state }
function Invoke-UserSkillsReconciliation {
    [CmdletBinding()]param([object]$DesiredState,[string]$UserHome,[string]$Mode,[switch]$ForceReinstallManagedSkills,[switch]$MigrateLegacyCatalogSkills,[object]$InstallReadLease)
    $barrierAction={
        $barrier=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'test-barrier-path.txt')
        $ready=Join-Path $barrier ("$PID.ready");[IO.File]::WriteAllText($ready,'ready');$deadline=[DateTime]::UtcNow.AddSeconds(20)
        while(-not(Test-Path (Join-Path $barrier 'go'))){if([DateTime]::UtcNow-ge$deadline){throw 'barrier timeout'};Start-Sleep -Milliseconds 25}
    }
    & $script:ActualInvoke -DesiredState $DesiredState -UserHome $UserHome -Mode $Mode -ForceReinstallManagedSkills:$ForceReinstallManagedSkills -MigrateLegacyCatalogSkills:$MigrateLegacyCatalogSkills -InstallReadLease $InstallReadLease -BeforeLockAcquisitionAction $barrierAction
}
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
'@|Set-Content -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Encoding UTF8
            Copy-Item -LiteralPath $desiredPath -Destination (Join-Path $runtime 'test-desired.clixml')
            [IO.File]::WriteAllText((Join-Path $runtime 'test-barrier-path.txt'),$barrier,[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-install.lock'),'')
            [IO.File]::WriteAllText((Join-Path $codexHome 'hooks/bootstrap-ai-instructions.ps1'),"param([switch]`$ValidateOnly)`nif(-not`$ValidateOnly){throw 'ValidateOnly required'}")
            @{schemaVersion=4;catalog=@{ref='89abcdef0123456789abcdef0123456789abcdef'}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $codexHome 'ai-instructions-sync.json') -Encoding UTF8
            @{schemaVersion=2;repository='https://github.com/example/ai-instructions.git';commit='89abcdef0123456789abcdef0123456789abcdef'}|ConvertTo-Json|Set-Content (Join-Path $runtime 'runtime-bundle.json') -Encoding UTF8
        }
        $processes=@();try{
            for($i=0;$i-lt2;$i++){$out=Join-Path $TestDrive "dual-codex-$i.out";$err=Join-Path $TestDrive "dual-codex-$i.err";$processes+=,[pscustomobject]@{Process=(Start-Process -FilePath $script:TestPowerShellExecutable -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$entry,'-CodexHome',$codexHomes[$i],'-UserHome',$userHome,'-Apply','-OutputFormat','Json') -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru);Out=$out;Err=$err}}
            $deadline=[DateTime]::UtcNow.AddSeconds(30);while(@(Get-ChildItem -LiteralPath $barrier -Filter '*.ready' -ErrorAction SilentlyContinue).Count-lt2){if(@($processes|Where-Object{$_.Process.HasExited}).Count-gt0){$diagnostics=@($processes|ForEach-Object{"stdout=$((Get-Content -Raw -LiteralPath $_.Out -ErrorAction SilentlyContinue)) stderr=$((Get-Content -Raw -LiteralPath $_.Err -ErrorAction SilentlyContinue))"})-join' | ';throw "entry exited before lock barrier: $diagnostics"};if([DateTime]::UtcNow-ge$deadline){throw 'entry lock barrier timeout'};Start-Sleep -Milliseconds 25}
            [IO.File]::WriteAllText((Join-Path $barrier 'go'),'go');foreach($item in $processes){$item.Process.WaitForExit(30000)|Should Be $true;$item.Process.HasExited|Should Be $true}
            $processResults=@($processes|ForEach-Object{[pscustomobject]@{Result=((Get-Content -Raw -LiteralPath $_.Out)|ConvertFrom-Json);ExitCode=$_.Process.ExitCode}})
            (@($processResults.Result.outcome|Sort-Object)-join ',')|Should Be 'applied,concurrent'
            foreach($processResult in $processResults){if([string]$processResult.Result.outcome-ceq'applied'){$processResult.ExitCode|Should Be 0}elseif([string]$processResult.Result.outcome-ceq'concurrent'){$processResult.ExitCode|Should Be 3}else{throw "Unexpected dual-entry outcome '$($processResult.Result.outcome)'."}}
            $manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $userHome '.agents/catalog-skills.manifest.json')|ConvertFrom-Json;Assert-UserSkillsManagedManifest -Manifest $manifest|Out-Null
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $userHome '.agents/skills/alpha/SKILL.md')).Hash.ToLowerInvariant()|Should Be $desired.Files[0].sha256
        }finally{foreach($item in $processes){if(-not$item.Process.HasExited){$item.Process.Kill()};$item.Process.Dispose()}}
    }

    # Scenario: The stable entry sees every new-transaction residue class in legacy-only/new-only/both layouts and read-only modes.
    # Purpose: Keep entry exit code, refusal Code, zero mutation, retained evidence, baseline, and production projection gate behavior executable.
    It 'InterT78_covers_entry_transaction_matrix_baseline_and_gate_refusals' {
        $entry=Join-Path $script:RepositoryRoot 'scripts/update-agent-environment.ps1';$codexHome=Join-Path $TestDrive 'entry-matrix-codex';$runtime=Join-Path $codexHome 'hooks/ai-instructions-runtime';New-Item -ItemType Directory -Force -Path $runtime,(Join-Path $runtime 'catalog')|Out-Null
        Copy-Item -Path (Join-Path $script:RuntimeRoot '*') -Destination $runtime -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog.json') -Destination (Join-Path $runtime 'catalog/skills-catalog.json')
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/skills-catalog-lock.json') -Destination (Join-Path $runtime 'catalog/skills-catalog-lock.json')
        Move-Item -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Destination (Join-Path $runtime 'agent-environment-reconciler-core.ps1')
        @'
. (Join-Path $PSScriptRoot 'agent-environment-reconciler-core.ps1')
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'reconciler-imported.marker'),'imported')
function Get-UserSkillsDesiredState { param([string]$RuntimeRoot,[object]$Configuration,[string]$CatalogRepository,[string]$CatalogCommit,[string]$WorkingRoot) $state=Import-Clixml -LiteralPath (Join-Path $PSScriptRoot 'test-desired.clixml');$state.RuntimeRoot=$PSScriptRoot;return $state }
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'force-capability-unavailable')){
    function Assert-AgentEnvironmentDirectoryPublicationCapability {throw (New-AgentEnvironmentRefusalException -Code 'capability-unavailable' -Message 'Injected directory-publication refusal.')}
}
Export-ModuleMember -Function Assert-UserProjectionRuntimeGate,Get-UserSkillsDesiredState,Invoke-UserSkillsReconciliation,Invoke-UserSkillsRecovery,New-AgentEnvironmentInstallReadLeaseEvidence
'@|Set-Content -LiteralPath (Join-Path $runtime 'agent-environment-reconciler.psm1') -Encoding UTF8
        [IO.File]::WriteAllText((Join-Path $codexHome 'ai-instructions-install.lock'),'');[IO.File]::WriteAllText((Join-Path $codexHome 'hooks/bootstrap-ai-instructions.ps1'),"param([switch]`$ValidateOnly)`nif(-not`$ValidateOnly){throw 'ValidateOnly required'}")
        $commit='89abcdef0123456789abcdef0123456789abcdef';@{schemaVersion=4;catalog=@{ref=$commit}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $codexHome 'ai-instructions-sync.json') -Encoding UTF8;@{schemaVersion=2;repository='https://github.com/example/ai-instructions.git';commit=$commit}|ConvertTo-Json|Set-Content (Join-Path $runtime 'runtime-bundle.json') -Encoding UTF8
        $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'entry-matrix-stage');$desired|Export-Clixml (Join-Path $runtime 'test-desired.clixml')
        [IO.File]::WriteAllText((Join-Path $runtime 'reconciler-imported.marker'),'imported')
        function Add-MatrixResidue([string]$MatrixUserHome,[string]$Classification,[string]$Layout){
            $agents=Join-Path $MatrixUserHome '.agents';New-Item -ItemType Directory -Force -Path $agents|Out-Null
            [IO.File]::WriteAllText((Join-Path $agents 'update-agent-environment.lock'),'')
            if($Layout-in@('legacy-only','both')){[IO.File]::WriteAllText((Join-Path $agents 'update-agent-environment.recovery.json'),'{}')}
            if($Layout-in@('new-only','both')){
                $name=if($Classification-ceq'invalid-name'){'invalid-name'}else{'0123456789abcdef0123456789abcdef'};$txn=Join-Path $MatrixUserHome ".ai-instructions-txn/$name";New-Item -ItemType Directory -Force -Path $txn|Out-Null
                if($Classification-ceq'malformed'){[IO.File]::WriteAllText((Join-Path $txn 'journal.json'),'{')}
                elseif($Classification-ceq'valid'){$journal=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'catalog/examples/ai-instructions-user-reconciler-journal-v1.example.json')|ConvertFrom-Json -DateKind String;$journal.transactionId=$name;[IO.File]::WriteAllText((Join-Path $txn 'journal.json'),($journal|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}
            }
        }
        try{
            foreach($mode in @('verify','whatif')){foreach($classification in @('valid','malformed','orphan','invalid-name')){foreach($layout in @('legacy-only','new-only','both')){
                $matrixUserHome=Join-Path $TestDrive "matrix-$mode-$classification-$layout";New-Item -ItemType Directory -Path $matrixUserHome|Out-Null;Add-MatrixResidue $matrixUserHome $classification $layout
                $beforeUser=Get-TestTreeSnapshot $matrixUserHome;$beforeCodex=Get-TestTreeSnapshot $codexHome
                $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$entry,'-CodexHome',$codexHome,'-UserHome',$matrixUserHome,'-OutputFormat','Json')+$(if($mode-ceq'verify'){@('-VerifyOnly')}else{@('-Apply','-WhatIf')})
                $output=@(& $script:TestPowerShellExecutable @args);$exit=$LASTEXITCODE;$result=$output[-1]|ConvertFrom-Json
                $exit|Should Be 1;$result.Code|Should Be 'interrupted-install';(Get-TestTreeSnapshot $matrixUserHome)|Should Be $beforeUser;(Get-TestTreeSnapshot $codexHome)|Should Be $beforeCodex
                if($layout-in@('new-only','both')){@(Get-ChildItem -Force -LiteralPath (Join-Path $matrixUserHome '.ai-instructions-txn')).Count|Should BeGreaterThan 0}
            }}}
            foreach($classification in @('valid','malformed','orphan','invalid-name')){
                $matrixUserHome=Join-Path $TestDrive "matrix-recover-new-$classification";New-Item -ItemType Directory -Path $matrixUserHome|Out-Null;Add-MatrixResidue $matrixUserHome $classification 'new-only'
                $recoverBefore=Get-TestTreeSnapshot $matrixUserHome;$recoverCodexBefore=Get-TestTreeSnapshot $codexHome
                $output=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $matrixUserHome -Recover -OutputFormat Json);$exit=$LASTEXITCODE;$result=$output[-1]|ConvertFrom-Json
                if($classification-in@('valid','orphan')){$exit|Should Be 0;$result.outcome|Should Be 'recovered';@(Get-ChildItem -Force -LiteralPath (Join-Path $matrixUserHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0}else{$exit|Should Be 1;$result.Code|Should Be 'interrupted-install';(Get-TestTreeSnapshot $matrixUserHome)|Should Be $recoverBefore;(Get-TestTreeSnapshot $codexHome)|Should Be $recoverCodexBefore}
                $bothHome=Join-Path $TestDrive "matrix-recover-both-$classification";New-Item -ItemType Directory -Path $bothHome|Out-Null;Add-MatrixResidue $bothHome $classification 'both'
                $bothBefore=Get-TestTreeSnapshot $bothHome;$bothCodexBefore=Get-TestTreeSnapshot $codexHome;$bothOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $bothHome -Recover -OutputFormat Json);$LASTEXITCODE|Should Be 1;($bothOutput[-1]|ConvertFrom-Json).Code|Should Be 'interrupted-install';(Get-TestTreeSnapshot $bothHome)|Should Be $bothBefore;(Get-TestTreeSnapshot $codexHome)|Should Be $bothCodexBefore
            }
            foreach($mode in @('verify','whatif')){$matrixUserHome=Join-Path $TestDrive "matrix-baseline-$mode";New-Item -ItemType Directory -Path $matrixUserHome|Out-Null;$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$entry,'-CodexHome',$codexHome,'-UserHome',$matrixUserHome,'-OutputFormat','Json')+$(if($mode-ceq'verify'){@('-VerifyOnly')}else{@('-Apply','-WhatIf')});$output=@(& $script:TestPowerShellExecutable @args);$result=$output[-1]|ConvertFrom-Json;if($mode-ceq'verify'){$LASTEXITCODE|Should Be 2;$result.outcome|Should Be 'drift'}else{$LASTEXITCODE|Should Be 0;$result.outcome|Should Be 'planned'};Test-Path (Join-Path $matrixUserHome '.agents/skills/alpha/SKILL.md')|Should Be $false}
            $downgradeHome=Join-Path $TestDrive 'matrix-downgrade';New-Item -ItemType Directory -Force -Path (Join-Path $downgradeHome '.agents')|Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/examples/user-skills-managed-manifest-v3.example.json') -Destination (Join-Path $downgradeHome '.agents/catalog-skills.manifest.json')
            $downgradeBefore=Get-TestTreeSnapshot $downgradeHome;$downgradeCodexBefore=Get-TestTreeSnapshot $codexHome
            $downgradeOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $downgradeHome -VerifyOnly -OutputFormat Json);$LASTEXITCODE|Should Be 1
            ($downgradeOutput[-1]|ConvertFrom-Json).Code|Should Be 'downgrade-refused';(Get-TestTreeSnapshot $downgradeHome)|Should Be $downgradeBefore;(Get-TestTreeSnapshot $codexHome)|Should Be $downgradeCodexBefore
            $importMarker=Join-Path $runtime 'reconciler-imported.marker'
            foreach($pair in @(
                [pscustomobject]@{Name='v5-v2';Config=5;Bundle=2;Code='mixed-generation'},
                [pscustomobject]@{Name='v4-v3';Config=4;Bundle=3;Code='mixed-generation'},
                [pscustomobject]@{Name='v5-v3';Config=5;Bundle=3;Code='projection-runtime-unavailable'},
                [pscustomobject]@{Name='unknown-config';Config=99;Bundle=2;Code='unsupported-version'},
                [pscustomobject]@{Name='unknown-bundle';Config=4;Bundle=99;Code='unsupported-version'}
            )){
                Remove-Item -LiteralPath $importMarker -Force -ErrorAction SilentlyContinue
                @{schemaVersion=$pair.Config;catalog=@{ref=$commit};projections=@{user=@('user-agents')}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $codexHome 'ai-instructions-sync.json') -Encoding UTF8
                @{schemaVersion=$pair.Bundle;repository='https://github.com/example/ai-instructions.git';commit=$commit}|ConvertTo-Json|Set-Content (Join-Path $runtime 'runtime-bundle.json') -Encoding UTF8
                $gateHome=Join-Path $TestDrive "matrix-gate-$($pair.Name)";New-Item -ItemType Directory -Path $gateHome|Out-Null;$beforeUser=Get-TestTreeSnapshot $gateHome;$beforeCodex=Get-TestTreeSnapshot $codexHome
                $gateOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $gateHome -VerifyOnly -OutputFormat Json);$LASTEXITCODE|Should Be 1;$gate=$gateOutput[-1]|ConvertFrom-Json;$gate.Code|Should Be $pair.Code
                (Get-TestTreeSnapshot $gateHome)|Should Be $beforeUser;(Get-TestTreeSnapshot $codexHome)|Should Be $beforeCodex;Test-Path -LiteralPath $importMarker|Should Be $false
            }
            foreach($missingSide in @('config','bundle')){
                @{schemaVersion=4;catalog=@{ref=$commit}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $codexHome 'ai-instructions-sync.json') -Encoding UTF8
                @{schemaVersion=2;repository='https://github.com/example/ai-instructions.git';commit=$commit}|ConvertTo-Json|Set-Content (Join-Path $runtime 'runtime-bundle.json') -Encoding UTF8
                if($missingSide-ceq'config'){Remove-Item -LiteralPath (Join-Path $codexHome 'ai-instructions-sync.json') -Force}else{Remove-Item -LiteralPath (Join-Path $runtime 'runtime-bundle.json') -Force}
                $missingHome=Join-Path $TestDrive "matrix-gate-missing-$missingSide";New-Item -ItemType Directory -Path $missingHome|Out-Null;Remove-Item -LiteralPath $importMarker -Force -ErrorAction SilentlyContinue
                $missingOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $missingHome -VerifyOnly -OutputFormat Json);$LASTEXITCODE|Should Be 1;($missingOutput[-1]|ConvertFrom-Json).Code|Should Be 'unsupported-version';Test-Path -LiteralPath $importMarker|Should Be $false
            }

            @{schemaVersion=4;catalog=@{ref=$commit}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $codexHome 'ai-instructions-sync.json') -Encoding UTF8
            @{schemaVersion=2;repository='https://github.com/example/ai-instructions.git';commit=$commit}|ConvertTo-Json|Set-Content (Join-Path $runtime 'runtime-bundle.json') -Encoding UTF8
            [IO.File]::WriteAllText((Join-Path $runtime 'force-capability-unavailable'),'1');[IO.File]::WriteAllText($importMarker,'imported')
            $capabilityHome=Join-Path $TestDrive 'matrix-capability';New-Item -ItemType Directory -Force -Path (Join-Path $capabilityHome '.agents')|Out-Null;[IO.File]::WriteAllText((Join-Path $capabilityHome '.agents/update-agent-environment.lock'),'')
            $capabilityBefore=Get-TestTreeSnapshot $capabilityHome;$capabilityCodexBefore=Get-TestTreeSnapshot $codexHome;$capabilityOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $capabilityHome -Apply -OutputFormat Json);$LASTEXITCODE|Should Be 1;($capabilityOutput[-1]|ConvertFrom-Json).Code|Should Be 'capability-unavailable';(Get-TestTreeSnapshot $capabilityHome)|Should Be $capabilityBefore;(Get-TestTreeSnapshot $codexHome)|Should Be $capabilityCodexBefore;Test-Path -LiteralPath (Join-Path $capabilityHome '.ai-instructions-txn')|Should Be $false
            Remove-Item -LiteralPath (Join-Path $runtime 'force-capability-unavailable') -Force

            $legacyRecoverHome=Join-Path $TestDrive 'matrix-legacy-recover';$legacyRecovery=Join-Path $legacyRecoverHome '.agents/update-agent-environment.recovery.json';New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacyRecovery)|Out-Null;[IO.File]::WriteAllText($legacyRecovery,'{}');[IO.File]::WriteAllText((Join-Path $legacyRecoverHome '.agents/update-agent-environment.lock'),'');$legacyBefore=Get-TestTreeSnapshot $legacyRecoverHome
            $legacyCodexBefore=Get-TestTreeSnapshot $codexHome;$legacyOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $codexHome -UserHome $legacyRecoverHome -Recover -OutputFormat Json);$LASTEXITCODE|Should Be 1;($legacyOutput[-1]|ConvertFrom-Json).outcome|Should Be 'failed';Test-Path -LiteralPath $legacyRecovery|Should Be $true;(Get-TestTreeSnapshot $legacyRecoverHome)|Should Be $legacyBefore;(Get-TestTreeSnapshot $codexHome)|Should Be $legacyCodexBefore
            # runtime-baseline-unavailable, closure-invalid, and platform-mismatch remain P7e gate wiring cases; this P8 entry cannot honestly produce them yet.
        }finally{Remove-Item Function:Add-MatrixResidue -ErrorAction SilentlyContinue}
    }

    # Scenario: A platform publication completes its rename but reports failure before the coordinator records operation.state=applied.
    # Purpose: Derive rollback from target/backup/stage identity evidence and restore the original instead of deleting its backup as stale transaction data.
    It 'InterT79_rolls_back_a_completed_platform_rename_from_observed_evidence' {
        $testUserHome=Join-Path $TestDrive 'post-rename-rollback';$initial=New-TestDesiredState -Root (Join-Path $TestDrive 'post-rename-initial') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $testUserHome -Mode Apply).outcome|Should Be 'applied'
        $target=Join-Path $testUserHome '.agents/skills/alpha/SKILL.md';$before=[IO.File]::ReadAllBytes($target)
        $next=New-TestDesiredState -Root (Join-Path $TestDrive 'post-rename-next') -SkillIds @('alpha')
        [IO.File]::WriteAllText([string]$next.Files[0].stagedPath,"---`nname: alpha`ndescription: changed after rename`n---`n",[Text.UTF8Encoding]::new($false))
        $next.Files[0].sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$next.Files[0].stagedPath)).Hash.ToLowerInvariant();$next.Manifest.files[0].sha256=$next.Files[0].sha256

        $failed=Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $testUserHome -Mode Apply -FailpointName after-platform-rename

        $failed.outcome|Should Be 'failed';$failed.rollbackState|Should Be 'completed'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($target))|Should Be ([Convert]::ToBase64String($before))
        @(Get-ChildItem -Force -LiteralPath (Join-Path $testUserHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: The final managed file for one Skill is retired from every USER projection while unrelated empty personal directories coexist.
    # Purpose: Prune only empty directories proven to have held managed files, after commit, across every projection root.
    It 'InterT80_prunes_retired_empty_Skill_directories_in_every_projection' {
        $testUserHome=Join-Path $TestDrive 'projection-prune';$initial=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-prune-initial')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $testUserHome -Mode Apply).outcome|Should Be 'applied'
        foreach($root in @('.agents/skills','.claude/skills','.copilot/skills')){New-Item -ItemType Directory -Force -Path (Join-Path $testUserHome "$root/personal-empty")|Out-Null}
        $retired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-prune-retired')
        $retired.Files=@();$retired.Manifest.files=@();$retired.SkillIds=@()

        (Invoke-UserSkillsReconciliation -DesiredState $retired -UserHome $testUserHome -Mode Apply).outcome|Should Be 'applied'

        foreach($root in @('.agents/skills','.claude/skills','.copilot/skills')){
            Test-Path -LiteralPath (Join-Path $testUserHome "$root/work-with-jira")|Should Be $false
            Test-Path -LiteralPath (Join-Path $testUserHome "$root/personal-empty") -PathType Container|Should Be $true
        }
    }

    # Scenario: Unmanaged content appears after the prune emptiness observation and before directory rename.
    # Purpose: Revalidate the complete empty-directory inventory and preserve the new USER content in place.
    It 'InterT83_preserves_unmanaged_content_raced_into_a_prune_candidate' {
        $testUserHome=Join-Path $TestDrive 'projection-prune-race';$initial=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-prune-race-initial')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $testUserHome -Mode Apply).outcome|Should Be 'applied'
        $retired=New-TestProjectionDesiredState -Root (Join-Path $TestDrive 'projection-prune-race-retired')
        $retired.Files=@();$retired.Manifest.files=@();$retired.SkillIds=@()
        $external=Join-Path $testUserHome '.agents/skills/work-with-jira/external.txt'

        $result=Invoke-UserSkillsReconciliation -DesiredState $retired -UserHome $testUserHome -Mode Apply -BeforeDirectoryPruneAction {
            param($relative)
            if($relative-ceq'.agents/skills/work-with-jira' -and -not(Test-Path -LiteralPath $external)){[IO.File]::WriteAllText($external,'unmanaged')}
        }

        $result.outcome|Should Be 'applied'
        [IO.File]::ReadAllText($external)|Should Be 'unmanaged'
        Test-Path -LiteralPath (Split-Path -Parent $external) -PathType Container|Should Be $true
        @(Get-ChildItem -Force -LiteralPath (Join-Path $testUserHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
    }

    # Scenario: Stable-entry failure text contains multiple refusal markers, including an unknown final marker.
    # Purpose: Emit only the last marker when it is in the closed runtime vocabulary and never surface an unknown code as the result Code.
    It 'InterT81_uses_the_last_closed_refusal_marker_in_entry_failures' {
        $entry=Join-Path $script:RepositoryRoot 'scripts/update-agent-environment.ps1';$userHome=Join-Path $TestDrive 'refusal-entry-user';New-Item -ItemType Directory -Path $userHome|Out-Null
        $validHome=Join-Path $TestDrive 'old [ai-instructions-refusal-code=closure-invalid] final [ai-instructions-refusal-code=interrupted-install]'
        $validRuntime=Join-Path $validHome 'hooks/ai-instructions-runtime';[void][IO.Directory]::CreateDirectory($validRuntime);[IO.File]::WriteAllText((Join-Path $validHome 'ai-instructions-install.lock'),'');@{schemaVersion=4}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $validHome 'ai-instructions-sync.json');@{schemaVersion=2}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $validRuntime 'runtime-bundle.json')
        $validOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $validHome -UserHome $userHome -VerifyOnly -OutputFormat Json)
        $LASTEXITCODE|Should Be 1;($validOutput[-1]|ConvertFrom-Json).Code|Should Be 'interrupted-install'
        $unknownHome=Join-Path $TestDrive 'old [ai-instructions-refusal-code=closure-invalid] final [ai-instructions-refusal-code=unknown]'
        $unknownRuntime=Join-Path $unknownHome 'hooks/ai-instructions-runtime';[void][IO.Directory]::CreateDirectory($unknownRuntime);[IO.File]::WriteAllText((Join-Path $unknownHome 'ai-instructions-install.lock'),'');@{schemaVersion=4}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $unknownHome 'ai-instructions-sync.json');@{schemaVersion=2}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $unknownRuntime 'runtime-bundle.json')
        $unknownOutput=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $unknownHome -UserHome $userHome -VerifyOnly -OutputFormat Json)
        $LASTEXITCODE|Should Be 1;($unknownOutput[-1]|ConvertFrom-Json).Code|Should BeNullOrEmpty
        $unknownText=@(& $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -CodexHome $unknownHome -UserHome $userHome -VerifyOnly -OutputFormat Text)
        @($unknownText|Where-Object{$_-match'^Code:'}).Count|Should Be 0
    }
}

Describe 'USER directory-publication capability gating' {
    # Scenario: directory-publication becomes unavailable after a current USER install exists.
    # Purpose: Require the capability only for Apply plans that really contain create-directory, never for read-only/current/drift classification.
    It 'InterT98_does_not_gate_read_only_or_current_paths_on_directory_publication' {
        $currentHome=Join-Path $TestDrive 'capability-current-home';$currentDesired=New-TestDesiredState -Root (Join-Path $TestDrive 'capability-current-stage')
        (Invoke-UserSkillsReconciliation -DesiredState $currentDesired -UserHome $currentHome -Mode Apply).outcome|Should Be 'applied'
        Mock Get-PlatformCapabilities {throw 'directory-publication unavailable'} -ModuleName agent-environment-reconciler
        (Invoke-UserSkillsReconciliation -DesiredState $currentDesired -UserHome $currentHome -Mode VerifyOnly).outcome|Should Be 'current'
        $driftHome=Join-Path $TestDrive 'capability-drift-home'
        (Invoke-UserSkillsReconciliation -DesiredState $currentDesired -UserHome $driftHome -Mode VerifyOnly).outcome|Should Be 'drift'
        (Invoke-UserSkillsReconciliation -DesiredState $currentDesired -UserHome $driftHome -Mode WhatIf).outcome|Should Be 'planned'
        Assert-MockCalled Get-PlatformCapabilities 0 -ModuleName agent-environment-reconciler
    }
}

Describe 'USER commit recovery capability gating' {
    Context 'committing an already-applied directory transaction' {
        # Scenario: A create-directory operation is fully applied, but the process dies before the applied journal is committed.
        # Purpose: A commit recovery only writes journal state and cleans transaction artifacts, so unavailable directory publication must not block it.
        It 'InterT100_does_not_gate_commit_recovery_on_directory_publication' {
            $caseHome=Join-Path $TestDrive 'capability-commit-recovery-home'
            $desired=New-TestDesiredState -Root (Join-Path $TestDrive 'capability-commit-recovery-stage')
            $failed=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode Apply -FailpointName before-committed-cleanup
            $failed.rollbackState|Should Be 'recovery-required'
            $transaction=@(Get-ChildItem -Force -Directory -LiteralPath (Join-Path $caseHome '.ai-instructions-txn'))[0]
            $journalPath=Join-Path $transaction.FullName 'journal.json'
            $previousJournalPath=Join-Path $transaction.FullName 'journal.prev'
            (Get-Content -Raw -Encoding UTF8 -LiteralPath $previousJournalPath|ConvertFrom-Json -DateKind String).phase|Should Be 'applied'
            [IO.File]::Delete($journalPath)
            [IO.File]::Move($previousJournalPath,$journalPath)
            Mock Get-PlatformCapabilities {throw 'directory-publication unavailable'} -ModuleName agent-environment-reconciler
            $readLease=New-TestInstallReadLeaseEvidence
            try{$recovered=Invoke-UserSkillsRecovery -UserHome $caseHome -InstallReadLease $readLease.Evidence}
            finally{$readLease.Evidence.Dispose();if($readLease.Created){Remove-Item -LiteralPath $readLease.Path -Force -ErrorAction SilentlyContinue}}

            $recovered.outcome|Should Be 'recovered'
            Assert-MockCalled Get-PlatformCapabilities 0 -ModuleName agent-environment-reconciler
            @(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count|Should Be 0
        }
    }
}
