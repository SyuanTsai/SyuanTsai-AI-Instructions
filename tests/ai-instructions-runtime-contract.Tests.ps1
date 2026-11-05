$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:RuntimeContractModule = Join-Path $script:RepositoryRoot 'scripts\ai-instructions-runtime-contract.psm1'
$script:CanonicalRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'

function New-TestConfigurationDocument {
    param([Parameter(Mandatory = $true)][int] $SchemaVersion)

    switch ($SchemaVersion) {
        1 {
            return [pscustomobject]@{
                schemaVersion = 1
                autoCommitRepositoryUrls = @('https://example.com/team/obsolete.git')
                excludedRepositoryUrls = @('https://example.org/team/excluded.git')
                excludedRepositoryPaths = @('docs/planning')
            }
        }
        2 {
            return [pscustomobject]@{
                schemaVersion = 2
                autoCommitRepositoryUrls = @('ssh://git@example.com/team/obsolete.git')
                excludedRepositoryUrls = @('ssh://git@example.org/team/excluded.git')
                excludedRepositoryPaths = @('design/review')
            }
        }
        3 {
            return [pscustomobject]@{
                schemaVersion = 3
                autoCommitRepositoryUrls = @('git@example.com:team/obsolete.git')
                excludedRepositoryUrls = @('git@example.org:team/excluded.git')
                excludedRepositoryPaths = @('architecture/drafts')
                catalog = [pscustomobject]@{
                    repository = $script:CanonicalRepository
                    ref = ('a' * 40)
                    profiles = @('observability')
                    includeSkills = @('work-with-jira')
                    excludeSkills = @('search-with-felo')
                }
            }
        }
        4 {
            return [pscustomobject]@{
                schemaVersion = 4
                excludedRepositoryUrls = @('https://example.org/team/excluded.git')
                excludedRepositoryPaths = @('docs/planning')
                catalog = [pscustomobject]@{
                    repository = $script:CanonicalRepository
                    ref = ('b' * 40)
                    profiles = @('core')
                    includeSkills = @('work-with-jira')
                    excludeSkills = @()
                }
                updates = [pscustomobject]@{
                    mode = 'auto-install-approved'
                    channel = 'github-release'
                    ref = 'latest'
                    minimumCheckIntervalMinutes = 60
                }
            }
        }
        5 {
            $configuration = New-TestConfigurationDocument -SchemaVersion 4
            $configuration.schemaVersion = 5
            $configuration | Add-Member -NotePropertyName projections -NotePropertyValue ([pscustomobject]@{
                user = @('user-agents','user-claude')
                project = @('project-agents')
            })
            return $configuration
        }
    }
}

function Get-RuntimeContractError {
    param([Parameter(Mandatory = $true)][scriptblock] $Action)
    try { & $Action; return $null }
    catch { return $_.Exception.Message }
}

function Copy-TestCanonicalRuntimeText {
    param([Parameter(Mandatory = $true)][string] $Source,[Parameter(Mandatory = $true)][string] $Destination)
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    $bytes = [IO.File]::ReadAllBytes($Source)
    [IO.File]::WriteAllBytes($Destination,$utf8.GetBytes($utf8.GetString($bytes).Replace("`r`n","`n")))
}

function Get-TestCanonicalTextSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $canonicalBytes = $utf8.GetBytes($utf8.GetString($bytes).Replace("`r`n","`n"))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($canonicalBytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-TestOrdinalRuntimeInventorySha256 {
    param([Parameter(Mandatory = $true)][object[]] $Inventory)
    $hashByPath = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $paths = [string[]]@($Inventory | ForEach-Object {
        $hashByPath.Add([string]$_.path,[string]$_.sha256)
        [string]$_.path
    })
    [Array]::Sort($paths,[StringComparer]::Ordinal)
    $payload = (($paths | ForEach-Object { "$_`t$($hashByPath[$_])`n" }) -join '')
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash(([Text.UTF8Encoding]::new($false)).GetBytes($payload)))).Replace('-','').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Set-TestTextOccurrence {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $OldValue,
        [Parameter(Mandatory = $true)][string] $NewValue
    )
    $text = [IO.File]::ReadAllText($Path)
    $index = $text.IndexOf($OldValue,[StringComparison]::Ordinal)
    if ($index -lt 0) { throw "Test fixture text was not found: $OldValue" }
    $updated = $text.Substring(0,$index) + $NewValue + $text.Substring($index + $OldValue.Length)
    [IO.File]::WriteAllText($Path,$updated,[Text.UTF8Encoding]::new($false))
}

function New-TestRuntimeV3Fixture {
    param([Parameter(Mandatory = $true)][string] $Path)
    New-Item -ItemType Directory -Force -Path $Path,(Join-Path $Path 'catalog') | Out-Null
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepositoryRoot 'scripts\platform-runtime.psd1')
    foreach ($relativePath in @($manifest.FileList)) {
        $destination = Join-Path $Path $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-TestCanonicalRuntimeText -Source (Join-Path $script:RepositoryRoot "scripts\$relativePath") -Destination $destination
    }
    Copy-TestCanonicalRuntimeText `
        -Source (Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog-v3.example.json') `
        -Destination (Join-Path $Path 'catalog\skills-catalog.json')
    $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\runtime-bundle-v3.example.json') | ConvertFrom-Json
    $fixture = [pscustomobject]@{ Root=$Path; Bundle=$bundle }
    Update-TestRuntimeV3Inventory -Fixture $fixture
    $bundle.platformRuntime.manifestSha256 = Get-TestCanonicalTextSha256 -Path (Join-Path $Path 'platform-runtime.psd1')
    return $fixture
}

function Update-TestRuntimeV3Inventory {
    param([Parameter(Mandatory = $true)][object] $Fixture)
    $Fixture.Bundle.inventory = @(Get-AiInstructionsRuntimeInventory -RuntimeRoot $Fixture.Root)
    $Fixture.Bundle.inventorySha256 = Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $Fixture.Bundle.inventory
}

function Update-TestRuntimeV3ProjectionContract {
    param([Parameter(Mandatory = $true)][object] $Fixture)
    $catalogPath = Join-Path $Fixture.Root 'catalog\skills-catalog.json'
    $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
    $catalogModule = Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-catalog-contract.psm1') -PassThru -Scope Local
    $Fixture.Bundle.projectionContractSha256 = & $catalogModule.ExportedCommands['Get-SkillsCatalogProjectionContractSha256'] -Projections $catalog.projections
}

function Invoke-TestRuntimeV3OrdinalChild {
    param(
        [Parameter(Mandatory = $true)][string] $Executable,
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [Parameter(Mandatory = $true)][string] $ModulePath,
        [Parameter(Mandatory = $true)][string] $InventoryPath
    )

    $outputPath = Join-Path $TestDrive ('runtime-v3-ordinal-stdout-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $errorPath = Join-Path $TestDrive ('runtime-v3-ordinal-stderr-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $process = Start-Process -FilePath $Executable `
        -ArgumentList @('-NoProfile','-NonInteractive','-File',$ScriptPath,$ModulePath,$InventoryPath) `
        -PassThru -Wait -NoNewWindow -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = [IO.File]::ReadAllText($outputPath)
        StdErr = [IO.File]::ReadAllText($errorPath)
    }
}

function Get-TestInstallJournalV1 {
    $path = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json'
    $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json (Get-Content -Raw -Encoding UTF8 -LiteralPath $path)
    $journal.operations = @($journal.operations | Select-Object -First 2)
    return $journal
}

function Get-TestLinuxInstallJournalV1 {
    $journal = Get-TestInstallJournalV1
    $journal.platform.os = 'linux'
    $journal.lock.primitive = 'flock'
    foreach ($operation in $journal.operations) {
        foreach ($state in @($operation.original,$operation.applied)) {
            if ($null -ne $state.identity) { $state.identity.kind = 'unix-device-inode' }
        }
        if ($null -ne $operation.backupIdentity) { $operation.backupIdentity.kind = 'unix-device-inode' }
    }
    $journal.operations[0].permissions = [pscustomobject]@{ kind='unix-mode'; mode='0644'; uid=1000; gid=1000 }
    return (ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20))
}

function New-TestInstallObservation {
    param(
        [Parameter(Mandatory = $true)][object] $Operation,
        [Parameter(Mandatory = $true)][object] $State,
        [AllowNull()][object] $Backup,
        [object] $Permissions = $Operation.permissions
    )
    if ([bool]$State.exists -and $null -eq $Permissions) {
        $Permissions = if ([string]$State.identity.kind -ceq 'windows-file-id') {
            [pscustomobject]@{ kind='windows-sddl'; sddl='D:PAI(A;;FA;;;SY)'; readOnly=$false }
        }
        else { [pscustomobject]@{ kind='unix-mode'; mode='0644'; uid=1000; gid=1000 } }
    }
    $observedPermissions = if ($null -eq $Permissions) { $null }
        elseif ([string]$Permissions.kind -ceq 'windows-sddl') { [pscustomobject]@{ kind=$Permissions.kind; sddl=$Permissions.sddl; readOnly=$Permissions.readOnly } }
        else { [pscustomobject]@{ kind=$Permissions.kind; mode=$Permissions.mode; uid=$Permissions.uid; gid=$Permissions.gid } }
    if (-not $PSBoundParameters.ContainsKey('Backup')) {
        $Backup = if ([bool]$Operation.original.exists) {
            [pscustomobject]@{
                exists = $true
                sha256 = $Operation.original.sha256
                length = $Operation.original.length
                identity = $Operation.backupIdentity
            }
        }
        else { $null }
    }
    $copyIdentity = {
        param([AllowNull()][object] $Identity)
        if ($null -eq $Identity) { $null }
        else {
            [pscustomobject]@{
                kind = $Identity.kind
                device = $Identity.device
                fileId = $Identity.fileId
            }
        }
    }
    $observedIdentity = & $copyIdentity $State.identity
    $observedBackup = if ($null -eq $Backup) { $null }
        else {
            [pscustomobject]@{
                exists = $Backup.exists
                sha256 = $Backup.sha256
                length = $Backup.length
                identity = & $copyIdentity $Backup.identity
            }
        }
    return [pscustomobject]@{
        exists = [bool]$State.exists
        sha256 = $State.sha256
        length = $State.length
        identity = $observedIdentity
        permissions = if ([bool]$State.exists) { $observedPermissions } else { $null }
        backup = $observedBackup
    }
}

function Get-TestPendingRemoveInstallJournalV1 {
    $journal = Get-TestInstallJournalV1
    $journal.operations = @($journal.operations[0])
    $journal.operations[0].kind = 'remove-file'
    $journal.operations[0].method = 'tombstone-rename'
    $journal.operations[0].stageLeaf = $null
    $journal.operations[0].backupIdentity = $journal.operations[0].original.identity
    $journal.operations[0].applied.exists = $false
    $journal.operations[0].applied.sha256 = $null
    $journal.operations[0].applied.length = $null
    $journal.operations[0].applied.identity = $null
    $journal.operations[0].state = 'pending'
    return (ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20))
}

