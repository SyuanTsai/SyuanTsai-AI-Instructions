$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RuntimeRoot = Join-Path $script:RepositoryRoot 'scripts'
$script:ModulePath = Join-Path $script:RuntimeRoot 'agent-environment-reconciler.psm1'
$script:ContractPath = Join-Path $script:RuntimeRoot 'skills-catalog-contract.psm1'
$script:TestPowerShellExecutable = (Get-Process -Id $PID).Path

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

Describe 'user-scoped Agent Skills reconciliation' {
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
        (Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        Test-Path (Join-Path $userHome '.agents/skills/alpha/references/details.md') | Should Be $false
        foreach($entry in $next.Files){ (Get-FileHash (Join-Path $userHome $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $before=(Get-FileHash (Join-Path $userHome '.agents/catalog-skills.manifest.json')).Hash
        (Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply).outcome | Should Be 'current'
        (Get-FileHash (Join-Path $userHome '.agents/catalog-skills.manifest.json')).Hash | Should Be $before
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
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
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
        @($collision.failureDetails|Where-Object code -eq 'unmanaged-collision').Count | Should BeGreaterThan 0
        [IO.File]::ReadAllText($personal) | Should Be 'personal'
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

        $readLeasePath=Join-Path $TestDrive 'ai-instructions-install.lock';[IO.File]::WriteAllText($readLeasePath,'')
        $readLease=[IO.File]::Open($readLeasePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{(Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -InstallReadLease $readLease).outcome | Should Be 'applied'}finally{$readLease.Dispose()}
        Test-Path -LiteralPath $orphan | Should Be $false
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
        $failpoints=@('after-journal-stage-flush','after-journal-publish','after-operation-journal','after-original-rename','after-applied-rename','after-parent-flush','during-rollback','before-committed-cleanup')
        foreach($failpoint in $failpoints){
            $caseHome=Join-Path $TestDrive ("failfast-home-$failpoint")
            $caseStage=Join-Path $TestDrive ("failfast-stage-$failpoint")
            New-Item -ItemType Directory -Force -Path $caseHome,$caseStage|Out-Null
            $desired=New-TestDesiredState -Root $caseStage
            $desiredPath=Join-Path $TestDrive ("desired-$failpoint.clixml");$desired|Export-Clixml -LiteralPath $desiredPath
            $failureAfter=if($failpoint-ceq'during-rollback'){1}else{0}
            & $script:TestPowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $childScript $script:ModulePath $desiredPath $caseHome $failpoint $failureAfter 2>$null
            $LASTEXITCODE | Should Not Be 0
            @(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count | Should BeGreaterThan 0
            $readLeasePath=Join-Path $TestDrive ("$failpoint-ai-instructions-install.lock");[IO.File]::WriteAllText($readLeasePath,'')
            $readLease=[IO.File]::Open($readLeasePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try{$result=Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $caseHome -Mode Apply -InstallReadLease $readLease}finally{$readLease.Dispose()}
            @('applied','current') | Should Contain $result.outcome
            @(Get-ChildItem -Force -LiteralPath (Join-Path $caseHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count | Should Be 0
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $caseHome '.agents/skills/alpha/SKILL.md')).Hash.ToLowerInvariant() | Should Be $desired.Files[0].sha256
        }
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
        $migrated.backupPath | Should BeNullOrEmpty
        @(Get-ChildItem -Force -LiteralPath (Join-Path $userHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count | Should Be 0
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
        $result.backupPath | Should BeNullOrEmpty
        @(Get-ChildItem -Force -LiteralPath (Join-Path $userHome '.ai-instructions-txn') -ErrorAction SilentlyContinue).Count | Should Be 0
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
        $transactionCount = @(Get-ChildItem -LiteralPath (Join-Path $userHome '.ai-instructions-txn') -Directory -ErrorAction SilentlyContinue).Count
        { Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -BeforeBackupValidationAction {
            [System.IO.File]::WriteAllText($target,'concurrent target edit')
        } } | Should Throw
        [System.IO.File]::ReadAllText($target) | Should Be 'concurrent target edit'
        Test-Path -LiteralPath $journalPath | Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $userHome '.ai-instructions-txn') -Directory -ErrorAction SilentlyContinue).Count | Should Be $transactionCount

        # The manifest participates in the same observation contract.
        [System.IO.File]::WriteAllBytes($target,[System.IO.File]::ReadAllBytes([string]$desired.Files[0].stagedPath))
        $manifestBeforeRace = [System.IO.File]::ReadAllText($manifestPath)
        { Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -BeforeBackupValidationAction {
            [System.IO.File]::AppendAllText($manifestPath,' ')
        } } | Should Throw
        [System.IO.File]::ReadAllText($manifestPath) | Should Be ($manifestBeforeRace + ' ')
        [System.IO.File]::ReadAllText($target) | Should Match 'name: alpha'
        Test-Path -LiteralPath $journalPath | Should Be $false
        @(Get-ChildItem -LiteralPath (Join-Path $userHome '.ai-instructions-txn') -Directory -ErrorAction SilentlyContinue).Count | Should Be $transactionCount
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
        @($failed.failureDetails | Where-Object { $_.code -eq 'mutation-failure' }).Count | Should Be 1
        [System.IO.File]::ReadAllText($target) | Should Be $before
        Test-Path -LiteralPath (Join-Path $userHome '.agents\update-agent-environment.recovery.json') | Should Be $false
    }

    # Scenario: Rollback itself is interrupted after the mutation failure.
    # Purpose: Preserve the install journal and classify the result as recovery-required instead of claiming completed rollback.
    It 'InterT26_reports_recovery_required_when_install_journal_rollback_is_interrupted' {
        $initial = New-TestDesiredState -Root (Join-Path $staging 'initial') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $next = New-TestDesiredState -Root (Join-Path $staging 'next') -SkillIds @('alpha','beta')
        $failed = Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -FailureAfterMutationCount 1 -FailpointName during-rollback

        $failed.outcome | Should Be 'failed'
        $failed.rollbackState | Should Be 'recovery-required'
        @($failed.failureDetails | Where-Object { $_.code -eq 'recovery-required' }).Count | Should Be 1
        ($failed.failureDetails[0].evidence) | Should Match 'Rollback failed'
        Test-Path -LiteralPath $failed.backupPath -PathType Container | Should Be $true
        Test-Path -LiteralPath (Join-Path $failed.backupPath 'journal.json') -PathType Leaf | Should Be $true
    }

    It 'reports drift in VerifyOnly and a plan in WhatIf without writing' {
        $desired = New-TestDesiredState -Root $staging
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode VerifyOnly).outcome | Should Be 'drift'
        (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode WhatIf).outcome | Should Be 'planned'
        Test-Path -LiteralPath (Join-Path $userHome '.agents') | Should Be $false
    }

    It 'returns concurrent when the global user-scope lock is already held' {
        $desired = New-TestDesiredState -Root $staging
        $agents = Join-Path $userHome '.agents'
        New-Item -ItemType Directory -Force -Path (Join-Path $agents 'skills') | Out-Null
        $stream = [System.IO.File]::Open((Join-Path $agents 'update-agent-environment.lock'),[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        try { (Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply).outcome | Should Be 'concurrent' }
        finally { $stream.Dispose() }
    }

    # Scenario: The P8 platform lock is held before a legacy File.Open contender starts.
    # Purpose: Prove the unchanged Windows FileShare.None protocol excludes legacy callers in the reverse direction too.
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
}
