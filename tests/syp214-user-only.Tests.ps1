# Reuse the established disposable bootstrap fixtures without executing their Describe blocks.
$fixtureText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'bootstrap-ai-instructions.Tests.ps1')
. ([scriptblock]::Create($fixtureText.Substring(0, $fixtureText.IndexOf("Describe 'bootstrap-ai-instructions'")).Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")))

function New-Syp214LegacySkill {
    param([string]$Repository, [string]$UserHome, [int]$SchemaVersion = 2)
    $entries = @()
    foreach ($relative in @('SKILL.md', 'assets/data.bin')) {
        $path = ".agents/skills/syp214-fixture/$relative"
        $full = Join-Path $Repository $path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
        [IO.File]::WriteAllBytes($full, [byte[]]@(0x80, 0x81, 0x0a))
        $entries += [pscustomobject][ordered]@{
            artifactType='skill'; artifactId='syp214-fixture'; sourceId='test-skills'
            sourceRepository='https://example.com/test-skills.git'; sourceRef='main'
            sourceCommit=('b'*40); sourceVersion='test@bbbbbbbb'
            sourcePath="$(if ($SchemaVersion -eq 3) { 'skills' } else { '.agents/skills' })/syp214-fixture/$relative"
            targetPath=$path; sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{schemaVersion=$SchemaVersion; catalogId='test-catalog'; lockSha256=('a'*64); files=$entries}
    New-Item -ItemType Directory -Force -Path (Join-Path $Repository '.codex') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Repository $script:ManifestPath), ($manifest | ConvertTo-Json -Depth 10) + "`n")
    [IO.File]::AppendAllText((Join-Path $Repository '.git/info/exclude'), "`n/.agents/skills/`n/.codex/`n")
    if ($UserHome) {
        foreach ($entry in $entries) {
            $full = Join-Path $UserHome $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [IO.File]::Copy((Join-Path $Repository $entry.targetPath), $full)
        }
        $userEntries = @($entries | ForEach-Object {
            [ordered]@{skillId=$_.artifactId; sourceId=$_.sourceId; sourceRepository=$_.sourceRepository
                sourceRef=$_.sourceRef; sourceCommit=$_.sourceCommit; sourceVersion=$_.sourceVersion
                sourcePath=$_.sourcePath; targetPath=$_.targetPath; sha256=$_.sha256}
        })
        $userManifest = [ordered]@{schemaVersion=$(if ($SchemaVersion -eq 3) {2} else {1})
            catalogRepository='https://example.com/ai-instructions.git'; catalogCommit=('c'*40)
            catalogId='test-catalog'; lockSha256=('a'*64); files=$userEntries}
        [IO.File]::WriteAllText((Join-Path $UserHome '.agents/catalog-skills.manifest.json'), ($userManifest | ConvertTo-Json -Depth 10))
    }
    return $entries
}

Describe 'SYP214 whole-Skill migration evidence' {
    BeforeEach {
        Import-Module (Join-Path $PSScriptRoot '../scripts/skills-catalog-contract.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '../scripts/repo-shared-skills-migration.psm1') -Force
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        New-TestRepository -Path $targetRoot
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $trusted = [pscustomobject]@{id='syp214-fixture'; sourceId='test-skills'; sourceRepository='https://example.com/test-skills.git'
            sourceCommit=('b'*40); sourceVersion='test@bbbbbbbb'; files=$entries}
    }

    # Scenario: A USER installation and ignored REPO copy have complete matching ownership.
    # Purpose: Recognize only a full stable identity and source inventory, including legacy/canonical versions.
    It 'InterT10_complete_inventory_allows_legacy_and_canonical_manifests' {
        # Given / When / Then
        foreach ($version in @(2,3)) {
            $manifest.schemaVersion = $version
            if ($version -eq 3) {
                foreach ($entry in $manifest.files) { $entry.sourcePath = $entry.sourcePath.Replace('.agents/skills/', 'skills/') }
            }
            $plan = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
            $plan.Count | Should Be 1
            $plan[0].removable | Should Be $true
            # USER is validated against its own immutable version, never against the old REPO bytes.
            foreach ($entry in $manifest.files) { $entry.sourceCommit = ('a'*40); $entry.sourceVersion='older' }
        }
    }

    # Scenario: One prerequisite is missing, customized, tracked, incomplete or unreadable.
    # Purpose: Fail closed for the entire Skill, retaining every file and manifest entry.
    It 'InterT20_protects_the_entire_Skill_for_<State>' -TestCases @(
        @{State='missing-user'}, @{State='corrupt-user'}, @{State='unreadable-user'}, @{State='unknown-user-schema'},
        @{State='customized'}, @{State='extra-file'}, @{State='tracked'}, @{State='staged'},
        @{State='not-ignored'}, @{State='unknown-ownership'}, @{State='incomplete-source'}, @{State='mixed-source'},
        @{State='newer-unverified-user'}, @{State='legacy-unowned-repo'}, @{State='mixed-version'}, @{State='reparse'}
    ) {
        param($State)
        # Given
        $locked = $null
        $repoFile = Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md'
        $userFile = Join-Path $userHome '.agents/skills/syp214-fixture/SKILL.md'
        $userManifestPath = Join-Path $userHome '.agents/catalog-skills.manifest.json'
        switch ($State) {
            'missing-user' { Remove-Item -LiteralPath $userFile }
            'corrupt-user' { Set-TestText $userFile 'corrupt' }
            'unreadable-user' { $locked = [IO.File]::Open($userFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            'unknown-user-schema' { $doc=Get-Content -Raw $userManifestPath|ConvertFrom-Json; $doc.schemaVersion=999; $doc|ConvertTo-Json -Depth 10|Set-Content $userManifestPath }
            'customized' { Set-TestText $repoFile 'customized' }
            'extra-file' { Set-TestText (Join-Path (Split-Path $repoFile) 'personal.txt') 'personal' }
            'tracked' { Invoke-TestGit $targetRoot @('add','-f','--','.agents/skills/syp214-fixture/SKILL.md')|Out-Null; Invoke-TestGit $targetRoot @('commit','-qm','project-owned')|Out-Null }
            'staged' { Invoke-TestGit $targetRoot @('add','-f','--','.agents/skills/syp214-fixture/SKILL.md')|Out-Null }
            'not-ignored' { [IO.File]::WriteAllText((Join-Path $targetRoot '.git/info/exclude'), '') }
            'unknown-ownership' { $trusted.sourceRepository='https://example.com/different.git' }
            'incomplete-source' { $trusted.files=@($entries[0]) }
            'mixed-source' { $manifest.files[0].sourceId='other-source' }
            'mixed-version' { $manifest.files[0].sourceVersion='different' }
            'reparse' { New-Item -ItemType Junction -Path (Join-Path (Split-Path $repoFile) 'linked') -Target $userHome | Out-Null }
            'newer-unverified-user' { $doc=Get-Content -Raw $userManifestPath|ConvertFrom-Json; foreach($entry in $doc.files){$entry.sourceCommit=('d'*40)}; $doc|ConvertTo-Json -Depth 10|Set-Content $userManifestPath }
            'legacy-unowned-repo' { $manifest.schemaVersion=1 }
        }
        # When / Then
        try {
            $plan = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
            $plan[0].removable | Should Be $false
            $plan[0].reason | Should Not BeNullOrEmpty
            Test-Path $repoFile | Should Be $true
            @($plan[0].entries).Count | Should Be 2
        }
        finally { if ($locked) { $locked.Dispose() } }
    }

    # Scenario: USER content, an extra REPO file, or Git index changes after the inventory.
    # Purpose: Stop before precise mutation and leave the new content intact.
    It 'InterT30_revalidates_<State>_before_mutation' -TestCases @(@{State='user' }, @{State='repo-extra'}, @{State='index'}, @{State='ignore'}) {
        param($State)
        # Given
        $plan = @(Get-RepoSharedSkillsMigrationPlan -Repository $targetRoot -Manifest $manifest -TrustedSkills @($trusted) -UserHome $userHome)
        $plan[0].removable | Should Be $true
        switch ($State) {
            'user' { Set-TestText (Join-Path $userHome '.agents/skills/syp214-fixture/SKILL.md') 'changed' }
            'repo-extra' { Set-TestText (Join-Path $targetRoot '.agents/skills/syp214-fixture/new.txt') 'new personal file' }
            'ignore' { [IO.File]::WriteAllText((Join-Path $targetRoot '.git/info/exclude'), '') }
            'index' { Set-TestText (Join-Path $targetRoot 'README.md') 'staged'; Invoke-TestGit $targetRoot @('add','README.md') | Out-Null }
        }
        # When / Then
        { Assert-RepoSharedSkillsMigrationEvidence -Repository $targetRoot -Skill $plan[0] } | Should Throw 'concurrently'
        Test-Path (Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md') | Should Be $true
    }
}

function New-Syp214BootstrapMutationPrefix {
    $bootstrapPath = (Resolve-Path -LiteralPath $script:BootstrapScript).Path
    $bootstrapText = [IO.File]::ReadAllText($bootstrapPath)
    $prefixEnd = $bootstrapText.IndexOf('$syncStartPath = ', [StringComparison]::Ordinal)
    if ($prefixEnd -lt 0) { throw 'Could not find the bootstrap definition prefix boundary.' }
    $bootstrapRoot = Split-Path -Parent $bootstrapPath
    $bootstrapRootLiteral = "'" + $bootstrapRoot.Replace("'", "''") + "'"
    $prefixText = $bootstrapText.Substring(0, $prefixEnd).Replace('$PSScriptRoot', $bootstrapRootLiteral)
    return ,([scriptblock]::Create($prefixText))
}

Describe 'SYP214 generic managed Instructions deletion recovery' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $targetRoot = Join-Path $caseRoot 'consumer'
        New-TestRepository -Path $targetRoot
        $targetRoot = (Resolve-Path -LiteralPath $targetRoot).Path
        $relativePath = '.codex/AI-Rules/Obsolete.en.md'
        $targetPath = Join-Path $targetRoot $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
        Set-TestText -Path $targetPath -Value '# stale managed Instructions'
        $originalBytes = [IO.File]::ReadAllBytes($targetPath)
        $originalHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $backupRoot = Join-Path $caseRoot 'target-backup'
        $journalPath = Join-Path $backupRoot 'skill-migration.json'
    }

    # Scenario: Generic managed-file deletion is interrupted after atomic removal but before in-memory mutation state is updated.
    # Purpose: Recover the exact stale Instructions bytes from the durable backup journal.
    It 'InterT10_restores_stale_Instructions_after_atomic_delete_interruption' {
        # Given
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $bootstrapPrefix = New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -GitExecutable 'git'
            $snapshot = New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState = Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext = [pscustomobject]@{
                Snapshot = $snapshot; ExcludeSnapshot = $excludeSnapshot; Path = $journalPath; GitState = $gitState
            }

            $atomicDeletePath = 'Function:\Remove-TargetMutationFileAtomically'
            $realAtomicDelete = (Get-Command Remove-TargetMutationFileAtomically -CommandType Function).ScriptBlock
            $interruptionSentinel = 'SYP214 interruption ' + [guid]::NewGuid().ToString('N')
            $interruptAfterDelete = {
                param(
                    [Parameter(Mandatory = $true)][object] $Snapshot,
                    [Parameter(Mandatory = $true)][string] $RelativePath,
                    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $ExpectedBytes,
                    [Parameter(Mandatory = $true)][string] $Operation
                )
                & $realAtomicDelete @PSBoundParameters
                throw $interruptionSentinel
            }.GetNewClosure()
            # When
            $interruptionObserved = $false
            try {
                Set-Item -Path $atomicDeletePath -Value $interruptAfterDelete
                try {
                    Remove-TargetMutationFile -Snapshot $snapshot -RelativePath $relativePath
                }
                catch {
                    if ($_.Exception.Message -cne $interruptionSentinel) { throw }
                    $interruptionObserved = $true
                }
            }
            finally { Set-Item -Path $atomicDeletePath -Value $realAtomicDelete }

            # Then
            $interruptionObserved | Should Be $true
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $false
            Restore-SkillMigrationJournal -Repository $snapshot.TargetRoot -Path $journalPath | Out-Null
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $originalBytes) | Should Be $true
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $originalHash
        }
        finally {
            $script:SkillMigrationJournalContext = $null
            $ErrorActionPreference = $previousErrorActionPreference
            Set-StrictMode -Off
        }
    }

    # Scenario: A user edit recreates the stale Instructions path after interrupted deletion but before recovery.
    # Purpose: Stop recovery when current bytes differ and preserve the later edit unchanged.
    It 'InterT20_preserves_later_Instructions_edit_after_atomic_delete_interruption' {
        # Given
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $bootstrapPrefix = New-Syp214BootstrapMutationPrefix
            . $bootstrapPrefix -TargetRoot $targetRoot -GitExecutable 'git'
            $snapshot = New-TargetMutationSnapshot -TargetRoot $targetRoot -RelativePaths @($relativePath) -BackupRoot $backupRoot
            $excludeSnapshot = New-GitInfoExcludeSnapshot -Repository $targetRoot
            $gitState = Get-RepoSkillMigrationGitState -Repository $targetRoot -GitExecutable 'git'
            Save-SkillMigrationJournal -Snapshot $snapshot -ExcludeSnapshot $excludeSnapshot `
                -Path $journalPath -GitState $gitState -Phase 'mutating'
            $script:SkillMigrationJournalContext = [pscustomobject]@{
                Snapshot = $snapshot; ExcludeSnapshot = $excludeSnapshot; Path = $journalPath; GitState = $gitState
            }

            $atomicDeletePath = 'Function:\Remove-TargetMutationFileAtomically'
            $realAtomicDelete = (Get-Command Remove-TargetMutationFileAtomically -CommandType Function).ScriptBlock
            $interruptionSentinel = 'SYP214 interruption ' + [guid]::NewGuid().ToString('N')
            $interruptAfterDelete = {
                param(
                    [Parameter(Mandatory = $true)][object] $Snapshot,
                    [Parameter(Mandatory = $true)][string] $RelativePath,
                    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $ExpectedBytes,
                    [Parameter(Mandatory = $true)][string] $Operation
                )
                & $realAtomicDelete @PSBoundParameters
                throw $interruptionSentinel
            }.GetNewClosure()
            # When
            $interruptionObserved = $false
            try {
                Set-Item -Path $atomicDeletePath -Value $interruptAfterDelete
                try {
                    Remove-TargetMutationFile -Snapshot $snapshot -RelativePath $relativePath
                }
                catch {
                    if ($_.Exception.Message -cne $interruptionSentinel) { throw }
                    $interruptionObserved = $true
                }
            }
            finally { Set-Item -Path $atomicDeletePath -Value $realAtomicDelete }

            # Then
            $interruptionObserved | Should Be $true
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $false
            Set-TestText -Path $targetPath -Value '# later user Instructions edit'
            $laterEditBytes = [IO.File]::ReadAllBytes($targetPath)
            $laterEditHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            { Restore-SkillMigrationJournal -Repository $snapshot.TargetRoot -Path $journalPath } | Should Throw 'preserved'
            Test-Path -LiteralPath $targetPath -PathType Leaf | Should Be $true
            (Test-TargetMutationBytesEqual -Left ([IO.File]::ReadAllBytes($targetPath)) -Right $laterEditBytes) | Should Be $true
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $laterEditHash
        }
        finally {
            $script:SkillMigrationJournalContext = $null
            $ErrorActionPreference = $previousErrorActionPreference
            Set-StrictMode -Off
        }
    }
}

function Invoke-Syp214Bootstrap {
    param([switch]$WhatIf, [int]$FailureAfterSkillRemovalCount = 0, [string]$RecoverSkillMigration)
    New-TestProvenance -ArchivePath $sourceArchive -Path $script:TestProvenancePath
    $arguments = @('-NoProfile','-File',$script:BootstrapScript,'-SourceArchivePath',$sourceArchive,
        '-TargetRoot',$targetRoot,'-ConfigurationPath',$script:TestConfigurationPath,
        '-ProvenancePath',$script:TestProvenancePath,'-UserHome',$userHome)
    if ($RecoverSkillMigration) { $arguments += @('-RecoverSkillMigration', $RecoverSkillMigration) }
    if ($WhatIf) { $arguments += '-WhatIf' }
    if ($FailureAfterSkillRemovalCount) { $arguments += @('-FailureAfterSkillRemovalCount', $FailureAfterSkillRemovalCount) }
    $output = & $script:TestPowerShellExecutable @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return $output
}

function Get-Syp214FileInventory {
    param([string]$Root,[string[]]$RelativePaths)
    $resolvedRoot=[IO.Path]::GetFullPath($Root)
    foreach($relative in @($RelativePaths | Sort-Object -Unique)){
        $normalized=[string]$relative -replace '\\','/'
        $full=Join-Path $resolvedRoot $normalized.Replace('/',[string][IO.Path]::DirectorySeparatorChar)
        if(Test-Path -LiteralPath $full){
            $item=Get-Item -Force -LiteralPath $full
            if($item.PSIsContainer){
                [ordered]@{relativePath=$normalized;type='directory';length=$null;sha256=$null}
            }
            else{
                [ordered]@{relativePath=$normalized;type='file';length=[long]$item.Length
                    sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
        }
        else{
            [ordered]@{relativePath=$normalized;type='missing';length=$null;sha256=$null}
        }
    }
}

function Get-Syp214FixtureSnapshot {
    param([string]$Repository,[string]$UserHome,[object[]]$Entries)
    $repositoryPaths=@(@($Entries | ForEach-Object { [string]$_.targetPath }) + @($script:ManifestPath,'AGENTS.md'))
    $userPaths=@(@($Entries | ForEach-Object { [string]$_.targetPath }) + @('.agents/catalog-skills.manifest.json'))
    $indexPath=Join-Path $Repository '.git/index'
    [ordered]@{
        repository=[ordered]@{
            files=@(Get-Syp214FileInventory -Root $Repository -RelativePaths $repositoryPaths)
            head=((Invoke-TestGit $Repository @('rev-parse','HEAD') | Select-Object -First 1).Trim())
            indexSha256=$(if(Test-Path -LiteralPath $indexPath -PathType Leaf){(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null})
            status=@(Invoke-TestGit $Repository @('status','--porcelain'))
            stashes=@(Invoke-TestGit $Repository @('stash','list','--format=%H%x00%gs'))
        }
        user=[ordered]@{files=@(Get-Syp214FileInventory -Root $UserHome -RelativePaths $userPaths)}
    }
}

function Get-Syp214JournalInventory {
    param([string]$JournalPath,[object]$Journal)
    $journalName=[string](Split-Path -Leaf $JournalPath)
    $backupStates=@($Journal.states | Where-Object { [string]$_.originalType -ceq 'file' })
    $relativePaths=@($journalName)
    $relativePaths+=@($backupStates | ForEach-Object { [string]$_.backupName })
    $inventory=@(Get-Syp214FileInventory -Root (Split-Path -Parent $JournalPath) -RelativePaths $relativePaths)
    foreach($item in $inventory){
        if([string]$item.relativePath -ceq $journalName){
            $item['kind']='journal'
            $item['expectedSha256']=$null
            $item['matchesJournalSha256']=$null
        }
        else{
            $state=@($backupStates | Where-Object { [string]$_.backupName -ceq [string]$item.relativePath })[0]
            $expectedSha256=[string]$state.backupSha256
            $matchesJournalSha256=([string]$item.type -ceq 'file' -and
                [string]$item.sha256 -cmatch '^[0-9a-f]{64}$' -and
                [string]$item.sha256 -ceq $expectedSha256)
            $item['kind']='backup'
            $item['expectedSha256']=$expectedSha256
            $item['matchesJournalSha256']=$matchesJournalSha256
        }
        $item
    }
}

function Test-Syp214JournalInventory {
    param([object[]]$Inventory,[object]$Journal,[string]$ExpectedCorruptBackupName)
    $journalRecords=@($Inventory | Where-Object { [string]$_.kind -ceq 'journal' })
    if($journalRecords.Count -ne 1 -or [string]$journalRecords[0].type -cne 'file' -or
        $null -eq $journalRecords[0].length -or [long]$journalRecords[0].length -lt 0 -or
        [string]$journalRecords[0].sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }

    $backupStates=@($Journal.states | Where-Object { [string]$_.originalType -ceq 'file' })
    $backupRecords=@($Inventory | Where-Object { [string]$_.kind -ceq 'backup' })
    if($backupRecords.Count -ne $backupStates.Count) { return $false }
    $corruptWitnessFound=$false
    foreach($state in $backupStates){
        $record=@($backupRecords | Where-Object { [string]$_.relativePath -ceq [string]$state.backupName })
        if($record.Count -ne 1 -or [string]$record[0].type -cne 'file' -or
            $null -eq $record[0].length -or [long]$record[0].length -lt 0 -or
            [string]$state.backupSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$record[0].sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }
        $matchesJournalSha256=([string]$record[0].sha256 -ceq [string]$state.backupSha256)
        if([bool]$record[0].matchesJournalSha256 -ne $matchesJournalSha256) { return $false }
        if([string]$state.backupName -ceq $ExpectedCorruptBackupName){
            if($matchesJournalSha256) { return $false }
            $corruptWitnessFound=$true
        }
        elseif(-not $matchesJournalSha256){ return $false }
    }
    if(-not [string]::IsNullOrEmpty($ExpectedCorruptBackupName) -and -not $corruptWitnessFound) { return $false }
    return $true
}

function Get-Syp214RunIdentity {
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $testPath=[IO.Path]::GetFullPath($PSCommandPath)
    $bootstrapPath=[IO.Path]::GetFullPath($script:BootstrapScript)
    [ordered]@{
        runId=[string]$env:GITHUB_RUN_ID
        runAttempt=[string]$env:GITHUB_RUN_ATTEMPT
        workflow=[string]$env:GITHUB_WORKFLOW
        event=[string]$env:GITHUB_EVENT_NAME
        ref=[string]$env:GITHUB_REF
        sourceHeadCommit=[string]$env:SYP214_SOURCE_HEAD_SHA
        checkoutHeadCommit=((Invoke-TestGit $repositoryRoot @('rev-parse','HEAD') | Select-Object -First 1).Trim())
        checkoutTree=((Invoke-TestGit $repositoryRoot @('rev-parse','HEAD^{tree}') | Select-Object -First 1).Trim())
        testScriptSha256=(Get-FileHash -LiteralPath $testPath -Algorithm SHA256).Hash.ToLowerInvariant()
        bootstrapScriptSha256=(Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash.ToLowerInvariant()
        powershellVersion=$PSVersionTable.PSVersion.ToString()
        powershellExecutable=[IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
        pesterVersion=[string]$env:SYP214_PESTER_VERSION
    }
}

function Save-Syp214FixtureEvidence {
    param([string]$Name,[object]$Value)
    if (-not $env:SYP214_FIXTURE_EVIDENCE_ROOT) { return }
    $root=[IO.Path]::GetFullPath($env:SYP214_FIXTURE_EVIDENCE_ROOT)
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText((Join-Path $root ($Name+'.json')),($Value | ConvertTo-Json -Depth 14)+"`n",[Text.UTF8Encoding]::new($false))
}

Describe 'SYP214 USER-only bootstrap boundary' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $caseRoot 'source'
        $sourceArchive = Join-Path $caseRoot 'source.zip'
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        $script:TestConfigurationPath = Join-Path $caseRoot 'config.json'
        $script:TestProvenancePath = Join-Path $caseRoot 'provenance.json'
        New-TestSource -Path $sourceRoot
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $script:TestConfigurationPath
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture') | Out-Null
        Set-TestText -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture/SKILL.md') -Value '# Shared fixture'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
    }

    # Scenario: A direct entry receives a legacy composed archive with selected Skills.
    # Purpose: Enforce the final consumer scope regardless of USER availability or archive age.
    It 'InterT10_legacy_archive_never_installs_shared_Skills_but_updates_Instructions' {
        # Given / When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot | Out-Null
        # Then
        Test-Path (Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md') | Should Be $false
        (Get-Content -Raw (Join-Path $targetRoot 'AGENTS.md')).Trim() | Should Be '# Codex English Base'
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
    }

    # Scenario: An old ignored manifest-owned Skill has no trusted USER installation.
    # Purpose: Neither stale pruning nor an archive update may delete or replace it.
    It 'InterT20_missing_USER_preserves_the_entire_legacy_Skill_and_ownership' {
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot
        Remove-Item -LiteralPath (Join-Path $sourceRoot '.agents/skills/syp214-fixture') -Recurse -Force
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        # When
        $output = Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot
        # Then
        foreach ($entry in $entries) {
            Test-Path (Join-Path $targetRoot $entry.targetPath) | Should Be $true
            (Get-FileHash -LiteralPath (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256
        }
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 2
        ($output -join ' ') | Should Match 'USER.*repair|USER.*unavailable'
    }


    # Scenario: A clean consumer sees missing, corrupt or unreadable USER Skills.
    # Purpose: Continue Instructions updates with repair guidance and no REPO fallback or USER mutation.
    It 'InterT25_no_USER_fallback_for_<State>' -TestCases @(@{State='missing'},@{State='corrupt'},@{State='unreadable'}) {
        param($State)
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        foreach ($entry in $entries) { Remove-Item -LiteralPath (Join-Path $targetRoot $entry.targetPath) }
        Remove-Item -LiteralPath (Join-Path $targetRoot $script:ManifestPath)
        $userFile = Join-Path $userHome '.agents/skills/syp214-fixture/SKILL.md'
        $userManifest = Join-Path $userHome '.agents/catalog-skills.manifest.json'
        $beforeManifest = (Get-FileHash -LiteralPath $userManifest).Hash
        $locked = $null
        switch ($State) {
            'missing' { Remove-Item -LiteralPath $userFile }
            'corrupt' { Set-TestText $userFile 'personal corrupt bytes' }
            'unreadable' { $locked=[IO.File]::Open($userFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        }
        # When / Then
        try {
            $output = Invoke-Syp214Bootstrap
            ($output -join ' ') | Should Match 'USER Skill repair/update required.*REPO fallback is disabled'
            Test-Path (Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md') | Should Be $false
            Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
            (Get-FileHash -LiteralPath $userManifest).Hash | Should Be $beforeManifest
        }
        finally { if ($locked) { $locked.Dispose() } }
    }

    # Scenario: A historical manifest lists the same tracked project Skill as a selected shared Skill.
    # Purpose: Preserve project bytes and Git ownership rather than remediate or reclassify the Skill.
    It 'InterT35_tracked_manifest_Skill_is_preserved' {
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $path='.agents/skills/syp214-fixture/SKILL.md'
        Invoke-TestGit $targetRoot @('add','-f','--',$path) | Out-Null
        Invoke-TestGit $targetRoot @('commit','-qm','project Skill with stale ownership') | Out-Null
        $head=Invoke-TestGit $targetRoot @('rev-parse','HEAD')
        $index=(Get-FileHash (Join-Path $targetRoot '.git/index')).Hash
        # When
        Invoke-Syp214Bootstrap | Out-Null
        # Then
        (Invoke-TestGit $targetRoot @('rev-parse','HEAD')) | Should Be $head
        (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash | Should Be $index
        foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
    }

    # Scenario: A project owns a tracked/staged Skill in a name also selected by the Catalog.
    # Purpose: Preserve project content, index and HEAD before reserved remediation runs.
    It 'InterT30_tracked_project_Skill_survives_remediation_and_bootstrap' {
        # Given
        $path = Join-Path $targetRoot '.agents/skills/syp214-fixture/SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-TestText -Path $path -Value '# Project-owned'
        Invoke-TestGit $targetRoot @('add','--','.agents/skills/syp214-fixture/SKILL.md') | Out-Null
        Invoke-TestGit $targetRoot @('commit','-qm','project Skill') | Out-Null
        Set-TestText -Path $path -Value '# Staged project-owned'
        Invoke-TestGit $targetRoot @('add','--','.agents/skills/syp214-fixture/SKILL.md') | Out-Null
        $head = Invoke-TestGit $targetRoot @('rev-parse','HEAD')
        $index = (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash
        # When
        Invoke-BootstrapScript -SourceArchivePath $sourceArchive -TargetRoot $targetRoot | Out-Null
        # Then
        (Get-Content -Raw $path).Trim() | Should Be '# Staged project-owned'
        (Invoke-TestGit $targetRoot @('rev-parse','HEAD')) | Should Be $head
        (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash | Should Be $index
    }

    # Scenario: An ignored REPO copy has identical USER bytes but no historical manifest.
    # Purpose: Report unknown ownership without adopting or deleting any Skill files.
    It 'InterT32_identical_unowned_copy_is_preserved_without_inferred_ownership' {
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        Remove-Item -LiteralPath (Join-Path $targetRoot $script:ManifestPath)
        # When
        $output=Invoke-Syp214Bootstrap
        # Then
        ($output -join ' ') | Should Match 'preserved without provable shared ownership'
        foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $manifest=Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
    }

    # Scenario: A real schema-v1 consumer manifest has no per-file shared source ownership.
    # Purpose: Keep the historical Skill and schema while still updating Instructions.
    It 'InterT36_preserves_unprovable_v1_Skill_ownership_and_updates_Instructions' {
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        $legacy=[ordered]@{schemaVersion=1;sourceRepository='https://example.com/ai-instructions.git';sourceRef='legacy-pin';files=@($entries | Select-Object sourcePath,targetPath,sha256)}
        Set-TestText (Join-Path $targetRoot $script:ManifestPath) ($legacy | ConvertTo-Json -Depth 10)
        # When
        Invoke-Syp214Bootstrap | Out-Null
        # Then
        $manifest=Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        $manifest.schemaVersion | Should Be 1
        @($manifest.files | Where-Object targetPath -like '.agents/skills/*').Count | Should Be 2
        Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $true
        foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
    }

}

Describe 'SYP214 USER-only bootstrap fixture evidence' -Tag 'Syp214FixtureEvidence' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sourceRoot = Join-Path $caseRoot 'source'
        $sourceArchive = Join-Path $caseRoot 'source.zip'
        $targetRoot = Join-Path $caseRoot 'consumer'
        $userHome = Join-Path $caseRoot 'user'
        $script:TestConfigurationPath = Join-Path $caseRoot 'config.json'
        $script:TestProvenancePath = Join-Path $caseRoot 'provenance.json'
        New-TestSource -Path $sourceRoot
        New-TestRepository -Path $targetRoot
        New-TestConfiguration -Path $script:TestConfigurationPath
        New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture') | Out-Null
        Set-TestText -Path (Join-Path $sourceRoot '.agents/skills/syp214-fixture/SKILL.md') -Value '# Shared fixture'
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
    }

    # Scenario: Valid USER and old REPO manifests own the same complete immutable Skill.
    # Purpose: Retire only ignored unchanged files, retain backup, and never rebuild after a branch change.
    It 'InterT40_verified_USER_allows_exact_migration_after_a_mutation_free_dry_run' {
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        foreach ($entry in $entries) {
            $full = Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath), $full, $true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $head = Invoke-TestGit $targetRoot @('rev-parse','HEAD')
        $index = (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash
        $manifestBefore = [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $beforeSnapshot = Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $bootstrapAndBranchRuns=0
        $dryRunCount=0
        # When / Then
        Invoke-Syp214Bootstrap -WhatIf | Out-Null
        $dryRunCount++
        $manifestAfterDryRun = [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $manifestAfterDryRun | Should Be $manifestBefore
        Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
        $output = Invoke-Syp214Bootstrap
        $bootstrapAndBranchRuns++
        foreach ($entry in $entries) { Test-Path (Join-Path $targetRoot $entry.targetPath) | Should Be $false }
        ($output -join ' ') | Should Match 'Skill migration.*Backup'
        $manifest = Get-Content -Raw (Join-Path $targetRoot $script:ManifestPath) | ConvertFrom-Json
        @($manifest.files | Where-Object artifactType -eq 'skill').Count | Should Be 0
        $after = (Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash
        $line=@($output | ForEach-Object {[string]$_} | Where-Object {$_ -match '^Skill migration transaction retained\.'})[0]
        $journalPath=$line.Substring($line.IndexOf('journal: ') + 9).Trim()
        $journal=Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
        $journalFilesBeforeNoOpRuns=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $journalInventoryVerifiedBeforeNoOpRuns=Test-Syp214JournalInventory -Inventory $journalFilesBeforeNoOpRuns -Journal $journal
        $journalInventoryVerifiedBeforeNoOpRuns | Should Be $true
        Invoke-Syp214Bootstrap | Out-Null
        $bootstrapAndBranchRuns++
        Invoke-TestGit $targetRoot @('checkout','-qb','other') | Out-Null
        Invoke-Syp214Bootstrap | Out-Null
        $bootstrapAndBranchRuns++
        (Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash | Should Be $after
        (Invoke-TestGit $targetRoot @('rev-parse','HEAD')) | Should Be $head
        (Get-FileHash (Join-Path $targetRoot '.git/index')).Hash | Should Be $index
        foreach ($entry in $entries) { (Get-FileHash (Join-Path $userHome $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $afterSnapshot = Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $userBytesStable = (ConvertTo-Json -InputObject @($beforeSnapshot.user.files) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($afterSnapshot.user.files) -Depth 6 -Compress)
        $manifestDryRunStable = $manifestAfterDryRun -ceq $manifestBefore
        $indexPreserved = ([string]$afterSnapshot.repository.indexSha256 -ceq ([string]$beforeSnapshot.repository.indexSha256))
        $headPreserved = ([string]$afterSnapshot.repository.head -ceq ([string]$beforeSnapshot.repository.head))
        $journalFilesAfterNoOpRuns=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $journalInventoryVerifiedAfterNoOpRuns=Test-Syp214JournalInventory -Inventory $journalFilesAfterNoOpRuns -Journal $journal
        $journalInventoryStable=(ConvertTo-Json -InputObject $journalFilesBeforeNoOpRuns -Depth 6 -Compress) -ceq
            (ConvertTo-Json -InputObject $journalFilesAfterNoOpRuns -Depth 6 -Compress)
        $userBytesStable | Should Be $true
        $manifestDryRunStable | Should Be $true
        $journalInventoryVerifiedAfterNoOpRuns | Should Be $true
        $journalInventoryStable | Should Be $true
        $runIdentity=Get-Syp214RunIdentity
        Save-Syp214FixtureEvidence 'migration' ([ordered]@{
            schemaVersion=2; scope='disposable integration fixture'; skillId='syp214-fixture'; runIdentity=$runIdentity
            before=$beforeSnapshot; after=$afterSnapshot; userBytesStable=$userBytesStable
            repoBefore=@($entries); repoAfter=@($entries | ForEach-Object { [ordered]@{targetPath=$_.targetPath; exists=(Test-Path (Join-Path $targetRoot $_.targetPath))} })
            userAfter=@($entries | ForEach-Object { [ordered]@{targetPath=$_.targetPath; sha256=(Get-FileHash (Join-Path $userHome $_.targetPath)).Hash.ToLowerInvariant()} })
            manifestBeforeSha256=([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifestBefore)) | ForEach-Object ToString x2) -join ''
            manifestAfterSha256=(Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash.ToLowerInvariant()
            instructionAfter=@($manifest.files | Select-Object targetPath,sha256)
            backupInventory=@($journal.states | Where-Object originalType -eq 'file' | Select-Object relativePath,backupName,backupSha256)
            journalFilesBeforeNoOpRuns=$journalFilesBeforeNoOpRuns;journalFilesAfterNoOpRuns=$journalFilesAfterNoOpRuns
            journalInventoryVerifiedBeforeNoOpRuns=$journalInventoryVerifiedBeforeNoOpRuns
            journalInventoryVerifiedAfterNoOpRuns=$journalInventoryVerifiedAfterNoOpRuns;journalInventoryStable=$journalInventoryStable
            journalPhase=$journal.phase; dryRunPreservedManifest=$manifestDryRunStable
            dryRunManifestSha256=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifestAfterDryRun))).Replace('-','').ToLowerInvariant())
            dryRunCount=$dryRunCount; bootstrapAndBranchRuns=$bootstrapAndBranchRuns
            indexPreserved=$indexPreserved; headPreserved=$headPreserved
        })
    }

    # Scenario: A failure occurs after the first verified Skill file removal.
    # Purpose: Restore exact original files and manifest through the existing mutation transaction.
    It 'InterT50_failure_during_migration_restores_exact_files_and_manifest' {
        # Given
        $entries = New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        foreach ($entry in $entries) {
            $full = Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath), $full, $true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $before = [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $beforeSnapshot = Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        # When
        $failureMessage=''
        try { Invoke-Syp214Bootstrap -FailureAfterSkillRemovalCount 1 | Out-Null }
        catch { $failureMessage=$_.Exception.Message }
        $failureMessage | Should Match 'Injected Skill migration failure'
        # Then
        $manifestAfter=[IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $manifestAfter | Should Be $before
        foreach ($entry in $entries) { (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $afterSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $restoredFiles=@(Get-Syp214FileInventory -Root $targetRoot -RelativePaths @($entries | ForEach-Object { [string]$_.targetPath }))
        $filesRestored=(@($restoredFiles | Where-Object { $_.type -ne 'file' }).Count -eq 0 -and
            @($entries | Where-Object { $expected=$_; @($restoredFiles | Where-Object { $_.relativePath -ceq $expected.targetPath -and $_.sha256 -ceq $expected.sha256 }).Count -ne 1 }).Count -eq 0)
        $manifestRestored=($manifestAfter -ceq $before)
        $userBytesPreserved=(ConvertTo-Json -InputObject @($beforeSnapshot.user.files) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($afterSnapshot.user.files) -Depth 6 -Compress)
        $verified=($failureMessage -match 'Injected Skill migration failure' -and $filesRestored -and $manifestRestored -and $userBytesPreserved)
        $verified | Should Be $true
        Save-Syp214FixtureEvidence 'failure-rollback' ([ordered]@{
            schemaVersion=2;scope='disposable integration fixture';runIdentity=(Get-Syp214RunIdentity)
            failureAfterRemovedFiles=1;failureMessage=$failureMessage;before=$beforeSnapshot;after=$afterSnapshot
            originalManifestRestored=$manifestRestored;restoredFiles=$restoredFiles;userBytesPreserved=$userBytesPreserved;verified=$verified
        })
    }

    # Scenario: A completed or interrupted transaction is recovered from its durable backup.
    # Purpose: Restore exact pre-migration state and refuse later edits or a corrupt backup.
    It 'InterT60_durable_recovery_<State>' -TestCases @(@{State='exact'},@{State='later-edit'},@{State='corrupt-backup'},@{State='pending-intent'}) {
        param($State)
        # Given
        $entries=New-Syp214LegacySkill -Repository $targetRoot -UserHome $userHome
        foreach($entry in $entries){
            $full=Join-Path $sourceRoot $entry.targetPath
            New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
            [IO.File]::Copy((Join-Path $targetRoot $entry.targetPath),$full,$true)
        }
        Compress-TestSource -SourceRoot $sourceRoot -ArchivePath $sourceArchive
        $manifestBefore=[IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
        $beforeSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $output=Invoke-Syp214Bootstrap
        $line=@($output | ForEach-Object {[string]$_} | Where-Object {$_ -match '^Skill migration transaction retained\.'})[0]
        $journalPath=$line.Substring($line.IndexOf('journal: ') + 9).Trim()
        Test-Path -LiteralPath $journalPath | Should Be $true
        $journal=Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
        $repoFile=Join-Path $targetRoot $entries[0].targetPath
        switch($State){
            'later-edit' { Set-TestText $repoFile 'later project edit' }
            'corrupt-backup' { Set-TestText (Join-Path (Split-Path $journalPath) $journal.states[0].backupName) 'corrupt backup' }
            'pending-intent' {
                # Model a crash after flushing intent, before the final manifest write.
                [IO.File]::WriteAllText((Join-Path $targetRoot $script:ManifestPath),$manifestBefore)
                $journal.phase='mutating'
                $journal | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $journalPath
            }
        }
        $preRecoverySnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $journalFilesBeforeRecovery=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $corruptBackupName=if($State -eq 'corrupt-backup'){[string]$journal.states[0].backupName}else{''}
        $journalInventoryVerifiedBeforeRecovery=Test-Syp214JournalInventory -Inventory $journalFilesBeforeRecovery -Journal $journal -ExpectedCorruptBackupName $corruptBackupName
        $journalInventoryVerifiedBeforeRecovery | Should Be $true
        $corruptBackupWitness=if($corruptBackupName){@($journalFilesBeforeRecovery | Where-Object { [string]$_.relativePath -ceq $corruptBackupName } | Select-Object relativePath,expectedSha256,sha256,matchesJournalSha256)[0]}else{$null}
        $recoveryError=''
        $recoveryOutput=@()
        # When / Then
        if($State -eq 'later-edit'){
            try { $recoveryOutput=@(Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath) }
            catch { $recoveryError=$_.Exception.Message }
            $recoveryError | Should Match 'preserved'
            (Get-Content -Raw $repoFile).Trim() | Should Be 'later project edit'
        }
        elseif($State -eq 'corrupt-backup'){
            $after=(Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash
            try { $recoveryOutput=@(Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath) }
            catch { $recoveryError=$_.Exception.Message }
            $recoveryError | Should Match 'backup hash mismatch'
            (Get-FileHash (Join-Path $targetRoot $script:ManifestPath)).Hash | Should Be $after
            Test-Path -LiteralPath $repoFile | Should Be $false
        }
        else {
            $recoveryOutput=@(Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath)
            [IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath)) | Should Be $manifestBefore
            Test-Path (Join-Path $targetRoot 'AGENTS.md') | Should Be $false
            foreach($entry in $entries){ (Get-FileHash (Join-Path $targetRoot $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
            Invoke-Syp214Bootstrap -RecoverSkillMigration $journalPath | Out-Null
        }
        foreach($entry in $entries){ (Get-FileHash (Join-Path $userHome $entry.targetPath)).Hash.ToLowerInvariant() | Should Be $entry.sha256 }
        $afterSnapshot=Get-Syp214FixtureSnapshot -Repository $targetRoot -UserHome $userHome -Entries $entries
        $journalFilesAfterRecovery=@(Get-Syp214JournalInventory -JournalPath $journalPath -Journal $journal)
        $journalInventoryVerifiedAfterRecovery=Test-Syp214JournalInventory -Inventory $journalFilesAfterRecovery -Journal $journal -ExpectedCorruptBackupName $corruptBackupName
        $journalInventoryVerifiedAfterRecovery | Should Be $true
        $journalAfterRecovery=if(Test-Path -LiteralPath $journalPath -PathType Leaf){Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json}else{$null}
        $userBytesPreserved=(ConvertTo-Json -InputObject @($beforeSnapshot.user.files) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($afterSnapshot.user.files) -Depth 6 -Compress)
        $repositoryStateVerified=$false
        if($State -eq 'later-edit'){
            $repositoryStateVerified=((Get-Content -Raw $repoFile).Trim() -ceq 'later project edit' -and $recoveryError -match 'preserved')
        }
        elseif($State -eq 'corrupt-backup'){
            $manifestPath=Join-Path $targetRoot $script:ManifestPath
            $manifestBeforeRecoveryHash=[string](@($preRecoverySnapshot.repository.files | Where-Object { $_.relativePath -ceq '.codex/ai-instructions.manifest.json' })[0].sha256)
            $repositoryStateVerified=(-not (Test-Path -LiteralPath $repoFile) -and
                (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $manifestBeforeRecoveryHash)
        }
        else{
            $manifestAfter=[IO.File]::ReadAllText((Join-Path $targetRoot $script:ManifestPath))
            $filesRestored=@($entries | Where-Object {
                $entry=$_
                (Get-FileHash -LiteralPath (Join-Path $targetRoot $entry.targetPath) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256
            }).Count -eq 0
            $repositoryStateVerified=($manifestAfter -ceq $manifestBefore -and -not (Test-Path -LiteralPath (Join-Path $targetRoot 'AGENTS.md')) -and $filesRestored)
        }
        $verified=($userBytesPreserved -and $repositoryStateVerified -and $journalInventoryVerifiedBeforeRecovery -and $journalInventoryVerifiedAfterRecovery)
        $verified | Should Be $true
        Save-Syp214FixtureEvidence ('recovery-'+$State) ([ordered]@{
            schemaVersion=2;scope='disposable integration fixture';runIdentity=(Get-Syp214RunIdentity);scenario=$State
            before=$beforeSnapshot;preRecovery=$preRecoverySnapshot;after=$afterSnapshot
            journalBeforeRecovery=$journal;journalAfterRecovery=$journalAfterRecovery
            journalFilesBeforeRecovery=$journalFilesBeforeRecovery;journalFilesAfterRecovery=$journalFilesAfterRecovery
            journalInventoryVerifiedBeforeRecovery=$journalInventoryVerifiedBeforeRecovery
            journalInventoryVerifiedAfterRecovery=$journalInventoryVerifiedAfterRecovery;corruptBackupWitness=$corruptBackupWitness
            recoveryOutput=@($recoveryOutput | ForEach-Object { [string]$_ });recoveryError=$recoveryError
            verified=$verified;repositoryStateVerified=$repositoryStateVerified;userBytesPreserved=$userBytesPreserved
            processKillExecuted=$false;interruptionModel=$(if($State -eq 'pending-intent'){'manually persisted pending-intent journal state'}else{'no process termination'})
        })
    }
}