Describe 'AI instructions runtime contracts' {
    BeforeAll {
        Import-Module $script:RuntimeContractModule -Force
    }

    # Scenario: The stable updater snapshots the runtime contract without its v3-only Catalog validator.
    # Purpose: Keep module loading plus v2 bundle and v4 sync validation independent from the Catalog contract.
    It 'UnitT02_imports_an_isolated_runtime_contract_for_v2_and_v4_validation' {
        $isolatedRoot = Join-Path $TestDrive 'isolated-runtime-contract'
        $runtimeRoot = Join-Path $isolatedRoot 'runtime'
        New-Item -ItemType Directory -Force -Path $isolatedRoot,$runtimeRoot | Out-Null
        $isolatedModulePath = Join-Path $isolatedRoot 'ai-instructions-runtime-contract.psm1'
        Copy-Item -LiteralPath $script:RuntimeContractModule -Destination $isolatedModulePath
        [IO.File]::WriteAllText((Join-Path $runtimeRoot 'bootstrap.ps1'),"Write-Output 'ok'`n")

        $isolatedModule = Import-Module $isolatedModulePath -PassThru -Scope Local -Force
        try {
            $configuration = & $isolatedModule.ExportedCommands['ConvertTo-AiInstructionsSyncConfigurationV4'] `
                -CatalogRepository $script:CanonicalRepository `
                -CatalogRef ('2' * 40)
            $bundle = & $isolatedModule.ExportedCommands['New-AiInstructionsRuntimeBundleV2'] `
                -RuntimeRoot $runtimeRoot `
                -Repository $script:CanonicalRepository `
                -Commit ('2' * 40) `
                -Acquisition git-checkout

            { & $isolatedModule.ExportedCommands['Assert-AiInstructionsSyncConfigurationV4'] -Configuration $configuration } | Should Not Throw
            { & $isolatedModule.ExportedCommands['Assert-AiInstructionsRuntimeBundleV2'] -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot } | Should Not Throw
        }
        finally { Remove-Module -ModuleInfo $isolatedModule -Force }
    }

    # Scenario: A supported personal configuration is installed by the current runtime.
    # Purpose: Preserve exclusions and selections while removing obsolete auto-commit authority.
    It 'UnitT10_migrates_schema_v<schemaVersion>_to_v4_without_auto_commit' -TestCases @(
        @{ schemaVersion = 1 },
        @{ schemaVersion = 2 },
        @{ schemaVersion = 3 },
        @{ schemaVersion = 4 }
    ) {
            param($schemaVersion)
            $existing = New-TestConfigurationDocument -SchemaVersion $schemaVersion

            $migrated = ConvertTo-AiInstructionsSyncConfigurationV4 `
                -ExistingConfiguration $existing `
                -CatalogRepository $script:CanonicalRepository `
                -CatalogRef ('c' * 40)

            $migrated.schemaVersion | Should Be 4
            ($migrated.PSObject.Properties.Name -contains 'autoCommitRepositoryUrls') | Should Be $false
            @($migrated.excludedRepositoryUrls).Count | Should Be 1
            @($migrated.excludedRepositoryPaths).Count | Should Be 1
            [string]$migrated.catalog.ref | Should Be ('c' * 40)
            if ($schemaVersion -ge 3) {
                @($migrated.catalog.includeSkills) | Should Be @('work-with-jira')
            }
            if ($schemaVersion -eq 4) {
                $migrated.updates.mode | Should Be 'auto-install-approved'
                $migrated.updates.channel | Should Be 'github-release'
                $migrated.updates.ref | Should Be 'latest'
                $migrated.updates.minimumCheckIntervalMinutes | Should Be 60
            }
            else {
                $migrated.updates.mode | Should Be 'notify-only'
                $migrated.updates.channel | Should Be 'protected-branch'
                $migrated.updates.ref | Should Be 'main'
                $migrated.updates.minimumCheckIntervalMinutes | Should Be 1440
            }
    }

    # Scenario: A previously valid v4 configuration used an equivalent canonical HTTPS URL without the .git suffix.
    # Purpose: Keep v4-to-v4 installation idempotent while writing the one strict canonical representation.
    It 'UnitT12_normalizes_a_legacy_v4_canonical_repository_alias' {
        $existing = New-TestConfigurationDocument -SchemaVersion 4
        $existing.catalog.repository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions'

        $migrated = ConvertTo-AiInstructionsSyncConfigurationV4 `
            -ExistingConfiguration $existing `
            -CatalogRepository $script:CanonicalRepository `
            -CatalogRef ('4' * 40)

        $migrated.catalog.repository | Should Be $script:CanonicalRepository
        { Assert-AiInstructionsSyncConfigurationV4 -Configuration $migrated } | Should Not Throw
    }

    # Scenario: A legacy v4 configuration repeats a Skill already selected by one of its active profiles.
    # Purpose: Remove the redundant hard-selection marker during installation while preserving unrelated explicit includes.
    It 'UnitT15_normalizes_profile_and_includeSkills_overlap_with_the_Catalog' {
        $existing = New-TestConfigurationDocument -SchemaVersion 4
        $existing.catalog.profiles = @('atlassian')
        $existing.catalog.includeSkills = @('work-with-jira','plan-production-change')
        $catalog = [pscustomobject]@{
            profiles = @(
                [pscustomobject]@{ id='atlassian'; default=$false; includes=@('work-with-jira'); excludes=@() }
            )
            skills = @(
                [pscustomobject]@{ id='work-with-jira'; lifecycle=[pscustomobject]@{ status='active'; aliases=@() } },
                [pscustomobject]@{ id='plan-production-change'; lifecycle=[pscustomobject]@{ status='active'; aliases=@() } }
            )
        }

        $migrated = ConvertTo-AiInstructionsSyncConfigurationV4 `
            -ExistingConfiguration $existing `
            -CatalogRepository $script:CanonicalRepository `
            -CatalogRef ('5' * 40) `
            -Catalog $catalog

        @($migrated.catalog.profiles) | Should Be @('atlassian')
        @($migrated.catalog.includeSkills) | Should Be @('plan-production-change')
    }

    # Scenario: A staged runtime is represented by bundle schema v2 and an exact file inventory.
    # Purpose: Make launcher validation cover every runtime byte rather than repository identity alone.
    It 'UnitT50_validates_runtime_bundle_v2_identity_and_complete_inventory' {
        $runtimeRoot = Join-Path $TestDrive 'runtime'
        New-Item -ItemType Directory -Force -Path (Join-Path $runtimeRoot 'catalog') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'launcher.ps1'), "Write-Output 'ok'`n")
        [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'catalog\skills-catalog.json'), "{}`n")
        $configuration = ConvertTo-AiInstructionsSyncConfigurationV4 `
            -CatalogRepository $script:CanonicalRepository `
            -CatalogRef ('d' * 40)
        $bundle = New-AiInstructionsRuntimeBundleV2 `
            -RuntimeRoot $runtimeRoot `
            -Repository $script:CanonicalRepository `
            -Commit ('d' * 40) `
            -Acquisition git-checkout

        { Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot } |
            Should Not Throw
        $bundle.schemaVersion | Should Be 2
        $bundle.inventorySha256 | Should Match '^[0-9a-f]{64}$'
        @($bundle.inventory).Count | Should Be 2
    }

    # Scenario: The checked-in configuration and runtime-bundle examples are used as executable parser inputs.
    # Purpose: Keep documented example hashes aligned with the exact runtime fixture they describe.
    It 'UnitT55_validates_checked_in_configuration_and_runtime_bundle_examples' {
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath `
            (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v4.example.json') | ConvertFrom-Json
        $bundle = Get-Content -Raw -Encoding UTF8 -LiteralPath `
            (Join-Path $script:RepositoryRoot 'catalog\examples\runtime-bundle-v2.example.json') | ConvertFrom-Json
        $runtimeRoot = Join-Path $TestDrive 'runtime-example'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText(
            (Join-Path $runtimeRoot 'bootstrap-ai-instructions.ps1'),
            "Write-Output 'example'`n",
            $utf8NoBom)

        { Assert-AiInstructionsSyncConfigurationV4 -Configuration $configuration } | Should Not Throw
        { Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot } |
            Should Not Throw
    }

    # Scenario: An installed runtime file is changed after installation.
    # Purpose: Fail closed before launching a bundle whose executable inventory drifted.
    It 'UnitT60_rejects_runtime_file_hash_drift' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-drift'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        $runtimeFile = Join-Path $runtimeRoot 'bootstrap.ps1'
        [System.IO.File]::WriteAllText($runtimeFile, "Write-Output 'v1'`n")
        $configuration = ConvertTo-AiInstructionsSyncConfigurationV4 -CatalogRepository $script:CanonicalRepository -CatalogRef ('e' * 40)
        $bundle = New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository $script:CanonicalRepository -Commit ('e' * 40) -Acquisition git-checkout
        [System.IO.File]::WriteAllText($runtimeFile, "Write-Output 'tampered'`n")

        $errorMessage = Get-RuntimeContractError {
            Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot
        }
        $errorMessage | Should Match 'inventory'
    }

    # Scenario: An unlisted file appears inside the active runtime directory.
    # Purpose: Reject incomplete inventories that could hide executable runtime content.
    It 'UnitT70_rejects_an_unlisted_runtime_file' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-extra'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'bootstrap.ps1'), "Write-Output 'ok'`n")
        $configuration = ConvertTo-AiInstructionsSyncConfigurationV4 -CatalogRepository $script:CanonicalRepository -CatalogRef ('f' * 40)
        $bundle = New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository $script:CanonicalRepository -Commit ('f' * 40) -Acquisition git-checkout
        [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'unexpected.ps1'), "Write-Output 'unexpected'`n")

        $errorMessage = Get-RuntimeContractError {
            Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot
        }
        $errorMessage | Should Match 'inventory'
    }

    # Scenario: A codeload-acquired bundle omits its immutable archive digest.
    # Purpose: Keep the downloaded source archive auditable and fail closed on incomplete provenance.
    It 'UnitT80_requires_archive_sha_for_github_codeload_bundles' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-codeload'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'bootstrap.ps1'), "Write-Output 'ok'`n")

        $errorMessage = Get-RuntimeContractError {
            New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository $script:CanonicalRepository -Commit ('1' * 40) -Acquisition github-codeload
        }
        $errorMessage | Should Match 'archiveSha256'
    }

    # Scenario: The persisted receipt schema, example, and executable parser define one outcome vocabulary.
    # Purpose: Keep the non-persisted rate-limit workflow response out of the receipt contract.
    It 'UnitT85_keeps_persisted_update_receipt_outcomes_in_schema_parser_sync' {
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-update-receipt-v1.schema.json'
        $examplePath = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-update-receipt-v1.example.json'
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $schemaPath | ConvertFrom-Json
        $example = Get-Content -Raw -Encoding UTF8 -LiteralPath $examplePath | ConvertFrom-Json
        $persistedOutcomes = @('current','available','installed','offline','stale','drift','failed')

        (@($schema.properties.outcome.enum) -join "`n") | Should Be ($persistedOutcomes -join "`n")
        { Assert-AiInstructionsUpdateReceiptV1 -Receipt $example } | Should Not Throw
        $example.outcome = 'rate-limit'
        (Get-RuntimeContractError { Assert-AiInstructionsUpdateReceiptV1 -Receipt $example }) |
            Should Match 'Unsupported.*rate-limit'
    }

    # Scenario: Standard JSON Schema tooling validates receipt channel/ref and outcome-dependent commit/hash requirements.
    # Purpose: Keep the portable schema from accepting combinations that the executable receipt parser rejects.
    It 'UnitT87_encodes_update_receipt_cross_field_requirements_in_the_JSON_schema' {
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-update-receipt-v1.schema.json'
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $schemaPath | ConvertFrom-Json
        $rules = @($schema.allOf)

        $protectedBranchRule = @($rules | Where-Object { [string]$_.if.properties.channel.const -ceq 'protected-branch' })
        $githubReleaseRule = @($rules | Where-Object { [string]$_.if.properties.channel.const -ceq 'github-release' })
        $currentRule = @($rules | Where-Object { [string]$_.if.properties.outcome.const -ceq 'current' })
        $candidateRule = @($rules | Where-Object { (@($_.if.properties.outcome.enum) -join ',') -ceq 'available,installed,stale,drift' })
        $archiveRule = @($rules | Where-Object { (@($_.if.properties.outcome.enum) -join ',') -ceq 'installed,drift' })

        $protectedBranchRule.Count | Should Be 1
        [string]$protectedBranchRule[0].then.properties.ref.const | Should Be 'main'
        $githubReleaseRule.Count | Should Be 1
        [string]$githubReleaseRule[0].then.properties.ref.const | Should Be 'latest'
        $currentRule.Count | Should Be 1
        [string]$currentRule[0].then.properties.candidateCommit.type | Should Be 'null'
        $candidateRule.Count | Should Be 1
        [string]$candidateRule[0].then.properties.candidateCommit.'$ref' | Should Be '#/$defs/commit'
        $archiveRule.Count | Should Be 1
        [string]$archiveRule[0].then.properties.archiveSha256.'$ref' | Should Be '#/$defs/hash'

        $currentReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-update-receipt-v1.example.json') | ConvertFrom-Json
        $currentReceipt.outcome = 'current'
        $currentReceipt.candidateCommit = $null
        $currentReceipt.message = 'The installed runtime is current.'
        { Assert-AiInstructionsUpdateReceiptV1 -Receipt $currentReceipt } | Should Not Throw
        $currentReceipt.candidateCommit = $currentReceipt.currentCommit
        (Get-RuntimeContractError { Assert-AiInstructionsUpdateReceiptV1 -Receipt $currentReceipt }) | Should Match 'current.*candidateCommit'
    }

    # Scenario: Portable configuration and runtime-bundle schemas describe the single canonical source accepted by runtime validation.
    # Purpose: Prevent schema-only consumers from approving a repository that executable validation must reject.
    It 'UnitT88_keeps_canonical_repository_identity_in_schema_and_runtime_parser_sync' {
        $configurationSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-sync-v4.schema.json') | ConvertFrom-Json
        $configurationSchemaV5 = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-sync-v5.schema.json') | ConvertFrom-Json
        $bundleSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\schemas\runtime-bundle-v2.schema.json') | ConvertFrom-Json
        $bundleSchemaV3 = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\schemas\runtime-bundle-v3.schema.json') | ConvertFrom-Json

        [string]$configurationSchema.properties.catalog.properties.repository.const | Should Be $script:CanonicalRepository
        [string]$configurationSchemaV5.properties.catalog.properties.repository.const | Should Be $script:CanonicalRepository
        [string]$bundleSchema.properties.repository.const | Should Be $script:CanonicalRepository
        [string]$bundleSchemaV3.properties.repository.const | Should Be $script:CanonicalRepository

        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $configuration.catalog.repository = 'https://github.com/example/other-ai-instructions.git'
        (Get-RuntimeContractError { Assert-AiInstructionsSyncConfigurationV4 -Configuration $configuration }) |
            Should Match 'canonical repository'
    }

    # Scenario: A schema-v4 configuration carries JSON values whose types do not match the portable schema.
    # Purpose: Reject malformed current configuration instead of coercing it during an idempotent v4 migration.
    It 'UnitT89_rejects_schema_invalid_v4_configuration_types' {
        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $configuration.updates.minimumCheckIntervalMinutes = '60'

        (Get-RuntimeContractError {
            ConvertTo-AiInstructionsSyncConfigurationV4 `
                -ExistingConfiguration $configuration `
                -CatalogRepository $script:CanonicalRepository `
                -CatalogRef ('c' * 40)
        }) | Should Match 'minimumCheckIntervalMinutes must be an integer'

        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $configuration.excludedRepositoryPaths = 'docs/planning'
        (Get-RuntimeContractError { Assert-AiInstructionsSyncConfigurationV4 -Configuration $configuration }) |
            Should Match 'excludedRepositoryPaths must be an array'

        $configuration = New-TestConfigurationDocument -SchemaVersion 5
        $configuration.projections.user = 'user-agents'
        (Get-RuntimeContractError { Assert-AiInstructionsSyncConfigurationV5 -Configuration $configuration }) |
            Should Match 'projections.user must be an array'
    }

    # Scenario: A schema-v4 update interval exceeds the Int32 range used by idempotent configuration migration.
    # Purpose: Keep the portable schema and executable validator aligned so every accepted v4 document can be migrated.
    It 'UnitT90_rejects_update_intervals_that_cannot_survive_v4_migration' {
        $configurationSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-sync-v4.schema.json') | ConvertFrom-Json
        [long]$configurationSchema.properties.updates.properties.minimumCheckIntervalMinutes.maximum |
            Should Be ([long][int]::MaxValue)

        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $configuration.updates.minimumCheckIntervalMinutes = [long][int]::MaxValue + 1

        (Get-RuntimeContractError { Assert-AiInstructionsSyncConfigurationV4 -Configuration $configuration }) |
            Should Match 'at most 2147483647'
        (Get-RuntimeContractError {
            ConvertTo-AiInstructionsSyncConfigurationV4 `
                -ExistingConfiguration $configuration `
                -CatalogRepository $script:CanonicalRepository `
                -CatalogRef ('c' * 40)
        }) | Should Match 'at most 2147483647'
    }

    # Scenario: A persisted git-checkout runtime bundle uses an empty string where the schema permits only null or SHA-256.
    # Purpose: Keep executable bundle validation aligned with the portable nullability contract.
    It 'UnitT91_rejects_schema_invalid_runtime_bundle_nullability' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-empty-archive-hash'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'bootstrap.ps1'), "Write-Output 'ok'`n")
        $configuration = ConvertTo-AiInstructionsSyncConfigurationV4 -CatalogRepository $script:CanonicalRepository -CatalogRef ('9' * 40)
        $bundle = New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository $script:CanonicalRepository -Commit ('9' * 40) -Acquisition git-checkout
        $bundle.archiveSha256 = ''

        (Get-RuntimeContractError {
            Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot
        }) | Should Match 'archiveSha256 is invalid'

        $runtimeV3Root = Join-Path $TestDrive 'runtime-v3-empty-archive-hash'
        New-Item -ItemType Directory -Force -Path $runtimeV3Root | Out-Null
        $configurationV5 = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v5.example.json') | ConvertFrom-Json
        $bundleV3 = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\runtime-bundle-v3.example.json') | ConvertFrom-Json
        $bundleV3.archiveSha256 = ''
        (Get-RuntimeContractError {
            Assert-AiInstructionsRuntimeBundleV3 -Bundle $bundleV3 -Configuration $configurationV5 -RuntimeRoot $runtimeV3Root
        }) | Should Match 'archiveSha256 is required'
    }

    # Scenario: A receipt uses a date-only value that JSON Schema date-time consumers reject.
    # Purpose: Enforce the same RFC 3339 date-time shape in the executable parser.
    It 'UnitT92_rejects_non_date_time_receipt_values' {
        $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-update-receipt-v1.example.json') | ConvertFrom-Json
        $receipt.checkedAtUtc = '2026-08-23'

        (Get-RuntimeContractError { Assert-AiInstructionsUpdateReceiptV1 -Receipt $receipt }) |
            Should Match 'ISO 8601 date-time'

        $receipt.checkedAtUtc = '2026-08-23t00:00:00z'
        { Assert-AiInstructionsUpdateReceiptV1 -Receipt $receipt } | Should Not Throw

        $utcValue = [datetime]::SpecifyKind([datetime]'2026-08-23T04:00:00', [DateTimeKind]::Utc)
        (ConvertTo-AiInstructionsUtcDateTime -Value $utcValue -Context 'test timestamp').ToString('o') |
            Should Be '2026-08-23T04:00:00.0000000Z'
        $unspecifiedValue = [datetime]::SpecifyKind([datetime]'2026-08-23T04:00:00', [DateTimeKind]::Unspecified)
        (Get-RuntimeContractError { ConvertTo-AiInstructionsUtcDateTime -Value $unspecifiedValue -Context 'test timestamp' }) |
            Should Match 'explicit UTC or numeric offset'
        (ConvertTo-AiInstructionsUtcDateTime -Value '2026-08-23T12:00:00+08:00' -Context 'test timestamp').ToString('o') |
            Should Be '2026-08-23T04:00:00.0000000Z'
    }

    # Scenario: JSON documents use a one-element array where the portable schemas require a scalar string.
    # Purpose: Prevent PowerShell string coercion from accepting documents rejected by JSON Schema consumers.
    It 'UnitT93_rejects_singleton_arrays_in_scalar_string_fields' {
        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $configuration.catalog.repository = @($script:CanonicalRepository)
        (Get-RuntimeContractError { Assert-AiInstructionsSyncConfigurationV4 -Configuration $configuration }) |
            Should Match 'catalog.repository must be a string'

        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $configuration.excludedRepositoryPaths = @([int]7)
        (Get-RuntimeContractError { Assert-AiInstructionsSyncConfigurationV4 -Configuration $configuration }) |
            Should Match 'excludedRepositoryPaths must contain only non-empty strings'

        $runtimeRoot = Join-Path $TestDrive 'runtime-singleton-array'
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'bootstrap.ps1'), "Write-Output 'ok'`n")
        $configuration = ConvertTo-AiInstructionsSyncConfigurationV4 -CatalogRepository $script:CanonicalRepository -CatalogRef ('8' * 40)
        $bundle = New-AiInstructionsRuntimeBundleV2 -RuntimeRoot $runtimeRoot -Repository $script:CanonicalRepository -Commit ('8' * 40) -Acquisition git-checkout
        $bundle.commit = @(('8' * 40))
        (Get-RuntimeContractError {
            Assert-AiInstructionsRuntimeBundleV2 -Bundle $bundle -Configuration $configuration -RuntimeRoot $runtimeRoot
        }) | Should Match 'commit must be a string'

        $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-update-receipt-v1.example.json') | ConvertFrom-Json
        $receipt.outcome = @('current')
        (Get-RuntimeContractError { Assert-AiInstructionsUpdateReceiptV1 -Receipt $receipt }) |
            Should Match 'outcome must be a string'
    }

    # Scenario: A caller supplies a filesystem root as a normalized directory path or as Codex Home.
    # Purpose: Preserve repository roots correctly while preventing installer/updater writes directly under a volume root.
    It 'UnitT94_preserves_filesystem_roots_and_can_reject_them_for_Codex_Home' {
        $fileSystemRoot = [System.IO.Path]::GetPathRoot($TestDrive)

        (Get-AiInstructionsFullDirectoryPath -Path $fileSystemRoot) | Should Be $fileSystemRoot
        (Get-RuntimeContractError {
            Get-AiInstructionsFullDirectoryPath -Path $fileSystemRoot -RejectFileSystemRoot -Context 'Codex Home'
        }) | Should Match 'Codex Home.*filesystem root'
    }

    # Scenario: Recursive cleanup is asked to remove a nested or reparse-backed path instead of its exact transaction root.
    # Purpose: Constrain destructive cleanup to one immediate, non-reparse child with the expected generated prefix.
    It 'UnitT95_accepts_only_safe_immediate_transaction_cleanup_directories' {
        $parent = Join-Path $TestDrive 'cleanup-parent'
        $safeRoot = Join-Path $parent '.ai-instructions-update-safe'
        $nestedRoot = Join-Path $safeRoot 'nested'
        New-Item -ItemType Directory -Force -Path $nestedRoot | Out-Null

        (Assert-AiInstructionsSafeChildDirectory -Parent $parent -Path $safeRoot -LeafPrefix '.ai-instructions-update-') |
            Should Be ([System.IO.Path]::GetFullPath($safeRoot))
        (Get-RuntimeContractError {
            Assert-AiInstructionsSafeChildDirectory -Parent $parent -Path $nestedRoot -LeafPrefix '.ai-instructions-update-'
        }) | Should Match 'immediate child'
    }

    # Scenario: Stable updater/runtime paths are replaced with the wrong filesystem type or a junction.
    # Purpose: Keep later reads, writes, and inventory traversal inside the installed Codex Home boundary.
    It 'UnitT96_rejects_unsafe_stable_mutation_and_runtime_paths' {
        $parent = Join-Path $TestDrive 'stable-paths'
        $outside = Join-Path $TestDrive 'outside-runtime'
        $junction = Join-Path $parent 'runtime-junction'
        $wrongFilePath = Join-Path $parent 'receipt.json'
        New-Item -ItemType Directory -Force -Path $parent,$outside,$wrongFilePath | Out-Null
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        }
        else {
            New-Item -ItemType SymbolicLink -Path $junction -Target $outside | Out-Null
        }

        (Get-RuntimeContractError {
            Assert-AiInstructionsMutationPath -Path $wrongFilePath -ExpectedType File -Context 'receipt'
        }) | Should Match 'non-reparse file'
        (Get-RuntimeContractError {
            Get-AiInstructionsRuntimeInventory -RuntimeRoot $junction
        }) | Should Match "^AI instructions runtime root '.+' must be a non-reparse directory\.$"
    }

    # Scenario: The reader receives the checked-in v5 sync configuration and migrates every legacy version safely.
    # Purpose: Add projection-aware reading without changing the v4 writer path.
    It 'UnitT97_validates_v5_and_migrates_v1_through_v4_with_default_projections' {
        $example = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v5.example.json') | ConvertFrom-Json
        { Assert-AiInstructionsSyncConfigurationV5 -Configuration $example } | Should Not Throw
        @($example.projections.user) | Should Be @('user-agents','user-claude')
        @($example.projections.project).Count | Should Be 0
        foreach ($version in 1..4) {
            $migrated = ConvertTo-AiInstructionsSyncConfigurationV5 -ExistingConfiguration (New-TestConfigurationDocument -SchemaVersion $version) -CatalogRepository $script:CanonicalRepository -CatalogRef ('c' * 40)
            $migrated.schemaVersion | Should Be 5
            @($migrated.projections.user) | Should Be @('user-agents','user-claude')
            @($migrated.projections.project).Count | Should Be 0
            [string]$migrated.catalog.ref | Should Be ('c' * 40)
        }
        $same = ConvertTo-AiInstructionsSyncConfigurationV5 -ExistingConfiguration $example -CatalogRepository $script:CanonicalRepository -CatalogRef ('d' * 40)
        [object]::ReferenceEquals($same,$example) | Should Be $true
        (Get-RuntimeContractError { ConvertTo-AiInstructionsSyncConfigurationV4 -ExistingConfiguration $example -CatalogRepository $script:CanonicalRepository -CatalogRef ('d' * 40) }) |
            Should Be 'AI Instructions sync configuration schema version 5 requires a projection-aware installer.'
    }

    # Scenario: Projection selections are malformed, cross scoped, duplicated, or extended unexpectedly.
    # Purpose: Keep v5 projection selection bound to the P6a fixed projection contract.
    It 'UnitT98_rejects_invalid_v5_projection_selections_and_unknown_properties' {
        $path = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v5.example.json'
        $cases = @(
            @{ Mutate={ param($x) $x.projections.user=@('user-claude') }; Pattern='must include' },
            @{ Mutate={ param($x) $x.projections.user=@('user-agents','project-agents') }; Pattern='wrong-scope' },
            @{ Mutate={ param($x) $x.projections.project=@('user-claude') }; Pattern='wrong-scope' },
            @{ Mutate={ param($x) $x.projections.user=@('user-agents','user-agents') }; Pattern='duplicate' },
            @{ Mutate={ param($x) $x.projections.project=@('project-unknown') }; Pattern='unknown' },
            @{ Mutate={ param($x) $x | Add-Member -NotePropertyName unexpected -NotePropertyValue $true }; Pattern='unsupported property' }
        )
        foreach ($case in $cases) {
            $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
            & $case.Mutate $configuration
            (Get-RuntimeContractError { Assert-AiInstructionsSyncConfigurationV5 -Configuration $configuration }) | Should Match $case.Pattern
        }
    }

    # Scenario: The checked-in v3 bundle describes the complete platform runtime and installed Catalog fixture.
    # Purpose: Exercise closure, platform, capability, projection, fingerprint, and inventory bindings independently of sync v4/v5 rollout.
    It 'UnitT99_validates_the_runtime_bundle_v3_example' {
        $example = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\runtime-bundle-v3.example.json') | ConvertFrom-Json
        (Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $example.inventory) | Should Be $example.inventorySha256
        $fixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-example')
        $actualInventory = @(Get-AiInstructionsRuntimeInventory -RuntimeRoot $fixture.Root)
        (Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $actualInventory) | Should Be $fixture.Bundle.inventorySha256
        $configurationV5 = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v5.example.json') | ConvertFrom-Json
        $configurationV4 = New-TestConfigurationDocument -SchemaVersion 4
        $configurationV4.catalog.ref = $fixture.Bundle.commit
        { Assert-AiInstructionsRuntimeBundleV3 -Bundle $fixture.Bundle -Configuration $configurationV4 -RuntimeRoot $fixture.Root } | Should Not Throw
        { Assert-AiInstructionsRuntimeBundleV3 -Bundle $fixture.Bundle -Configuration $configurationV5 -RuntimeRoot $fixture.Root } | Should Not Throw
    }

    # Scenario: The runtime-contract module has a fixed expected platform runtime API surface.
    # Purpose: Keep the runtime bundle validator's API allowlist synchronized with the checked-in manifest.
    It 'UnitT103_keeps_expected_platform_runtime_exports_in_sync_with_the_manifest' {
        $contractModule = Import-Module -Name $script:RuntimeContractModule -PassThru -Force
        $expectedFunctions = & $contractModule { @($script:ExpectedPlatformRuntimeFunctionsToExport) }
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepositoryRoot 'scripts\platform-runtime.psd1')

        @($expectedFunctions) | Should Be @($manifest.FunctionsToExport)
    }

    # Scenario: Platform metadata, capability declarations, and required runtime inventory are malformed.
    # Purpose: Fail closed on every v3-only contract boundary.
    It 'UnitT86_rejects_invalid_runtime_bundle_v3_fields' {
        $fixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-negative')
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v5.example.json') | ConvertFrom-Json
        $cases = @(
            @{ Mutate={param($x)$x.platform.os='bsd'}; Pattern='platform.os' },
            @{ Mutate={param($x)$x.platform.architecture='riscv64'}; Pattern='platform.architecture' },
            @{ Mutate={param($x)$x.requiredCapabilities=@('unknown')}; Pattern='unknown required capability' },
            @{ Mutate={param($x)$x.requiredCapabilities=@('lock','lock')}; Pattern='duplicate required capability' },
            @{ Mutate={param($x)$x.platformRuntime.apiVersion='1'}; Pattern='apiVersion' },
            @{ Mutate={param($x)$x.inventorySha256=('0' * 64)}; Pattern='digest' },
            @{ Mutate={param($x)$x | Add-Member -NotePropertyName unexpected -NotePropertyValue $true}; Pattern='unsupported property' }
        )
        foreach ($case in $cases) {
            $bundle = $fixture.Bundle | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            & $case.Mutate $bundle
            if ($case.Pattern -cne 'digest') { $bundle.inventorySha256 = Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $bundle.inventory }
            (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $bundle -Configuration $configuration -RuntimeRoot $fixture.Root }) | Should Match $case.Pattern
        }
    }

    # Scenario: Installed platform closure, Catalog projections, manifest trust pin, or source fingerprint drifts from the v3 bundle.
    # Purpose: Bind every executable runtime dependency and the selected projection contract before use.
    It 'UnitT87_rejects_runtime_bundle_v3_closure_and_projection_drift' {
        $configuration = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v5.example.json') | ConvertFrom-Json
        $missingFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-missing-closure')
        Remove-Item -LiteralPath (Join-Path $missingFixture.Root 'platform\Linux.psm1')
        Update-TestRuntimeV3Inventory -Fixture $missingFixture
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $missingFixture.Bundle -Configuration $configuration -RuntimeRoot $missingFixture.Root }) |
            Should Match 'implementation directory contains missing or extra files'

        $hashFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-closure-hash')
        @($hashFixture.Bundle.inventory | Where-Object path -eq 'platform/Linux.psm1')[0].sha256 = '0' * 64
        $hashFixture.Bundle.inventorySha256 = Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $hashFixture.Bundle.inventory
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $hashFixture.Bundle -Configuration $configuration -RuntimeRoot $hashFixture.Root }) |
            Should Match 'inventory'

        $manifestFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-manifest-hash')
        $manifestFixture.Bundle.platformRuntime.manifestSha256 = '0' * 64
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $manifestFixture.Bundle -Configuration $configuration -RuntimeRoot $manifestFixture.Root }) |
            Should Match 'manifestSha256'

        $fileListFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-manifest-file-list')
        $fileListManifestPath = Join-Path $fileListFixture.Root 'platform-runtime.psd1'
        Set-TestTextOccurrence -Path $fileListManifestPath -OldValue "        'platform/Linux.psm1',`n" -NewValue "        `n"
        Update-TestRuntimeV3Inventory -Fixture $fileListFixture
        $fileListFixture.Bundle.platformRuntime.manifestSha256 = Get-TestCanonicalTextSha256 -Path $fileListManifestPath
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $fileListFixture.Bundle -Configuration $configuration -RuntimeRoot $fileListFixture.Root }) |
            Should Match 'FileList differs'

        $manifestInventoryFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-manifest-inventory-hash')
        $manifestInventoryPath = Join-Path $manifestInventoryFixture.Root 'platform-runtime.psd1'
        Set-TestTextOccurrence `
            -Path $manifestInventoryPath `
            -OldValue "Sha256 = '82e7a6412abd51da98f7eb1777518dc9714dcaa3a72954af8a8ba5e959d3d879'" `
            -NewValue ("Sha256 = '" + ('0' * 64) + "'")
        Update-TestRuntimeV3Inventory -Fixture $manifestInventoryFixture
        $manifestInventoryFixture.Bundle.platformRuntime.manifestSha256 = Get-TestCanonicalTextSha256 -Path $manifestInventoryPath
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $manifestInventoryFixture.Bundle -Configuration $configuration -RuntimeRoot $manifestInventoryFixture.Root }) |
            Should Match 'manifest inventory hash mismatch'

        $manifestApiFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-manifest-api-version')
        $manifestApiPath = Join-Path $manifestApiFixture.Root 'platform-runtime.psd1'
        Set-TestTextOccurrence -Path $manifestApiPath -OldValue "ApiVersion = '1.0'" -NewValue "ApiVersion = '2.0'"
        Update-TestRuntimeV3Inventory -Fixture $manifestApiFixture
        $manifestApiFixture.Bundle.platformRuntime.manifestSha256 = Get-TestCanonicalTextSha256 -Path $manifestApiPath
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $manifestApiFixture.Bundle -Configuration $configuration -RuntimeRoot $manifestApiFixture.Root }) |
            Should Match 'ApiVersion does not match'

        $nestedManifestFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-nested-manifest')
        $nestedManifestDirectory = Join-Path $nestedManifestFixture.Root 'nested'
        New-Item -ItemType Directory -Path $nestedManifestDirectory | Out-Null
        Move-Item -LiteralPath (Join-Path $nestedManifestFixture.Root 'platform-runtime.psd1') -Destination (Join-Path $nestedManifestDirectory 'platform-runtime.psd1')
        Update-TestRuntimeV3Inventory -Fixture $nestedManifestFixture
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $nestedManifestFixture.Bundle -Configuration $configuration -RuntimeRoot $nestedManifestFixture.Root }) |
            Should Match 'at the runtime root'

        $nestedCatalogFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-nested-catalog')
        $nestedCatalogDirectory = Join-Path $nestedCatalogFixture.Root 'nested\catalog'
        New-Item -ItemType Directory -Path $nestedCatalogDirectory -Force | Out-Null
        Move-Item -LiteralPath (Join-Path $nestedCatalogFixture.Root 'catalog\skills-catalog.json') -Destination (Join-Path $nestedCatalogDirectory 'skills-catalog.json')
        Update-TestRuntimeV3Inventory -Fixture $nestedCatalogFixture
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $nestedCatalogFixture.Bundle -Configuration $configuration -RuntimeRoot $nestedCatalogFixture.Root }) |
            Should Match 'fixed Catalog path'

        $catalogV2Fixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-catalog-v2')
        $catalogPath = Join-Path $catalogV2Fixture.Root 'catalog\skills-catalog.json'
        $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
        $catalog.schemaVersion = 2
        [IO.File]::WriteAllText($catalogPath,($catalog | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Update-TestRuntimeV3Inventory -Fixture $catalogV2Fixture
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $catalogV2Fixture.Bundle -Configuration $configuration -RuntimeRoot $catalogV2Fixture.Root }) |
            Should Match 'Catalog must use schemaVersion 3'

        $catalogProjectionFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-catalog-projection')
        $catalogProjectionPath = Join-Path $catalogProjectionFixture.Root 'catalog\skills-catalog.json'
        $catalogProjection = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogProjectionPath | ConvertFrom-Json
        $catalogProjection.projections = @($catalogProjection.projections | Where-Object id -ne 'project-agents')
        [IO.File]::WriteAllText($catalogProjectionPath,($catalogProjection | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Update-TestRuntimeV3Inventory -Fixture $catalogProjectionFixture
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $catalogProjectionFixture.Bundle -Configuration $configuration -RuntimeRoot $catalogProjectionFixture.Root }) |
            Should Match 'projectionContractSha256'

        $catalogMissingSkillsFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-catalog-missing-skills')
        $catalogMissingSkillsPath = Join-Path $catalogMissingSkillsFixture.Root 'catalog\skills-catalog.json'
        $catalogMissingSkills = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogMissingSkillsPath | ConvertFrom-Json
        $catalogMissingSkills.PSObject.Properties.Remove('skills')
        [IO.File]::WriteAllText($catalogMissingSkillsPath,($catalogMissingSkills | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Update-TestRuntimeV3Inventory -Fixture $catalogMissingSkillsFixture
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $catalogMissingSkillsFixture.Bundle -Configuration $configuration -RuntimeRoot $catalogMissingSkillsFixture.Root }) |
            Should Match "missing required property 'skills'"

        $catalogUnknownPropertyFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-catalog-unknown-property')
        $catalogUnknownPropertyPath = Join-Path $catalogUnknownPropertyFixture.Root 'catalog\skills-catalog.json'
        $catalogUnknownProperty = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogUnknownPropertyPath | ConvertFrom-Json
        $catalogUnknownProperty | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        [IO.File]::WriteAllText($catalogUnknownPropertyPath,($catalogUnknownProperty | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Update-TestRuntimeV3Inventory -Fixture $catalogUnknownPropertyFixture
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $catalogUnknownPropertyFixture.Bundle -Configuration $configuration -RuntimeRoot $catalogUnknownPropertyFixture.Root }) |
            Should Match "unsupported property 'unexpected'"

        $projectionFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-projection')
        $projectionFixture.Bundle.projectionContractSha256 = '0' * 64
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $projectionFixture.Bundle -Configuration $configuration -RuntimeRoot $projectionFixture.Root }) |
            Should Match 'projectionContractSha256'

        $fingerprintFixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-fingerprint')
        $fingerprintFixture.Bundle.platformRuntime.sourceFingerprint = '0' * 64
        (Get-RuntimeContractError { Assert-AiInstructionsRuntimeBundleV3 -Bundle $fingerprintFixture.Bundle -Configuration $configuration -RuntimeRoot $fingerprintFixture.Root }) |
            Should Match 'sourceFingerprint'
    }

    # Scenario: Inventory paths sort differently under culture-sensitive or case-insensitive comparers.
    # Purpose: Keep the v3 digest stable across PowerShell editions, operating systems, and process cultures.
    It 'UnitT100_computes_runtime_bundle_v3_inventory_digest_with_ordinal_path_order' {
        $inventory = @('B','a','a-b','a_b','aB','ab','ä') | ForEach-Object {
            [pscustomobject]@{ path=$_; sha256=(('{0:x2}' -f ([int][char]$_[0])) * 32).Substring(0,64) }
        }
        $expected = Get-TestOrdinalRuntimeInventorySha256 -Inventory $inventory
        $actual = Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $inventory
        $actual | Should Be $expected

        $inventoryPath = Join-Path $TestDrive 'runtime-v3-ordinal-inventory.json'
        $childScriptPath = Join-Path $TestDrive 'runtime-v3-ordinal-child.ps1'
        [IO.File]::WriteAllText($inventoryPath,($inventory | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        $childScript = @'
param([string] $ModulePath,[string] $InventoryPath)
$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force -ErrorAction Stop
$inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $InventoryPath | ConvertFrom-Json
Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $inventory
'@
        [IO.File]::WriteAllText($childScriptPath,$childScript,[Text.UTF8Encoding]::new($false))

        $isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
        $comparisonDigests = @()
        if ($isWindowsPlatform -and $null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
            $comparisonResult = Invoke-TestRuntimeV3OrdinalChild -Executable 'powershell.exe' -ScriptPath $childScriptPath -ModulePath $script:RuntimeContractModule -InventoryPath $inventoryPath
            $comparisonResult.ExitCode | Should Be 0
            $comparisonResult.StdErr | Should Be ''
            $comparisonResult.StdOut.Trim() | Should Match '^[0-9a-f]{64}$'
            $comparisonResult.StdOut.Trim() | Should Be $actual
            $comparisonDigests += $comparisonResult.StdOut.Trim()
        }
        elseif (-not $isWindowsPlatform -and $null -ne (Get-Command pwsh -ErrorAction SilentlyContinue)) {
            $originalLang = $env:LANG
            $originalLcAll = $env:LC_ALL
            try {
                foreach ($locale in @('C','en_US.UTF-8')) {
                    $env:LANG = $locale
                    $env:LC_ALL = $locale
                    $comparisonResult = Invoke-TestRuntimeV3OrdinalChild -Executable 'pwsh' -ScriptPath $childScriptPath -ModulePath $script:RuntimeContractModule -InventoryPath $inventoryPath
                    $comparisonResult.ExitCode | Should Be 0
                    $comparisonResult.StdErr | Should Be ''
                    $comparisonResult.StdOut.Trim() | Should Match '^[0-9a-f]{64}$'
                    $comparisonResult.StdOut.Trim() | Should Be $actual
                    $comparisonDigests += $comparisonResult.StdOut.Trim()
                }
            }
            finally {
                $env:LANG = $originalLang
                $env:LC_ALL = $originalLcAll
            }
        }
        else {
            $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                foreach ($culture in @([Globalization.CultureInfo]::GetCultureInfo('tr-TR'),[Globalization.CultureInfo]::GetCultureInfo('zh-TW'),[Globalization.CultureInfo]::InvariantCulture)) {
                    [Threading.Thread]::CurrentThread.CurrentCulture = $culture
                    $comparisonDigests += Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $inventory
                }
            }
            finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
        }
        foreach ($digest in $comparisonDigests) { [string]$digest | Should Be $actual }
    }

    # Scenario: A v3 inventory path contains a digest record delimiter control character.
    # Purpose: Keep JSON Schema and executable validation from accepting ambiguous digest input.
    It 'UnitT101_rejects_runtime_bundle_v3_inventory_control_characters' {
        $fixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-control-character')
        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $configuration.catalog.ref = $fixture.Bundle.commit
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\runtime-bundle-v3.schema.json'

        foreach ($controlCharacter in @("`t","`n","`r")) {
            $bundle = $fixture.Bundle | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $bundle.inventory[0].path = 'control' + $controlCharacter + 'path'
            $bundle.inventorySha256 = Get-TestOrdinalRuntimeInventorySha256 -Inventory $bundle.inventory

            (Get-RuntimeContractError { Get-AiInstructionsRuntimeInventorySha256V3 -Inventory $bundle.inventory }) |
                Should Match 'control character'
            (Test-Json -Json ($bundle | ConvertTo-Json -Depth 20) -SchemaFile $schemaPath) | Should Be $false
            (Get-RuntimeContractError {
                Assert-AiInstructionsRuntimeBundleV3 -Bundle $bundle -Configuration $configuration -RuntimeRoot $fixture.Root
            }) | Should Match 'control character'
        }
    }

    # Scenario: A platform runtime manifest adds an unused import-time load hook.
    # Purpose: Reject paths that Import-Module could otherwise load outside the authenticated closure.
    It 'UnitT102_rejects_platform_runtime_manifest_loading_fields' {
        $configuration = New-TestConfigurationDocument -SchemaVersion 4
        $cases = @(
            @{ Field = 'ScriptsToProcess'; Value = "@('../evil.ps1')" },
            @{ Field = 'RequiredAssemblies'; Value = "@('C:\x.dll')" }
        )
        foreach ($case in $cases) {
            $fixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive ('runtime-v3-load-field-' + $case.Field))
            $configuration.catalog.ref = $fixture.Bundle.commit
            $manifestPath = Join-Path $fixture.Root 'platform-runtime.psd1'
            $manifestText = [IO.File]::ReadAllText($manifestPath)
            $closingIndex = $manifestText.LastIndexOf("`n}",[StringComparison]::Ordinal)
            if ($closingIndex -lt 0) { throw 'Test fixture manifest has no closing hashtable delimiter.' }
            $manifestText = $manifestText.Insert($closingIndex,"`n    " + $case.Field + ' = ' + $case.Value)
            [IO.File]::WriteAllText($manifestPath,$manifestText,[Text.UTF8Encoding]::new($false))
            Update-TestRuntimeV3Inventory -Fixture $fixture
            $fixture.Bundle.platformRuntime.manifestSha256 = Get-TestCanonicalTextSha256 -Path $manifestPath

            (Get-RuntimeContractError {
                Assert-AiInstructionsRuntimeBundleV3 -Bundle $fixture.Bundle -Configuration $configuration -RuntimeRoot $fixture.Root
            }) | Should Match 'loading field'
        }
    }

    # Scenario: A platform runtime manifest changes its declared module API surface.
    # Purpose: Bind the authenticated manifest to the exact runtime entry point and exported functions.
    It 'UnitT104_rejects_platform_runtime_manifest_api_drift' {
        $cases = @(
            @{ Name = 'root-module'; OldValue = "RootModule = 'platform-runtime.psm1'"; NewValue = "RootModule = 'renamed-runtime.psm1'"; Pattern = 'RootModule' },
            @{ Name = 'function-export'; OldValue = "        'Get-PlatformCapabilities',`n"; NewValue = "        `n"; Pattern = 'FunctionsToExport' }
        )
        foreach ($case in $cases) {
            $fixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive ('runtime-v3-api-' + $case.Name))
            $configuration = New-TestConfigurationDocument -SchemaVersion 4
            $configuration.catalog.ref = $fixture.Bundle.commit
            $manifestPath = Join-Path $fixture.Root 'platform-runtime.psd1'
            Set-TestTextOccurrence -Path $manifestPath -OldValue $case.OldValue -NewValue $case.NewValue
            Update-TestRuntimeV3Inventory -Fixture $fixture
            $fixture.Bundle.platformRuntime.manifestSha256 = Get-TestCanonicalTextSha256 -Path $manifestPath

            (Get-RuntimeContractError {
                Assert-AiInstructionsRuntimeBundleV3 -Bundle $fixture.Bundle -Configuration $configuration -RuntimeRoot $fixture.Root
            }) | Should Match $case.Pattern
        }
    }

    # Scenario: A v5 selection names a known projection absent from the installed Catalog.
    # Purpose: Prevent projection-aware installation from accepting a selection its authenticated Catalog cannot provide.
    It 'UnitT105_rejects_v5_projection_not_declared_by_the_installed_catalog' {
        $fixture = New-TestRuntimeV3Fixture -Path (Join-Path $TestDrive 'runtime-v3-v5-undeclared-projection')
        $configuration = New-TestConfigurationDocument -SchemaVersion 5
        $configuration.catalog.ref = $fixture.Bundle.commit
        $catalogPath = Join-Path $fixture.Root 'catalog\skills-catalog.json'
        $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
        $catalog.projections = @($catalog.projections | Where-Object { $_.id -ceq 'user-agents' })
        [IO.File]::WriteAllText($catalogPath,($catalog | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Update-TestRuntimeV3Inventory -Fixture $fixture
        Update-TestRuntimeV3ProjectionContract -Fixture $fixture

        (Get-RuntimeContractError {
            Assert-AiInstructionsRuntimeBundleV3 -Bundle $fixture.Bundle -Configuration $configuration -RuntimeRoot $fixture.Root
        }) | Should Match "user-claude.*not declared by the installed catalog"
    }

    # Scenario: The checked-in durable install journal is consumed by both executable and portable validators.
    # Purpose: Keep the v1 example, reader, and JSON Schema on one contract before a writer is connected.
    It 'UnitT106_validates_the_install_journal_v1_example_with_reader_and_schema' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT106 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $examplePath = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json'
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $json = Get-Content -Raw -Encoding UTF8 -LiteralPath $examplePath

        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
        (Test-Json -Json $json -SchemaFile $schemaPath) | Should Be $true
    }

    # Scenario: Individually malformed journal fields are presented to the executable and portable contracts.
    # Purpose: Keep all JSON-Schema-expressible v1 invariants aligned with the exact reader.
    It 'UnitT107_rejects_schema_invalid_install_journal_fields_in_both_validators' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT107 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $cases = @(
            @{ Name='unknown-version'; Change={ param($j) $j.schemaVersion=2 }; Pattern='schema version' },
            @{ Name='extra-property'; Change={ param($j) $j | Add-Member -NotePropertyName unexpected -NotePropertyValue $true }; Pattern='unsupported property' },
            @{ Name='missing-property'; Change={ param($j) $j.PSObject.Properties.Remove('kind') }; Pattern="missing 'kind'" },
            @{ Name='parent-segment'; Change={ param($j) $j.operations[1].targetRelativePath='runtime/../outside' }; Pattern='targetRelativePath' },
            @{ Name='backslash'; Change={ param($j) $j.operations[1].targetRelativePath='runtime\\outside' }; Pattern='targetRelativePath' },
            @{ Name='absolute'; Change={ param($j) $j.operations[1].targetRelativePath='/runtime/outside' }; Pattern='targetRelativePath' },
            @{ Name='control'; Change={ param($j) $j.operations[1].targetRelativePath="runtime/$([char]1)outside" }; Pattern='targetRelativePath' },
            @{ Name='absent-with-hash'; Change={ param($j) $j.operations[1].original.sha256='6' * 64 }; Pattern='must be null' },
            @{ Name='create-original-exists'; Change={ param($j) $j.operations[1].original.exists=$true; $j.operations[1].original.sha256='6' * 64; $j.operations[1].original.length=1; $j.operations[1].original.identity=$j.operations[0].original.identity; $j.operations[1].backupLeaf='created.backup'; $j.operations[1].permissions=$j.operations[0].permissions }; Pattern='create-file' },
            @{ Name='missing-backup'; Change={ param($j) $j.operations[0].backupLeaf=$null }; Pattern='backupLeaf' },
            @{ Name='committed-pending'; Change={ param($j) $j.phase='committed'; $j.operations[0].state='pending'; $j.operations[1].state='applied' }; Pattern='committed' }
        )
        foreach ($case in $cases) {
            $journal = Get-TestInstallJournalV1
            & $case.Change $journal
            (Get-RuntimeContractError { Assert-AiInstructionsInstallJournalV1 -Journal $journal }) | Should Match $case.Pattern
            $json = $journal | ConvertTo-Json -Depth 20
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }
    }

    # Scenario: Array-wide invariants and terminal state consistency reach the executable reader.
    # Purpose: Make it fail closed on sequence gaps, portable-normalized duplicate paths, and phase/state drift.
    It 'UnitT108_rejects_install_journal_cross_operation_and_phase_inconsistency' {
        $journal = Get-TestInstallJournalV1
        $journal.operations[1].sequence = 3
        (Get-RuntimeContractError { Assert-AiInstructionsInstallJournalV1 -Journal $journal }) | Should Match 'continuous sequence'

        $journal = Get-TestInstallJournalV1
        $journal.operations[1].targetRelativePath = $journal.operations[0].targetRelativePath
        (Get-RuntimeContractError { Assert-AiInstructionsInstallJournalV1 -Journal $journal }) | Should Match 'duplicates'

        $journal = Get-TestInstallJournalV1
        $journal.phase = 'committed'
        $journal.operations[0].state = 'pending'
        $journal.operations[1].state = 'applied'
        (Get-RuntimeContractError { Assert-AiInstructionsInstallJournalV1 -Journal $journal }) | Should Match 'sequence 1.state.*committed'
    }

    # Scenario: An ambiguous JSON object repeats a key that ConvertFrom-Json could otherwise collapse.
    # Purpose: Reject duplicate keys before object conversion and exact-property validation.
    It 'UnitT109_rejects_duplicate_install_journal_json_keys' {
        $json = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json')
        $json = $json.Replace('"schemaVersion": 1,','"schemaVersion": 1, "schemaVersion": 1,')
        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'duplicate key.*schemaVersion'
    }

    # Scenario: A completed or fully applied transaction is observed after process restart.
    # Purpose: Distinguish terminal no-op, terminal drift refusal, and the sole commit case.
    It 'UnitT110_decides_none_refuse_and_commit_for_terminal_install_journals' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'committed'
        foreach ($operation in $journal.operations) { $operation.state = 'applied' }
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].applied
        }
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'none'

        $observations[2] = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'refuse'

        $journal.phase = 'applied'
        $observations[2] = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].applied
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'commit'
        (@($decision.operations.action) -join ',') | Should Be 'keep,keep'
    }

    # Scenario: An interrupted applying phase contains one applied replacement and one untouched create operation.
    # Purpose: Roll back only the applied state and never roll forward pending work.
    It 'UnitT111_rolls_back_mixed_original_and_applied_observations' {
        $journal = Get-TestInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'roll-back'
        $decision.operations[0].action | Should Be 'restore-original'
        $decision.operations[1].action | Should Be 'none'

        $observations[1] = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
        $observations[2] = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].applied
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'roll-back'
        $decision.operations[1].action | Should Be 'remove-applied'
    }

    # Scenario: Recovery lacks a required backup or sees content matching neither recorded state.
    # Purpose: Preserve external changes and refuse rollback without the evidence needed to restore ownership.
    It 'UnitT112_refuses_install_recovery_without_backup_or_after_external_change' {
        $journal = Get-TestInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied -Backup $null
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*backup'

        $observations[1] = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        $observations[1].sha256 = '9' * 64
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*external change'
        (@($decision.operations.action) -join ',') | Should Be 'keep,keep'
    }

    # Scenario: Observation keys omit or add an operation sequence.
    # Purpose: Require one observation for every journal operation before making a recovery decision.
    It 'UnitT113_rejects_missing_and_extra_install_recovery_observations' {
        $journal = Get-TestInstallJournalV1
        $missing = @{ 1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original }
        (Get-RuntimeContractError { Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $missing }) | Should Match 'one-to-one'

        $extra = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
            3 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        (Get-RuntimeContractError { Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $extra }) | Should Match 'one-to-one'
    }

    # Scenario: A caller creates a v1 journal without supplying an identifier.
    # Purpose: Return an ordered, fully validated contract object with a generated transaction ID.
    It 'UnitT114_constructs_and_validates_an_install_journal_v1' {
        $source = Get-TestInstallJournalV1
        $journal = New-AiInstructionsInstallJournalV1 `
            -CreatedAtUtc $source.createdAtUtc `
            -OwnerComponent $source.owner.component `
            -OwnerProcessId $source.owner.processId `
            -OwnerProcessStartIdentity $source.owner.processStartIdentity `
            -PlatformOs $source.platform.os `
            -PlatformArchitecture $source.platform.architecture `
            -LockPrimitive $source.lock.primitive `
            -LockLeaf $source.lock.leaf `
            -CandidateBundleSha256 $source.generation.candidateBundleSha256 `
            -Phase $source.phase `
            -Operations $source.operations
        $journal.transactionId | Should Match '^[0-9a-f]{32}$'
        $journal.generation.previousBundleSha256 | Should Be $null
        $journal.operations[0].backupIdentity.fileId | Should Be '0000ABCD:00001235'
        $journal.operations[1].backupIdentity | Should Be $null
        (@($journal.PSObject.Properties.Name) -join ',') | Should Be 'schemaVersion,kind,transactionId,createdAtUtc,owner,platform,lock,generation,phase,operations'
    }

    # Scenario: PowerShell 7.5 would normally coerce an ISO 8601 JSON value to DateTime.
    # Purpose: Keep the durable journal reader's timestamp contract byte-for-value string based on every supported PowerShell.
    It 'UnitT115_preserves_install_journal_created_at_as_a_string' {
        $json = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json')
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json
        ($journal.createdAtUtc -is [string]) | Should Be $true
        $journal.createdAtUtc | Should Be '2026-11-05T01:02:03.0000000Z'
    }

    # Scenario: A deleted target is recreated with the recorded bytes but a different file identity.
    # Purpose: Preserve the external replacement instead of treating it as transaction-owned applied state.
    It 'UnitT116_refuses_same_bytes_with_a_different_file_identity' {
        $journal = Get-TestInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $observations[1].identity = [pscustomobject]@{
            kind = $observations[1].identity.kind
            device = $observations[1].identity.device
            fileId = '0000ABCD:99999999'
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*external change'
    }

    # Scenario: Pending work records the future bytes before publication identity is known.
    # Purpose: Never use a null expected identity as proof that a live target is the applied state.
    It 'UnitT117_treats_pending_applied_state_without_identity_as_not_matching' {
        $journal = Get-TestInstallJournalV1
        $observation = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].applied
        $journal.operations[1].state = 'pending'
        $journal.operations[1].applied.identity = $null
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = $observation
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 2.*external change'
    }

    # Scenario: Recovery can read bytes but cannot obtain the live file ID.
    # Purpose: Fail closed before making any ownership decision about an existing target.
    It 'UnitT118_rejects_an_existing_observation_without_identity' {
        $journal = Get-TestInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $observations[1].identity = $null
        (Get-RuntimeContractError { Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations }) | Should Match 'sequence 1.identity.*must not be null'
    }

    # Scenario: File-state identities violate presence, publication-state, or platform invariants one at a time.
    # Purpose: Keep executable and portable identity contracts aligned.
    It 'UnitT119_rejects_invalid_install_journal_file_state_identities' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT119 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $cases = @(
            @{ Change={ param($j) $j.operations[0].original.identity=$null }; Pattern='original.identity.*must not be null' },
            @{ Change={ param($j) $j.operations[1].applied.identity=$null }; Pattern='applied.identity.*must not be null' },
            @{ Change={ param($j) $j.operations[0].original.identity.kind='unix-device-inode' }; Pattern='original.identity.kind.*journal platform' }
        )
        foreach ($case in $cases) {
            $journal = Get-TestInstallJournalV1
            & $case.Change $journal
            (Get-RuntimeContractError { Assert-AiInstructionsInstallJournalV1 -Journal $journal }) | Should Match $case.Pattern
            $json = $journal | ConvertTo-Json -Depth 20
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }
    }

    # Scenario: Portable journal names can alias on Windows or after Unicode normalization.
    # Purpose: Reject ambiguous target and temporary names on every platform while keeping schema/reader duties explicit.
    It 'UnitT120_rejects_portable_path_aliases_and_windows_unsafe_names' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT120 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $combiningAcute = [char]0x0301
        $precomposedEAcute = [char]0x00e9
        $cases = @(
            @{ Change={ param($j) $j.operations[0].targetRelativePath='runtime/File'; $j.operations[1].targetRelativePath='runtime/file' }; Pattern='duplicates another target path'; SchemaInvalid=$false },
            @{ Change={ param($j) $j.operations[1].targetRelativePath='runtime/file:stream' }; Pattern='targetRelativePath'; SchemaInvalid=$true },
            @{ Change={ param($j) $j.operations[1].targetRelativePath='runtime/nul.txt' }; Pattern='reserved device name'; SchemaInvalid=$false },
            @{ Change={ param($j) $j.operations[1].targetRelativePath='runtime/file.' }; Pattern='targetRelativePath'; SchemaInvalid=$true },
            @{ Change={ param($j) $j.operations[1].targetRelativePath='runtime/file ' }; Pattern='targetRelativePath'; SchemaInvalid=$true },
            @{ Change={ param($j) $j.operations[1].stageLeaf=$j.operations[0].backupLeaf.ToUpperInvariant() }; Pattern='stageLeaf and backupLeaf.*unique'; SchemaInvalid=$false },
            @{ Change={ param($j) $j.operations[0].targetRelativePath="runtime/caf$precomposedEAcute"; $j.operations[1].targetRelativePath="runtime/cafe$combiningAcute" }; Pattern='duplicates another target path'; SchemaInvalid=$false }
        )
        foreach ($case in $cases) {
            $journal = Get-TestInstallJournalV1
            & $case.Change $journal
            (Get-RuntimeContractError { Assert-AiInstructionsInstallJournalV1 -Journal $journal }) | Should Match $case.Pattern
            if ($case.SchemaInvalid) {
                $json = $journal | ConvertTo-Json -Depth 20
                (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
            }
        }
    }

    # Scenario: A one-operation journal has exactly one keyed observation after restart.
    # Purpose: Preserve array shape when PowerShell collapses a single observation property to a scalar.
    It 'UnitT121_decides_recovery_for_a_single_operation_and_single_observation' {
        $journal = Get-TestInstallJournalV1
        $journal.operations = @($journal.operations[0])
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        }

        { Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations | Out-Null } | Should Not Throw
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        @($decision.operations).Count | Should Be 1
    }

    # Scenario: A journal uses the lock primitive implemented by a different platform runtime.
    # Purpose: Keep platform-runtime capability evidence, the constructor parameter, reader, and portable schema on the same names and OS binding.
    It 'UnitT122_rejects_install_journal_lock_primitives_for_the_wrong_platform' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT122 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $validateSet = (Get-Command New-AiInstructionsInstallJournalV1).Parameters['LockPrimitive'].Attributes |
            Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] }
        (@($validateSet.ValidValues) -join ',') | Should Be 'windows-fileshare,flock'
        $cases = @(
            @{ Journal=(Get-TestInstallJournalV1); Primitive='flock'; Expected='windows-fileshare' },
            @{ Journal=(Get-TestLinuxInstallJournalV1); Primitive='windows-fileshare'; Expected='flock' }
        )
        foreach ($case in $cases) {
            $case.Journal.lock.primitive = $case.Primitive
            $json = $case.Journal | ConvertTo-Json -Depth 20
            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match "lock.primitive must be $($case.Expected)"
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }
    }

    # Scenario: A lock filename is valid on one host but unsafe or ambiguous on Windows.
    # Purpose: Apply the same portable leaf contract to lock, stage, and backup names without adding lock to temporary-name uniqueness.
    It 'UnitT123_rejects_nonportable_install_journal_lock_leaves' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT123 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $cases = @(
            @{ Leaf='NUL'; Pattern='reserved device name'; SchemaValid=$true },
            @{ Leaf='a:b'; Pattern='portable single filename'; SchemaValid=$false },
            @{ Leaf='lock.'; Pattern='portable single filename'; SchemaValid=$false }
        )
        foreach ($case in $cases) {
            $journal = Get-TestInstallJournalV1
            $journal.lock.leaf = $case.Leaf
            $json = $journal | ConvertTo-Json -Depth 20
            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match $case.Pattern
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $case.SchemaValid
        }
    }

    # Scenario: A permissions snapshot is valid in shape but cannot be restored by the journal platform adapter.
    # Purpose: Reject cross-platform permission kinds in both the strict reader and JSON Schema.
    It 'UnitT124_rejects_install_journal_permission_kinds_for_the_wrong_platform' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT124 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $windowsJournal = Get-TestInstallJournalV1
        $windowsJournal.operations[0].permissions = [pscustomobject]@{ kind='unix-mode'; mode='0644'; uid=1000; gid=1000 }
        $linuxJournal = Get-TestLinuxInstallJournalV1
        $linuxJournal.operations[0].permissions = [pscustomobject]@{ kind='windows-sddl'; sddl='D:PAI(A;;FA;;;SY)'; readOnly=$false }
        $cases = @(
            @{ Journal=$windowsJournal; Expected='windows-sddl' },
            @{ Journal=$linuxJournal; Expected='unix-mode' }
        )
        foreach ($case in $cases) {
            $json = $case.Journal | ConvertTo-Json -Depth 20
            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match "permissions.kind must be $($case.Expected)"
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }
    }

    # Scenario: Windows superscript-digit device aliases appear in a target segment or temporary leaf.
    # Purpose: Treat the documented COM/LPT aliases as reserved on every journal platform without embedding non-ASCII source characters.
    It 'UnitT125_rejects_superscript_windows_device_aliases_in_journal_names' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT125 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $superscriptOne = [char]0x00B9
        $superscriptTwo = [char]0x00B2
        $cases = @(
            @{ Change={ param($j) $j.operations[1].targetRelativePath="runtime/COM$superscriptOne.txt" }; Pattern='targetRelativePath contains a Windows reserved device name' },
            @{ Change={ param($j) $j.operations[1].stageLeaf="LPT$superscriptTwo.stage" }; Pattern='stageLeaf must not use a Windows reserved device name' }
        )
        foreach ($case in $cases) {
            $journal = Get-TestInstallJournalV1
            & $case.Change $journal
            $json = $journal | ConvertTo-Json -Depth 20
            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match $case.Pattern
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $true
        }
    }

    # Scenario: A write operation can restore original content but omits its original permissions snapshot.
    # Purpose: Refuse rollback evidence that cannot prove restoration of the original access policy.
    It 'UnitT126_rejects_write_file_without_original_permissions' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT126 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].permissions = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.permissions.*must not be null'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A remove operation preserves a backup but omits its original permissions snapshot.
    # Purpose: Require access-policy evidence for every operation whose original target existed.
    It 'UnitT127_rejects_remove_file_without_original_permissions' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT127 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].kind = 'remove-file'
        $journal.operations[0].method = 'tombstone-rename'
        $journal.operations[0].stageLeaf = $null
        $journal.operations[0].backupIdentity = $journal.operations[0].original.identity
        $journal.operations[0].applied.exists = $false
        $journal.operations[0].applied.sha256 = $null
        $journal.operations[0].applied.length = $null
        $journal.operations[0].applied.identity = $null
        $journal.operations[0].permissions = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.permissions.*must not be null'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A create operation has no original filesystem object or access policy to restore.
    # Purpose: Preserve null permissions as a valid representation for create-file operations.
    It 'UnitT128_accepts_create_file_without_original_permissions' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT128 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $json = $journal | ConvertTo-Json -Depth 20

        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $true
    }

    # Scenario: A Windows write operation claims the removed in-place publication method.
    # Purpose: Keep journal v1 publication atomic on every platform by rejecting methods outside the closed enum.
    It 'UnitT129_rejects_windows_in_place_write_as_an_unknown_method' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT129 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].method = 'in-place'
        $journal.operations[0].stageLeaf = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.method is invalid'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A stage-rename write operation omits its stage object after publication.
    # Purpose: Keep stage reopening, verification, and cleanup possible in every operation state.
    It 'UnitT130_rejects_stage_rename_write_without_stage_leaf' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT130 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].stageLeaf = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.stageLeaf.*method is stage-rename'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A create operation claims the removal-only tombstone-rename method.
    # Purpose: Require create publication to use stage-and-rename with durable stage evidence.
    It 'UnitT131_rejects_tombstone_rename_for_create_file' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT131 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[1].method = 'tombstone-rename'
        $journal.operations[1].stageLeaf = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 2.method.*stage-rename for create-file'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A directory swap claims the removal-only tombstone-rename method.
    # Purpose: Require directory replacement to retain its stage-and-rename recovery evidence.
    It 'UnitT132_rejects_tombstone_rename_for_swap_directory' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT132 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].kind = 'swap-directory'
        $journal.operations[0].method = 'tombstone-rename'
        $journal.operations[0].stageLeaf = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.method.*stage-rename for swap-directory'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A file removal claims a stage-and-rename publication method.
    # Purpose: Bind remove-file recovery to a same-identity tombstone rename plus backup restoration.
    It 'UnitT133_rejects_stage_rename_remove_file' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT133 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].kind = 'remove-file'
        $journal.operations[0].applied.exists = $false
        $journal.operations[0].applied.sha256 = $null
        $journal.operations[0].applied.length = $null
        $journal.operations[0].applied.identity = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.method.*tombstone-rename for remove-file'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A tombstone removal claims that a distinct stage object was published.
    # Purpose: Keep removal state aligned with a method that never creates a stage object.
    It 'UnitT134_rejects_staged_state_for_tombstone_rename_method' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT134 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].kind = 'remove-file'
        $journal.operations[0].method = 'tombstone-rename'
        $journal.operations[0].stageLeaf = $null
        $journal.operations[0].backupIdentity = $journal.operations[0].original.identity
        $journal.operations[0].state = 'staged'
        $journal.operations[0].applied.exists = $false
        $journal.operations[0].applied.sha256 = $null
        $journal.operations[0].applied.length = $null
        $journal.operations[0].applied.identity = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.method tombstone-rename.*state staged'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: An operation omits the publication method entirely.
    # Purpose: Refuse ambiguous recovery records in the reader, constructor validator, and schema.
    It 'UnitT135_rejects_install_journal_operation_without_method' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT135 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].PSObject.Properties.Remove('method')
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match "sequence 1 is missing 'method'"
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: Every platform-runtime reserved alias is used in a target segment or journal leaf.
    # Purpose: Keep target, stage, backup, and lock checks aligned with the Windows native runtime.
    It 'UnitT136_rejects_platform_runtime_reserved_names_in_all_journal_name_positions' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT136 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $superscriptOne = [char]0x00B9
        $superscriptThree = [char]0x00B3
        $cases = @(
            @{ Name='CON'; Change={ param($j,$n) $j.operations[0].targetRelativePath="runtime/$n" } },
            @{ Name='prn.txt'; Change={ param($j,$n) $j.operations[0].stageLeaf=$n } },
            @{ Name='AUX'; Change={ param($j,$n) $j.operations[0].backupLeaf=$n } },
            @{ Name='nul'; Change={ param($j,$n) $j.lock.leaf=$n } },
            @{ Name='CONIN$'; Change={ param($j,$n) $j.operations[0].targetRelativePath="runtime/$n" } },
            @{ Name='conout$.log'; Change={ param($j,$n) $j.operations[0].stageLeaf=$n } },
            @{ Name='COM0'; Change={ param($j,$n) $j.operations[0].backupLeaf=$n } },
            @{ Name='COM9'; Change={ param($j,$n) $j.lock.leaf=$n } },
            @{ Name='LPT0'; Change={ param($j,$n) $j.operations[0].targetRelativePath="runtime/$n" } },
            @{ Name="COM$superscriptOne"; Change={ param($j,$n) $j.operations[0].stageLeaf=$n } },
            @{ Name="LPT$superscriptThree.x"; Change={ param($j,$n) $j.operations[0].backupLeaf=$n } }
        )
        foreach ($case in $cases) {
            $journal = Get-TestInstallJournalV1
            & $case.Change $journal $case.Name
            (Get-RuntimeContractError { Assert-AiInstructionsInstallJournalV1 -Journal $journal }) | Should Match 'reserved device name'
        }
    }

    # Scenario: Similar-looking ordinary names are used as target path segments.
    # Purpose: Avoid broadening the native reserved-name set beyond exact aliases.
    It 'UnitT137_accepts_nonreserved_platform_runtime_name_neighbours' {
        foreach ($name in @('CONX','COM10','LPT','console')) {
            $journal = Get-TestInstallJournalV1
            $journal.operations[0].targetRelativePath = "runtime/$name"
            { Assert-AiInstructionsInstallJournalV1 -Journal $journal | Out-Null } | Should Not Throw
        }
    }

    # Scenario: Two distinct journal documents arrive through one PowerShell pipeline.
    # Purpose: Parse, validate, and emit every pipeline record in input order.
    It 'UnitT138_parses_each_install_journal_pipeline_input_in_order' {
        $first = Get-TestInstallJournalV1
        $second = Get-TestInstallJournalV1
        $first.transactionId = '11111111111111111111111111111111'
        $second.transactionId = '22222222222222222222222222222222'
        $json = @(
            ($first | ConvertTo-Json -Depth 20)
            ($second | ConvertTo-Json -Depth 20)
        )

        $result = @($json | ConvertFrom-AiInstructionsInstallJournalV1Json)
        $result.Count | Should Be 2
        (@($result.transactionId) -join ',') | Should Be '11111111111111111111111111111111,22222222222222222222222222222222'
    }

    # Scenario: The second journal document in a pipeline omits its method.
    # Purpose: Ensure per-record validation cannot silently retain only the last or first input.
    It 'UnitT139_throws_when_the_second_install_journal_pipeline_input_is_invalid' {
        $first = Get-TestInstallJournalV1
        $second = Get-TestInstallJournalV1
        $second.operations[0].PSObject.Properties.Remove('method')
        $json = @(
            ($first | ConvertTo-Json -Depth 20)
            ($second | ConvertTo-Json -Depth 20)
        )

        (Get-RuntimeContractError { $json | ConvertFrom-AiInstructionsInstallJournalV1Json | Out-Null }) | Should Match "sequence 1 is missing 'method'"
    }

    # Scenario: Rollback restored original bytes and identity but crashed before restoring the original access policy.
    # Purpose: Resume the incomplete rollback by restoring permissions instead of treating the operation as complete.
    It 'UnitT140_restores_permissions_when_rolling_back_original_content_with_permission_drift' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'rolling-back'
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $observations[1].permissions.readOnly = -not $observations[1].permissions.readOnly

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'roll-back'
        $decision.operations[0].action | Should Be 'restore-permissions'
        $decision.operations[1].action | Should Be 'none'
    }

    # Scenario: A rolled-back journal has original content everywhere but one access policy still differs.
    # Purpose: Refuse to accept a terminal rollback whose permissions restoration is incomplete.
    It 'UnitT141_refuses_rolled_back_state_with_permission_drift' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'rolled-back'
        foreach ($operation in $journal.operations) { $operation.state = 'rolled-back' }
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $observations[1].permissions.readOnly = -not $observations[1].permissions.readOnly

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*permissions'
        (@($decision.operations.action) -join ',') | Should Be 'keep,keep'
    }

    # Scenario: A rolled-back journal has original content, identity, and required permissions everywhere.
    # Purpose: Preserve the terminal no-op decision when rollback is fully complete.
    It 'UnitT142_accepts_fully_matching_rolled_back_state' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'rolled-back'
        foreach ($operation in $journal.operations) { $operation.state = 'rolled-back' }
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'none'
        @($decision.reasons).Count | Should Be 0
    }

    # Scenario: Recovery can observe existing content and identity but cannot read its permissions.
    # Purpose: Fail closed before making a recovery decision without access-policy evidence.
    It 'UnitT143_rejects_an_existing_observation_without_permissions' {
        $journal = Get-TestInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $observations[1].permissions = $null

        (Get-RuntimeContractError { Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations }) | Should Match 'sequence 1.permissions must not be null'
    }

    # Scenario: A Windows recovery observation reports the Unix permissions shape.
    # Purpose: Bind observed permissions to the journal platform before comparison.
    It 'UnitT144_rejects_observation_permissions_for_the_wrong_platform' {
        $journal = Get-TestInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].original
        }
        $observations[1].permissions = [pscustomobject]@{ kind='unix-mode'; mode='0644'; uid=1000; gid=1000 }

        (Get-RuntimeContractError { Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations }) | Should Match 'sequence 1.permissions.kind must be windows-sddl'
    }

    # Scenario: Unix recovery observes the same mode without the journal's optional leading zero.
    # Purpose: Compare Unix modes by normalized integer value while retaining uid and gid checks.
    It 'UnitT145_treats_unix_modes_with_optional_leading_zero_as_equal' {
        $journal = Get-TestLinuxInstallJournalV1
        $journal.phase = 'rolling-back'
        $journal.operations = @($journal.operations[0])
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
        }
        $observations[1].permissions.mode = '644'

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'roll-back'
        $decision.operations[0].action | Should Be 'none'
    }

    # Scenario: An applied create-file has observable permissions but no original permissions snapshot.
    # Purpose: Keep create rollback based on its absent original and avoid comparing unrecorded applied permissions.
    It 'UnitT146_does_not_compare_permissions_for_create_file_recovery' {
        $journal = Get-TestInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
            2 = New-TestInstallObservation -Operation $journal.operations[1] -State $journal.operations[1].applied
        }
        $observations[2].permissions.readOnly = $true

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $journal.operations[1].permissions | Should Be $null
        $decision.action | Should Be 'roll-back'
        $decision.operations[1].action | Should Be 'remove-applied'
    }

    # Scenario: Applying remove-file already renamed the target to its tombstone, so the absent target has null permissions.
    # Purpose: Roll back from the applied state without dereferencing permissions on a nonexistent target.
    It 'UnitT147_restores_removed_file_without_comparing_absent_target_permissions' {
        $journal = Get-TestInstallJournalV1
        $journal.operations = @($journal.operations[0])
        $journal.operations[0].kind = 'remove-file'
        $journal.operations[0].method = 'tombstone-rename'
        $journal.operations[0].stageLeaf = $null
        $journal.operations[0].backupIdentity = $journal.operations[0].original.identity
        $journal.operations[0].state = 'applied'
        $journal.operations[0].applied.exists = $false
        $journal.operations[0].applied.sha256 = $null
        $journal.operations[0].applied.length = $null
        $journal.operations[0].applied.identity = $null
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $observations[1].permissions | Should Be $null
        $decision.action | Should Be 'roll-back'
        $decision.operations[0].action | Should Be 'restore-original'
    }

    # Scenario: A rolled-back remove-file has restored original content, identity, and permissions.
    # Purpose: Accept the terminal rollback only after the restored target and its access policy both match.
    It 'UnitT148_accepts_rolled_back_remove_file_with_matching_permissions' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'rolled-back'
        $journal.operations = @($journal.operations[0])
        $journal.operations[0].kind = 'remove-file'
        $journal.operations[0].method = 'tombstone-rename'
        $journal.operations[0].stageLeaf = $null
        $journal.operations[0].backupIdentity = $journal.operations[0].original.identity
        $journal.operations[0].state = 'rolled-back'
        $journal.operations[0].applied.exists = $false
        $journal.operations[0].applied.sha256 = $null
        $journal.operations[0].applied.length = $null
        $journal.operations[0].applied.identity = $null
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'none'
        @($decision.reasons).Count | Should Be 0
        $decision.operations[0].action | Should Be 'keep'
    }

    # Scenario: Permission comparison receives incomplete evidence from either side.
    # Purpose: Keep the low-level matcher fail-closed and null-safe under strict mode.
    It 'UnitT149_returns_false_when_permission_comparison_has_a_null_side' {
        $runtimeModule = Get-Module | Where-Object { $_.Path -eq $script:RuntimeContractModule } | Select-Object -First 1
        $permissions = [pscustomobject]@{ kind='windows-sddl'; sddl='D:PAI(A;;FA;;;SY)'; readOnly=$false }
        $observation = [pscustomobject]@{ permissions=$permissions }

        (& $runtimeModule { param($Value) Test-AiInstructionsInstallJournalPermissionsMatch -Observation $null -Permissions $Value } $permissions) | Should Be $false
        (& $runtimeModule { param($Value) Test-AiInstructionsInstallJournalPermissionsMatch -Observation $Value -Permissions $null } $observation) | Should Be $false
        (& $runtimeModule { param($Value,$Expected) Test-AiInstructionsInstallJournalPermissionsMatch -Observation $Value -Permissions $Expected } ([pscustomobject]@{ permissions=$null }) $permissions) | Should Be $false
    }

    # Scenario: A remove-file rollback renames its same-identity tombstone back into place.
    # Purpose: Accept the restored tombstone identity without weakening byte or permission checks.
    It 'UnitT150_accepts_restored_remove_file_with_tombstone_identity' {
        $journal = Get-TestInstallJournalV1
        $journal.operations = @($journal.operations[0])
        $journal.operations[0].kind = 'remove-file'
        $journal.operations[0].method = 'tombstone-rename'
        $journal.operations[0].stageLeaf = $null
        $journal.operations[0].backupIdentity = $journal.operations[0].original.identity
        $journal.operations[0].state = 'rolled-back'
        $journal.operations[0].applied.exists = $false
        $journal.operations[0].applied.sha256 = $null
        $journal.operations[0].applied.length = $null
        $journal.operations[0].applied.identity = $null
        $journal.phase = 'rolled-back'
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
        }
        $observations[1].identity = [pscustomobject]@{
            kind = $journal.operations[0].backupIdentity.kind
            device = $journal.operations[0].backupIdentity.device
            fileId = $journal.operations[0].backupIdentity.fileId
        }

        $terminalDecision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $terminalDecision.action | Should Be 'none'
        $terminalDecision.operations[0].action | Should Be 'keep'

        $journal.phase = 'rolling-back'
        $rollingDecision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $rollingDecision.action | Should Be 'roll-back'
        $rollingDecision.operations[0].action | Should Be 'none'
    }

    # Scenario: Restored bytes match the original, but the live identity matches neither the original nor its independent backup.
    # Purpose: Preserve external-change refusal while permitting only the two explicitly recorded identities.
    It 'UnitT151_refuses_restored_bytes_with_an_unrecorded_identity' {
        $journal = Get-TestInstallJournalV1
        $journal.operations = @($journal.operations[0])
        $journal.operations[0].kind = 'remove-file'
        $journal.operations[0].method = 'tombstone-rename'
        $journal.operations[0].stageLeaf = $null
        $journal.operations[0].backupIdentity = $journal.operations[0].original.identity
        $journal.operations[0].state = 'rolled-back'
        $journal.operations[0].applied.exists = $false
        $journal.operations[0].applied.sha256 = $null
        $journal.operations[0].applied.length = $null
        $journal.operations[0].applied.identity = $null
        $journal.phase = 'rolled-back'
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
        }
        $observations[1].identity = [pscustomobject]@{
            kind = 'windows-file-id'
            device = '0x1A2B'
            fileId = '0000ABCD:99999999'
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations
        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'expected terminal state'
    }

    # Scenario: An applied operation claims an original backup exists but omits the identity recorded when that backup was created.
    # Purpose: Refuse incomplete durable ownership evidence in the strict JSON reader.
    It 'UnitT152_rejects_applied_operation_without_backup_identity' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT152 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].backupIdentity = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.backupIdentity.*must not be null'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false

        $journal.operations[0].state = 'pending'
        $json = $journal | ConvertTo-Json -Depth 20
        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $true
    }

    # Scenario: A Windows journal supplies owner, group, or SACL sections that the platform permission setter cannot restore.
    # Purpose: Keep the strict reader and schema limited to the same DACL-only SDDL accepted by the Windows runtime.
    It 'UnitT153_rejects_non_dacl_windows_sddl_and_accepts_dacl_only' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT153 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $invalidSddl = @(
            'D:PAI(A;;FA;;;SY)O:SY'
            'D:PAI(A;;FA;;;SY)G:SY'
            'D:PAI(A;;FA;;;SY)S:PAI(AU;SA;FA;;;SY)'
        )
        foreach ($sddl in $invalidSddl) {
            $journal = Get-TestInstallJournalV1
            $journal.operations[0].permissions.sddl = $sddl
            $json = $journal | ConvertTo-Json -Depth 20
            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'permissions.sddl.*only a DACL'
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }

        $journal = Get-TestInstallJournalV1
        $journal.operations[0].permissions.sddl = 'D:PAI(A;;FA;;;SY)'
        $json = $journal | ConvertTo-Json -Depth 20
        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $true
    }

    # Scenario: A pending remove-file target is absent but no tombstone backup can be observed.
    # Purpose: Refuse an external deletion instead of treating target absence alone as proof that removal was applied.
    It 'UnitT154_refuses_pending_remove_when_target_and_backup_are_absent' {
        $journal = Get-TestPendingRemoveInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied -Backup $null
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*external change'
        $decision.operations[0].action | Should Be 'keep'
    }

    # Scenario: A committed remove-file has already cleaned up its tombstone, while an applied transaction has not committed yet.
    # Purpose: Treat committed target absence as terminal completion, but keep requiring tombstone proof during recovery.
    It 'UnitT161_distinguishes_committed_remove_cleanup_from_uncommitted_recovery' {
        $committedJournal = Get-TestPendingRemoveInstallJournalV1
        $committedJournal.phase = 'committed'
        $committedJournal.operations[0].state = 'applied'
        $committedObservation = New-TestInstallObservation -Operation $committedJournal.operations[0] -State $committedJournal.operations[0].applied -Backup $null

        $committedDecision = Get-AiInstructionsInstallRecoveryDecision -Journal $committedJournal -Observations @{ 1 = $committedObservation }

        $committedDecision.action | Should Be 'none'

        $appliedJournal = Get-TestPendingRemoveInstallJournalV1
        $appliedJournal.phase = 'applied'
        $appliedJournal.operations[0].state = 'applied'
        $appliedObservation = New-TestInstallObservation -Operation $appliedJournal.operations[0] -State $appliedJournal.operations[0].applied -Backup $null

        $appliedDecision = Get-AiInstructionsInstallRecoveryDecision -Journal $appliedJournal -Observations @{ 1 = $appliedObservation }

        $appliedDecision.action | Should Be 'refuse'
    }

    # Scenario: Transaction objects use a private namespace, while targets try both spellings of its reserved first segment.
    # Purpose: Permit a stage leaf equal to a target basename only because structural isolation prevents aliasing.
    It 'UnitT162_reserves_the_transaction_directory_and_accepts_an_isolated_matching_stage_leaf' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT162 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        foreach ($reservedTarget in @('.ai-instructions-txn/x','.AI-Instructions-TXN/x')) {
            $journal = Get-TestInstallJournalV1
            $journal.operations[0].targetRelativePath = $reservedTarget
            $json = $journal | ConvertTo-Json -Depth 20

            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'targetRelativePath.*reserved .ai-instructions-txn'
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }

        $journal = Get-TestInstallJournalV1
        $journal.operations[0].targetRelativePath = 'runtime/runtime-bundle.json'
        $journal.operations[0].stageLeaf = 'runtime-bundle.json'
        $json = $journal | ConvertTo-Json -Depth 20

        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
        (Test-Json -Json $json -SchemaFile $schemaPath) | Should Be $true
    }

    # Scenario: Commit finished, the remove target is absent, and its tombstone still has the recorded bytes and identity.
    # Purpose: Permit idempotent cleanup only while the residual tombstone remains the original transaction object.
    It 'UnitT163_accepts_a_matching_committed_remove_tombstone' {
        $journal = Get-TestPendingRemoveInstallJournalV1
        $journal.phase = 'committed'
        $journal.operations[0].state = 'applied'
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observation = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations @{ 1 = $observation }

        $decision.action | Should Be 'none'
        @($decision.reasons).Count | Should Be 0
    }

    # Scenario: Commit finished, the remove target is absent, but the remaining tombstone bytes were replaced.
    # Purpose: Preserve the foreign tombstone instead of authorizing commit cleanup by target absence alone.
    It 'UnitT164_refuses_a_committed_remove_tombstone_with_a_different_hash' {
        $journal = Get-TestPendingRemoveInstallJournalV1
        $journal.phase = 'committed'
        $journal.operations[0].state = 'applied'
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observation = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        $observation.backup.sha256 = '9' * 64

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations @{ 1 = $observation }

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1 tombstone'
    }

    # Scenario: Commit finished, the remove target is absent, but the remaining tombstone has a new file identity.
    # Purpose: Refuse cleanup of independently recreated bytes even when their hash and length match the original.
    It 'UnitT165_refuses_a_committed_remove_tombstone_with_a_different_identity' {
        $journal = Get-TestPendingRemoveInstallJournalV1
        $journal.phase = 'committed'
        $journal.operations[0].state = 'applied'
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observation = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        $observation.backup.identity = [pscustomobject]@{
            kind = 'windows-file-id'
            device = '0x1A2B'
            fileId = '0000ABCD:99999999'
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations @{ 1 = $observation }

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1 tombstone'
    }

    # Scenario: A pending remove-file target is absent and its same-identity tombstone matches the original bytes.
    # Purpose: Use the tombstone as durable proof that the remove was applied and can be rolled back safely.
    It 'UnitT155_restores_pending_remove_when_the_tombstone_is_available' {
        $journal = Get-TestPendingRemoveInstallJournalV1
        $observations = @{
            1 = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'roll-back'
        $decision.operations[0].action | Should Be 'restore-original'
    }

    # Scenario: A remove tombstone has the original bytes but an identity different from backupIdentity.
    # Purpose: Reject a replaced or independently recreated backup as ownership evidence.
    It 'UnitT156_refuses_remove_when_tombstone_identity_does_not_match' {
        $journal = Get-TestPendingRemoveInstallJournalV1
        $observation = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        $observation.backup.identity = [pscustomobject]@{
            kind = 'windows-file-id'
            device = '0x1A2B'
            fileId = '0000ABCD:99999999'
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations @{ 1 = $observation }

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*backup'
    }

    # Scenario: A remove tombstone has the recorded identity but bytes different from the original.
    # Purpose: Require both ownership and content integrity before restoring a tombstone.
    It 'UnitT157_refuses_remove_when_tombstone_hash_does_not_match' {
        $journal = Get-TestPendingRemoveInstallJournalV1
        $observation = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].applied
        $observation.backup.sha256 = '9' * 64

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations @{ 1 = $observation }

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*backup'
    }

    # Scenario: A pending remove-file omits backupIdentity or records an identity different from its original object.
    # Purpose: Bind every remove tombstone to the identity preserved by rename before recovery uses it as ownership proof.
    It 'UnitT158_rejects_remove_without_the_original_backup_identity' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT158 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestPendingRemoveInstallJournalV1
        $journal.operations[0].backupIdentity = $null
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.backupIdentity.*must not be null'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false

        $journal = Get-TestPendingRemoveInstallJournalV1
        $journal.operations[0].backupIdentity = [pscustomobject]@{
            kind = 'windows-file-id'
            device = '0x1A2B'
            fileId = '0000ABCD:99999999'
        }
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.backupIdentity.*original.identity'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $true
    }

    # Scenario: JSON integer syntax is represented as Double after conversion, while fractional and string values are also supplied.
    # Purpose: Match draft 2020-12 integer semantics without accepting fractional or string coercion.
    It 'UnitT159_accepts_integral_numeric_representation_and_rejects_nonintegers' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT159 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $examplePath = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json'
        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $examplePath

        $integralJson = $source.Replace('"processId": 4242','"processId": 4242.0')
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json $integralJson
        $journal.owner.processId | Should Be 4242
        (Test-Json -Json $integralJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $true

        $fractionalJson = $source.Replace('"processId": 4242','"processId": 4242.5')
        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $fractionalJson }) | Should Match 'owner.processId.*integer'
        (Test-Json -Json $fractionalJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false

        $stringJson = $source.Replace('"processId": 4242','"processId": "4242"')
        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $stringJson }) | Should Match 'owner.processId.*integer'
        (Test-Json -Json $stringJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: Floating-point values that round to zero when coerced to Decimal are supplied as journal integers.
    # Purpose: Validate integer semantics against the original floating-point value before any narrowing conversion.
    It 'UnitT166_rejects_fractional_subnormal_lengths_without_decimal_rounding' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT166 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        foreach ($value in @('1e-29','0.5','1E-300')) {
            $source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json')
            $json = $source.Replace('"length": 512','"length": ' + $value)
            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'length.*integer'
        }

        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json')
        $json = $source.Replace('"length": 512','"length": 4242.0')
        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
    }

    # Scenario: An applied or committed write-file retains a backup that no longer proves the original bytes and identity.
    # Purpose: Refuse terminal cleanup when a residual backup was replaced, while allowing a matching or absent backup.
    It 'UnitT167_validates_residual_write_file_backups_before_terminal_decision' {
        $appliedJournal = Get-TestInstallJournalV1
        $appliedJournal.phase = 'applied'
        foreach ($operation in $appliedJournal.operations) { $operation.state = 'applied' }
        $appliedJournal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($appliedJournal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $appliedJournal.operations) { $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.applied }
        $observations[[int64]1].backup.sha256 = '9' * 64
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $appliedJournal -Observations $observations
        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1 backup'

        $observations[[int64]1] = New-TestInstallObservation -Operation $appliedJournal.operations[0] -State $appliedJournal.operations[0].applied
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $appliedJournal -Observations $observations
        $decision.action | Should Be 'commit'

        $committedJournal = Get-TestInstallJournalV1
        $committedJournal.phase = 'committed'
        foreach ($operation in $committedJournal.operations) { $operation.state = 'applied' }
        $committedJournal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($committedJournal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $committedJournal.operations) { $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.applied }
        $observations[[int64]1].backup.identity.fileId = '0000ABCD:99999999'
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $committedJournal -Observations $observations
        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1 backup'

        $observations[[int64]1].backup = $null
        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $committedJournal -Observations $observations
        $decision.action | Should Be 'none'
    }

    # Scenario: Rollback restored every target but left a write-file backup with different bytes.
    # Purpose: Require valid residual backup evidence before accepting the rolled-back terminal state.
    It 'UnitT168_refuses_rolled_back_state_with_a_mismatched_residual_backup' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'rolled-back'
        foreach ($operation in $journal.operations) { $operation.state = 'rolled-back' }
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $journal.operations) {
            $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.original
        }
        $observations[[int64]1].backup.sha256 = '9' * 64

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*backup'
        @($decision.reasons).Count | Should BeGreaterThan 0
    }

    # Scenario: Rollback restored every target and all transaction backups were already cleaned up.
    # Purpose: Keep the fully completed rolled-back terminal state an empty-reason no-op.
    It 'UnitT169_accepts_rolled_back_state_with_null_backups' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'rolled-back'
        foreach ($operation in $journal.operations) { $operation.state = 'rolled-back' }
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $journal.operations) {
            $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.original -Backup $null
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'none'
        @($decision.reasons).Count | Should Be 0
    }

    # Scenario: A create-file journal records a backup leaf even though no original object exists.
    # Purpose: Keep the strict reader and JSON Schema aligned on the absence of create backups.
    It 'UnitT170_rejects_create_file_with_a_backup_leaf' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT170 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $journal = Get-TestInstallJournalV1
        $journal.operations[1].backupLeaf = 'created.backup'
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 2.backupLeaf.*create-file'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: Recovery observes a backup object for create-file despite the journal having no original.
    # Purpose: Refuse the inconsistent backup evidence instead of accepting or removing the created target.
    It 'UnitT171_refuses_create_file_with_a_nonnull_observed_backup' {
        $journal = Get-TestInstallJournalV1
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $journal.operations) {
            $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.original
        }
        $backup = New-TestInstallObservation -Operation $journal.operations[0] -State $journal.operations[0].original
        $observations[[int64]2].backup = [pscustomobject]@{
            exists = $backup.exists
            sha256 = $backup.sha256
            length = $backup.length
            identity = [pscustomobject]@{
                kind = $backup.identity.kind
                device = $backup.identity.device
                fileId = $backup.identity.fileId
            }
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 2.*backup'
        @($decision.reasons).Count | Should BeGreaterThan 0
    }

    # Scenario: Applying recovery sees original target content but a residual write-file backup has different bytes.
    # Purpose: Validate every observed backup before selecting even a no-op rollback action.
    It 'UnitT172_refuses_applying_original_state_with_a_mismatched_residual_backup' {
        $journal = Get-TestInstallJournalV1
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $journal.operations) {
            $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.original
        }
        $observations[[int64]1].backup.sha256 = '9' * 64

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*backup'
        (@($decision.operations.action) -join ',') | Should Be 'keep,keep'
    }

    # Scenario: Rolling back restored original target content but not permissions, while the residual backup identity was replaced.
    # Purpose: Refuse before selecting restore-permissions when backup ownership evidence is invalid.
    It 'UnitT173_refuses_rolling_back_permission_drift_with_a_mismatched_backup_identity' {
        $journal = Get-TestInstallJournalV1
        $journal.phase = 'rolling-back'
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $journal.operations) {
            $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.original
        }
        $observations[[int64]1].permissions.readOnly = -not $observations[[int64]1].permissions.readOnly
        $observations[[int64]1].backup.identity.fileId = '0000ABCD:99999999'

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'refuse'
        ($decision.reasons -join ' ') | Should Match 'sequence 1.*backup'
        (@($decision.operations.action) -join ',') | Should Be 'keep,keep'
    }

    # Scenario: Applying recovery sees every target in its original state and no residual backup remains.
    # Purpose: Preserve the safe no-op rollback decision when the global backup precondition succeeds.
    It 'UnitT174_rolls_back_with_none_when_original_state_has_no_residual_backup' {
        $journal = Get-TestInstallJournalV1
        $journal = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
        $observations = @{}
        foreach ($operation in $journal.operations) {
            $observations[[int64]$operation.sequence] = New-TestInstallObservation -Operation $operation -State $operation.original -Backup $null
        }

        $decision = Get-AiInstructionsInstallRecoveryDecision -Journal $journal -Observations $observations

        $decision.action | Should Be 'roll-back'
        (@($decision.operations.action) -join ',') | Should Be 'none,none'
    }

    # Scenario: An operation target is an ancestor or descendant of another operation target after portable normalization.
    # Purpose: Reject journals whose operations would record contradictory state for the same directory tree.
    It 'UnitT175_rejects_operation_ancestor_or_descendant_target_<Case>' -TestCases @(
        @{ Case='swap-parent'; SwapPath='runtime'; OtherPath='runtime/marker'; Reverse=$false },
        @{ Case='swap-child'; SwapPath='runtime/dir'; OtherPath='runtime'; Reverse=$true },
        @{ Case='case-insensitive'; SwapPath='Runtime'; OtherPath='runtime/x'; Reverse=$false }
    ) {
        param($Case,$SwapPath,$OtherPath,$Reverse)
        $journal = Get-TestInstallJournalV1
        if ($Reverse) {
            $swapSource = ConvertFrom-AiInstructionsInstallJournalV1Json -Json ($journal | ConvertTo-Json -Depth 20)
            $swapOperation = $swapSource.operations[0]
            $swapOperation.sequence = 2
            $swapOperation.kind = 'swap-directory'
            $swapOperation.targetRelativePath = $SwapPath
            $swapOperation.stageLeaf = 'swap-directory.stage'
            $swapOperation.backupLeaf = 'swap-directory.backup'
            $journal.operations[0].targetRelativePath = $OtherPath
            $journal.operations = @($journal.operations[0],$swapOperation)
        }
        else {
            $journal.operations[0].kind = 'swap-directory'
            $journal.operations[0].targetRelativePath = $SwapPath
            $journal.operations[1].targetRelativePath = $OtherPath
        }
        $json = $journal | ConvertTo-Json -Depth 20

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 2.*sequence 1.*ancestor or descendant'
    }

    # Scenario: A swap-directory target and another operation only share a textual prefix, not a normalized path segment.
    # Purpose: Accept sibling namespaces such as runtime and runtime2.
    It 'UnitT176_accepts_swap_directory_with_a_non_descendant_textual_prefix' {
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].kind = 'swap-directory'
        $journal.operations[0].targetRelativePath = 'runtime'
        $journal.operations[1].targetRelativePath = 'runtime2/x'
        $json = $journal | ConvertTo-Json -Depth 20

        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
    }

    # Scenario: A lock leaf aliases the transaction namespace or a root-level publication target.
    # Purpose: Keep the lock inode outside every namespace that transaction publication can replace.
    It 'UnitT177_rejects_reserved_or_root_target_lock_leaf_and_accepts_nested_target' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT177 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        foreach ($reservedLeaf in @('.ai-instructions-txn','.AI-INSTRUCTIONS-TXN')) {
            $journal = Get-TestInstallJournalV1
            $journal.lock.leaf = $reservedLeaf
            $json = $journal | ConvertTo-Json -Depth 20

            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'lock.*reserved .ai-instructions-txn'
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }

        $journal = Get-TestInstallJournalV1
        $journal.lock.leaf = 'install.lock'
        $journal.operations[0].targetRelativePath = 'install.lock'
        $json = $journal | ConvertTo-Json -Depth 20
        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 1.*lock'
        (Test-Json -Json $json -SchemaFile $schemaPath) | Should Be $true

        $journal = Get-TestInstallJournalV1
        $journal.lock.leaf = 'install.lock'
        $journal.operations[0].targetRelativePath = 'sub/install.lock'
        $json = $journal | ConvertTo-Json -Depth 20
        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
        (Test-Json -Json $json -SchemaFile $schemaPath) | Should Be $true
    }

    # Scenario: File operations target a parent and child path, or two sibling paths.
    # Purpose: Apply the publishable namespace rule to every operation kind without rejecting siblings.
    It 'UnitT178_rejects_file_operation_ancestor_target_and_accepts_siblings' {
        $journal = Get-TestInstallJournalV1
        $journal.operations[0].targetRelativePath = 'runtime'
        $journal.operations[1].targetRelativePath = 'runtime/marker'
        $json = $journal | ConvertTo-Json -Depth 20
        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'sequence 2.*sequence 1.*ancestor or descendant'

        $journal = Get-TestInstallJournalV1
        $journal.operations[0].targetRelativePath = 'a/b'
        $journal.operations[1].targetRelativePath = 'a/c'
        $json = $journal | ConvertTo-Json -Depth 20
        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
    }

    # Scenario: A target segment reaches the schema maxLength with supplementary-plane characters, then exceeds it by one scalar.
    # Purpose: Keep the reader's Unicode scalar count aligned with JSON Schema instead of UTF-16 code units.
    It 'UnitT179_counts_target_length_in_unicode_scalars' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT179 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $supplementaryCharacter = [char]::ConvertFromUtf32(0x1F600)

        $journal = Get-TestInstallJournalV1
        $journal.operations[0].targetRelativePath = $supplementaryCharacter * 512
        $json = $journal | ConvertTo-Json -Depth 20
        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json | Out-Null } | Should Not Throw
        (Test-Json -Json $json -SchemaFile $schemaPath) | Should Be $true

        $journal = Get-TestInstallJournalV1
        $journal.operations[0].targetRelativePath = $supplementaryCharacter * 513
        $json = $journal | ConvertTo-Json -Depth 20
        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'targetRelativePath'
        (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: JSON decodes an isolated high surrogate into a lock leaf.
    # Purpose: Reject invalid Unicode strings before normalization or filesystem use.
    It 'UnitT180_rejects_unpaired_surrogate_in_lock_leaf' {
        $examplePath = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json'
        $json = (Get-Content -Raw -Encoding UTF8 -LiteralPath $examplePath).Replace('"leaf": "install.lock"','"leaf": "\uD800"')

        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match 'unpaired Unicode surrogate'
    }

    # Scenario: The process ID reaches and then exceeds the reader's Int64 upper bound.
    # Purpose: Keep the journal schema's integer range aligned with the reader.
    It 'UnitT181_aligns_process_id_int64_upper_bound_between_reader_and_schema' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT181 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $examplePath = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-install-journal-v1.example.json'
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $source = Get-Content -Raw -Encoding UTF8 -LiteralPath $examplePath

        $acceptedJson = $source.Replace('"processId": 4242', '"processId": 9223372036854775807')
        { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $acceptedJson | Out-Null } | Should Not Throw
        (Test-Json -Json $acceptedJson -SchemaFile $schemaPath) | Should Be $true

        $rejectedJson = $source.Replace('"processId": 4242', '"processId": 9223372036854775808')
        (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $rejectedJson }) | Should Match 'owner.processId'
        (Test-Json -Json $rejectedJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    # Scenario: A journal uses Unicode whitespace at the end of a lock leaf or target path, plus whitespace-only values.
    # Purpose: Keep the reader and schema aligned with PlatformPaths.Leaf whitespace rejection.
    It 'UnitT160_rejects_unicode_whitespace_only_leaf_and_target_segment' {
        if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'UnitT160 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.' }
        $schemaPath = Join-Path $script:RepositoryRoot 'catalog\schemas\ai-instructions-install-journal-v1.schema.json'
        $cases = @(
            @{ Change={ param($j) $j.lock.leaf=[string][char]0x00A0 }; Pattern='lock.leaf' },
            @{ Change={ param($j) $j.operations[0].targetRelativePath="runtime/$([char]0x3000)" }; Pattern='targetRelativePath' },
            @{ Change={ param($j) $j.lock.leaf="lock$([char]0x00A0)" }; Pattern='lock.leaf' },
            @{ Change={ param($j) $j.operations[0].targetRelativePath="runtime$([char]0x3000)" }; Pattern='targetRelativePath' }
        )
        foreach ($case in $cases) {
            $journal = Get-TestInstallJournalV1
            & $case.Change $journal
            $json = $journal | ConvertTo-Json -Depth 20

            (Get-RuntimeContractError { ConvertFrom-AiInstructionsInstallJournalV1Json -Json $json }) | Should Match $case.Pattern
            (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        }
    }
}
