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
        [hashtable] $Aliases = @{}
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

Describe 'user-scoped Agent Skills reconciliation' {
    BeforeEach {
        $userHome = Join-Path $TestDrive ('home-' + [Guid]::NewGuid().ToString('N'))
        $staging = Join-Path $TestDrive ('staging-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $userHome,$staging | Out-Null
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

    It 'fails closed on an unmanaged collision unless legacy migration is explicit' {
        $legacy = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy) | Out-Null
        [System.IO.File]::WriteAllText($legacy,'legacy')
        $desired = New-TestDesiredState -Root $staging
        $blocked = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply
        $blocked.outcome | Should Be 'failed'
        [System.IO.File]::ReadAllText($legacy) | Should Be 'legacy'
        $migrated = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -MigrateLegacyCatalogSkills
        $migrated.outcome | Should Be 'applied'
        [System.IO.File]::ReadAllText($legacy) | Should Match 'name: alpha'
        Test-Path -LiteralPath $migrated.backupPath | Should Be $true
    }

    It 'backs up and removes a legacy alias while installing its replacement' {
        $legacy = Join-Path $userHome '.agents\skills\old-alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $legacy) | Out-Null
        [System.IO.File]::WriteAllText($legacy,'legacy alias')
        $desired = New-TestDesiredState -Root $staging -Aliases @{ alpha=@('old-alpha') }
        $result = Invoke-UserSkillsReconciliation -DesiredState $desired -UserHome $userHome -Mode Apply -MigrateLegacyCatalogSkills
        $result.outcome | Should Be 'applied'
        Test-Path -LiteralPath $legacy | Should Be $false
        Test-Path -LiteralPath (Join-Path $userHome '.agents\skills\alpha\SKILL.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $result.backupPath '.agents\skills\old-alpha\SKILL.md') | Should Be $true
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

    It 'rolls back when a mutation fails and leaves the prior manifest valid' {
        $initial = New-TestDesiredState -Root (Join-Path $staging 'initial') -SkillIds @('alpha')
        (Invoke-UserSkillsReconciliation -DesiredState $initial -UserHome $userHome -Mode Apply).outcome | Should Be 'applied'
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $before = [System.IO.File]::ReadAllText($target)
        $next = New-TestDesiredState -Root (Join-Path $staging 'next') -SkillIds @('alpha','beta')
        { Invoke-UserSkillsReconciliation -DesiredState $next -UserHome $userHome -Mode Apply -FailureAfterMutationCount 1 } | Should Throw
        [System.IO.File]::ReadAllText($target) | Should Be $before
        Test-Path -LiteralPath (Join-Path $userHome '.agents\update-agent-environment.recovery.json') | Should Be $false
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
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup))))
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

    It 'rejects a tampered recovery backup without replacing the applied target or deleting the journal' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-tampered\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'applied')
        [System.IO.File]::WriteAllText($backup,'original')
        $appliedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText($backup,'tampered')
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup))))
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
                originalSha256=$originalSha; appliedSha256=$appliedSha
            })
        }
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        { Invoke-UserSkillsRecovery -UserHome $userHome } | Should Throw
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
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup))))
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
                originalSha256='not-a-sha256'; appliedSha256=$appliedSha
            })
        }
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        { Invoke-UserSkillsRecovery -UserHome $userHome } | Should Throw
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
            $journal = [pscustomobject][ordered]@{
                schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/')); backupPath=$backupRoot
                states=@([pscustomobject][ordered]@{
                    relativePath='.agents/skills/alpha/SKILL.md'; existed=$invalidBoolean; backupPath=$backup
                    originalSha256=$originalSha; appliedSha256=$appliedSha
                })
            }
            $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

            { Invoke-UserSkillsRecovery -UserHome $userHome } | Should Throw
            [System.IO.File]::ReadAllText($target) | Should Be 'applied'
            Test-Path -LiteralPath $journalPath | Should Be $true
        }
    }

    It 'rejects an empty recovery state array and preserves the journal' {
        $backupRoot = Join-Path $userHome '.agents\backups\recovery-empty'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1
            userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=$backupRoot
            states=[object[]]@()
        }
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8

        { Invoke-UserSkillsRecovery -UserHome $userHome } | Should Throw
        Test-Path -LiteralPath $journalPath | Should Be $true
    }

    It 'preserves a concurrent edit instead of overwriting it during recovery' {
        $target = Join-Path $userHome '.agents\skills\alpha\SKILL.md'
        $backup = Join-Path $userHome '.agents\backups\recovery-drift\.agents\skills\alpha\SKILL.md'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target),(Split-Path -Parent $backup) | Out-Null
        [System.IO.File]::WriteAllText($target,'concurrent')
        [System.IO.File]::WriteAllText($backup,'original')
        $originalSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash.ToLowerInvariant()
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/'))
            backupPath=(Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $backup))))
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$backup
                originalSha256=$originalSha; appliedSha256=('2' * 64)
            })
        }
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        { Invoke-UserSkillsRecovery -UserHome $userHome } | Should Throw
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
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome=[System.IO.Path]::GetFullPath($userHome).TrimEnd([char[]]@('\','/')); backupPath=$userHome
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$true; backupPath=$outsideBackup
                originalSha256=$originalSha; appliedSha256=$appliedSha
            })
        }
        $journalPath = Join-Path $userHome '.agents\update-agent-environment.recovery.json'
        $journal | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPath -Encoding UTF8
        { Invoke-UserSkillsRecovery -UserHome $userHome } | Should Throw
        [System.IO.File]::ReadAllText($target) | Should Be 'applied'
        Test-Path -LiteralPath $journalPath | Should Be $true
    }
}

Describe 'user Skills managed manifest contract' {
    BeforeEach { Import-Module $script:ContractPath -Force }

    It 'accepts the checked-in example' {
        $example = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v1.example.json') | ConvertFrom-Json
        { Assert-UserSkillsManagedManifestV1 -Manifest $example } | Should Not Throw
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
}
