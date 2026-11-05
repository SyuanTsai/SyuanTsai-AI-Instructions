Describe 'Skills Catalog contract' {
    BeforeAll {
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ContractModule = Join-Path $script:RepositoryRoot 'scripts\skills-catalog-contract.psm1'
$script:ProductionCatalog = Join-Path $script:RepositoryRoot 'catalog\skills-catalog.json'
$script:ProductionPins = Join-Path $script:RepositoryRoot 'catalog\skills-catalog.sources.json'
$script:ProductionLock = Join-Path $script:RepositoryRoot 'catalog\skills-catalog-lock.json'
$script:CatalogExample = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog.example.json'
$script:LockExample = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog-lock.example.json'
$script:ManifestExample = Join-Path $script:RepositoryRoot 'catalog\examples\managed-manifest-v2.example.json'
$script:UserManifestExample = Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v1.example.json'
$script:CatalogV2Example = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog-v2.example.json'
$script:LockV2Example = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog-lock-v2.example.json'
$script:CatalogV3Example = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog-v3.example.json'
$script:LockV3Example = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog-lock-v3.example.json'
$script:ManifestV3Example = Join-Path $script:RepositoryRoot 'catalog\examples\managed-manifest-v3.example.json'
$script:UserManifestV2Example = Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v2.example.json'
$script:UserManifestV3Example = Join-Path $script:RepositoryRoot 'catalog\examples\user-skills-managed-manifest-v3.example.json'
$script:ConfigurationExample = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v4.example.json'
$script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures\skills-catalog-contract'

Import-Module $script:ContractModule -Force

function Get-ContractValidationError {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CatalogPath,

        [string] $LockPath = $script:LockExample,

        [string] $ManifestPath = $script:ManifestExample,

        [string] $ConfigurationPath = $script:ConfigurationExample
    )

    try {
        Test-SkillsCatalogContract `
            -CatalogPath $CatalogPath `
            -LockPath $LockPath `
            -ManifestPath $ManifestPath `
            -ConfigurationPath $ConfigurationPath | Out-Null
        return $null
    }
    catch {
        return $_.Exception.Message
    }
}

function Write-TestJsonDocument {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Document,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $path = Join-Path $TestDrive $Name
    $json = ConvertTo-Json -InputObject $Document -Depth 100
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-TestRawSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    $stream = [System.IO.File]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try { return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $sha256.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Assert-UserManifestBindingFailure {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $Catalog,
        [Parameter(Mandatory = $true)][object] $Lock,
        [Parameter(Mandatory = $true)][string] $LockSha256,
        [Parameter(Mandatory = $true)][string] $ExpectedMessage
    )

    $message = $null
    try { Assert-UserSkillsManagedManifestBinding -Manifest $Manifest -Catalog $Catalog -Lock $Lock -LockSha256 $LockSha256 -ExpectedCatalogRepository ([string]$Manifest.catalogRepository) -ExpectedCatalogCommit ([string]$Manifest.catalogCommit) }
    catch { $message = $_.Exception.Message }
    if ([string]::IsNullOrWhiteSpace($message)) { throw 'Expected the user Skills managed manifest binding to fail.' }
    $message.Contains($ExpectedMessage) | Should Be $true
}

    }

    # Scenario: Every checked-in JSON Schema document is loaded by the repository's oldest supported PowerShell runtime.
    # Purpose: Detect malformed schema artifacts before downstream tools depend on them.
    It 'UnitT05_parses_every_checked_in_json_schema_document' {
        $schemaRoot = Join-Path $script:RepositoryRoot 'catalog\schemas'
        $schemaFiles = @(Get-ChildItem -LiteralPath $schemaRoot -File -Filter '*.schema.json')

        $schemaFiles.Count | Should Be 15
        foreach ($schemaFile in $schemaFiles) {
            $schema = Import-SkillsCatalogJson -Path $schemaFile.FullName -DocumentName $schemaFile.Name
            $schema.'$schema' | Should Be 'https://json-schema.org/draft/2020-12/schema'
            $schema.type | Should Be 'object'
        }
    }

    # Scenario: Every checked-in example is validated against its explicitly mapped schema.
    # Purpose: Exercise the portable JSON Schema contract, including composition keywords that
    # the PowerShell parser does not evaluate.
    It 'UnitT06_validates_each_checked_in_example_with_its_explicit_schema_mapping' {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            throw 'UnitT06 requires PowerShell 7 because Test-Json is unavailable in Windows PowerShell 5.1.'
        }

        $exampleMappings = @(
            @{ Example = 'ai-instructions-sync-v4.example.json'; Schema = 'ai-instructions-sync-v4.schema.json'; SchemaVersion = 4 }
            @{ Example = 'ai-instructions-update-receipt-v1.example.json'; Schema = 'ai-instructions-update-receipt-v1.schema.json'; SchemaVersion = 1 }
            @{ Example = 'managed-manifest-v2.example.json'; Schema = 'managed-manifest-v2.schema.json'; SchemaVersion = 2 }
            @{ Example = 'managed-manifest-v3.example.json'; Schema = 'managed-manifest-v3.schema.json'; SchemaVersion = 3 }
            @{ Example = 'runtime-bundle-v2.example.json'; Schema = 'runtime-bundle-v2.schema.json'; SchemaVersion = 2 }
            @{ Example = 'skills-catalog-lock-v2.example.json'; Schema = 'skills-catalog-lock-v2.schema.json'; SchemaVersion = 2 }
            @{ Example = 'skills-catalog-lock-v3.example.json'; Schema = 'skills-catalog-lock-v3.schema.json'; SchemaVersion = 3 }
            @{ Example = 'skills-catalog-lock.example.json'; Schema = 'skills-catalog-lock.schema.json'; SchemaVersion = 1 }
            @{ Example = 'skills-catalog-v2.example.json'; Schema = 'skills-catalog-v2.schema.json'; SchemaVersion = 2 }
            @{ Example = 'skills-catalog-v3.example.json'; Schema = 'skills-catalog-v3.schema.json'; SchemaVersion = 3 }
            @{ Example = 'skills-catalog.example.json'; Schema = 'skills-catalog.schema.json'; SchemaVersion = 1 }
            @{ Example = 'user-skills-managed-manifest-v1.example.json'; Schema = 'user-skills-managed-manifest-v1.schema.json'; SchemaVersion = 1 }
            @{ Example = 'user-skills-managed-manifest-v2.example.json'; Schema = 'user-skills-managed-manifest-v2.schema.json'; SchemaVersion = 2 }
            @{ Example = 'user-skills-managed-manifest-v3.example.json'; Schema = 'user-skills-managed-manifest-v3.schema.json'; SchemaVersion = 3 }
        )

        $exampleRoot = Join-Path $script:RepositoryRoot 'catalog\examples'
        $schemaRoot = Join-Path $script:RepositoryRoot 'catalog\schemas'
        $mappedExamples = @($exampleMappings | ForEach-Object { $_.Example })
        $allExamples = @(Get-ChildItem -LiteralPath $exampleRoot -File -Filter '*.example.json' | ForEach-Object { $_.Name })
        Compare-Object -ReferenceObject $allExamples -DifferenceObject $mappedExamples | Should Be $null

        foreach ($mapping in $exampleMappings) {
            $examplePath = Join-Path $exampleRoot $mapping.Example
            $schemaPath = Join-Path $schemaRoot $mapping.Schema
            $document = Import-SkillsCatalogJson -Path $examplePath -DocumentName $mapping.Example
            $document.schemaVersion | Should Be $mapping.SchemaVersion
            (Test-Json -Json (Get-Content -LiteralPath $examplePath -Raw) -SchemaFile $schemaPath) | Should Be $true
        }
    }

    # Scenario: The checked-in examples describe the complete current catalog and all persisted contracts.
    # Purpose: Protect the executable contract used by later resolver, downloader, and migration tasks.
    It 'UnitT10_validates_the_complete_catalog_lock_manifest_and_configuration_examples' {
        $result = Test-SkillsCatalogContract `
            -CatalogPath $script:CatalogExample `
            -LockPath $script:LockExample `
            -ManifestPath $script:ManifestExample `
            -ConfigurationPath $script:ConfigurationExample

        $result.SkillCount | Should Be 17
        $result.ProfileCount | Should Be 7
        $result.SourceCount | Should Be 1
        $result.ManifestFileCount | Should Be 2

        $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
        $lock = Import-SkillsCatalogJson -Path $script:LockExample -DocumentName 'Skills Catalog lock'
        $userManifest = Import-SkillsCatalogJson -Path $script:UserManifestExample -DocumentName 'user Skills managed manifest'
        Assert-UserSkillsManagedManifestV1 -Manifest $userManifest
        [string]$userManifest.catalogId | Should Be ([string]$catalog.catalogId)
        [string]$userManifest.lockSha256 | Should Be (Get-TestRawSha256 -Path $script:LockExample)
        $userSkill = @($userManifest.files)[0]
        $lockedSkill = @($lock.skills | Where-Object { [string]$_.id -eq [string]$userSkill.skillId })[0]
        $lockedSource = @($lock.sources | Where-Object { [string]$_.id -eq [string]$userSkill.sourceId })[0]
        [string]$userSkill.sourceId | Should Be ([string]$lockedSkill.sourceId)
        ([string]$userSkill.sourcePath).StartsWith(([string]$lockedSkill.sourcePath + '/'),[System.StringComparison]::Ordinal) | Should Be $true
        [string]$userSkill.sourceRepository | Should Be ([string]$lockedSource.repository)
        [string]$userSkill.sourceRef | Should Be ([string]$lockedSource.requestedRef)
        [string]$userSkill.sourceCommit | Should Be ([string]$lockedSource.resolvedCommit)
        [string]$userSkill.sourceVersion | Should Be ([string]$lockedSource.resolvedVersion)
        $productionCatalog = Test-SkillsCatalogDocument -CatalogPath $script:ProductionCatalog
        $actualSkillIds = @($productionCatalog.skills | Select-Object -ExpandProperty id | Sort-Object)
        $catalogSkillIds = @($catalog.skills | Select-Object -ExpandProperty id | Sort-Object)
        ($catalogSkillIds -join "`n") | Should Be ($actualSkillIds -join "`n")

        $expectedProfileIds = @('ai-memory', 'atlassian', 'code-collaboration', 'core', 'external-research', 'knowledge-capture', 'observability')
        $catalogProfileIds = @($catalog.profiles | Select-Object -ExpandProperty id | Sort-Object)
        ($catalogProfileIds -join "`n") | Should Be ($expectedProfileIds -join "`n")
    }

    # Scenario: Production Catalog switches to canonical source packages after the source repositories merge.
    # Purpose: Prevent a legacy source path or stale immutable pin from silently returning to production.
    It 'UnitT10a_binds_production_catalog_v2_to_canonical_sources_and_lock' {
        $catalog = Test-SkillsCatalogDocument -CatalogPath $script:ProductionCatalog
        $pins = Test-SkillsCatalogSourcePinsDocument -SourcePinsPath $script:ProductionPins -CatalogPath $script:ProductionCatalog
        $lock = Test-SkillsCatalogLockDocument -LockPath $script:ProductionLock -CatalogPath $script:ProductionCatalog

        $catalog.schemaVersion | Should Be 2
        $lock.schemaVersion | Should Be 2
        @($catalog.skills).Count | Should Be 17
        @($lock.skills).Count | Should Be 14
        @($catalog.skills | Where-Object { $_.lifecycle.status -eq 'removed' }).Count | Should Be 3
        foreach ($skill in @($catalog.skills | Where-Object { $_.lifecycle.status -ne 'removed' })) {
            $skill.source.sourcePath | Should Be "skills/$($skill.id)"
            $skill.source.targetPath | Should Be ".agents/skills/$($skill.id)"
            $locked = @($lock.skills | Where-Object { $_.id -ceq $skill.id })
            $locked.Count | Should Be 1
            $locked[0].sourcePath | Should Be $skill.source.sourcePath
            $locked[0].targetPath | Should Be $skill.source.targetPath
        }
        foreach ($pin in @($pins.sources)) {
            $pin.requestedRef | Should Be 'main'
            $pin.resolvedCommit | Should Match '^[0-9a-f]{40}$'
            $lockedSource = @($lock.sources | Where-Object { $_.id -ceq $pin.id })
            $lockedSource.Count | Should Be 1
            $lockedSource[0].resolvedCommit | Should Be $pin.resolvedCommit
        }
    }

    # Scenario: Version 2 Catalog/Lock and version 3 manifests separate canonical source paths from runtime targets.
    # Purpose: Establish the executable contract before production pins migrate away from the legacy layout.
    It 'UnitT11_accepts_the_versioned_canonical_source_and_runtime_target_examples' {
        $catalogV2 = Import-SkillsCatalogJson -Path $script:CatalogV2Example -DocumentName 'Skills Catalog v2'
        $lockV2 = Import-SkillsCatalogJson -Path $script:LockV2Example -DocumentName 'Skills Catalog lock v2'
        $manifestV3 = Import-SkillsCatalogJson -Path $script:ManifestV3Example -DocumentName 'managed manifest v3'
        $userManifestV2 = Import-SkillsCatalogJson -Path $script:UserManifestV2Example -DocumentName 'user Skills managed manifest v2'

        { Assert-SkillsCatalogV2 -Catalog $catalogV2 } | Should Not Throw
        { Assert-SkillsCatalogLockV2 -Lock $lockV2 -Catalog $catalogV2 } | Should Not Throw
        { Assert-ManagedManifest -Manifest $manifestV3 } | Should Not Throw
        { Assert-UserSkillsManagedManifest -Manifest $userManifestV2 } | Should Not Throw

        @($catalogV2.skills)[0].source.sourcePath | Should Be 'skills/work-with-jira'
        @($catalogV2.skills)[0].source.targetPath | Should Be '.agents/skills/work-with-jira'
        @($lockV2.skills)[0].targetPath | Should Be '.agents/skills/work-with-jira'
        @($manifestV3.files)[0].sourcePath | Should Match '^skills/work-with-jira/'
        @($manifestV3.files)[0].targetPath | Should Match '^\.agents/skills/work-with-jira/'
        @($userManifestV2.files)[0].sourcePath | Should Match '^skills/work-with-jira/'
    }

    # Scenario: A v3 Catalog declares several bounded USER and project projections and its Lock binds their canonical digest.
    # Purpose: Establish reader-first v3 validation and deterministic target derivation without changing production v2 files.
    It 'UnitT11a_accepts_v3_catalog_lock_projections_and_independent_digest' {
        $catalog = Test-SkillsCatalogDocument -CatalogPath $script:CatalogV3Example
        $lock = Test-SkillsCatalogLockDocument -CatalogPath $script:CatalogV3Example -LockPath $script:LockV3Example

        $catalog.schemaVersion | Should Be 3
        $lock.schemaVersion | Should Be 3
        (Get-SkillsCatalogProjectionTargetPath -Catalog $catalog -SkillId 'work-with-jira' -ProjectionId 'user-agents') | Should Be '.agents/skills/work-with-jira'
        (Get-SkillsCatalogProjectionTargetPath -Catalog $catalog -SkillId 'work-with-jira' -ProjectionId 'user-claude') | Should Be '.claude/skills/work-with-jira'
        (Get-SkillsCatalogProjectionTargetPath -Catalog $catalog -SkillId 'work-with-jira' -ProjectionId 'project-agents') | Should Be '.agents/skills/work-with-jira'

        $byId = @{}
        foreach ($projection in @($catalog.projections)) { $byId[[string]$projection.id] = $projection }
        [string[]]$ids = @($byId.Keys)
        [System.Array]::Sort($ids,[System.StringComparer]::Ordinal)
        $canonical = (@($ids | ForEach-Object { $projection = $byId[$_]; "$($_)`t$([string]$projection.scope)`t$([string]$projection.root)`n" }) -join '')
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($canonical)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $expected = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        (Get-SkillsCatalogProjectionContractSha256 -Projections $catalog.projections) | Should Be $expected
        [string]$lock.projectionContractSha256 | Should Be $expected

        $manifest = Import-SkillsCatalogJson -Path $script:ManifestV3Example -DocumentName 'managed manifest v3'
        $manifest.catalogId = [string]$catalog.catalogId
        $manifest.lockSha256 = Get-TestRawSha256 -Path $script:LockV3Example
        $manifestPath = Write-TestJsonDocument -Document $manifest -Name 'v3-contract-manifest.json'
        $configuration = Import-SkillsCatalogJson -Path $script:ConfigurationExample -DocumentName 'sync configuration'
        $configuration.catalog.profiles = @('core')
        $configuration.catalog.includeSkills = @('work-with-jira')
        $configuration.catalog.excludeSkills = @()
        $configurationPath = Write-TestJsonDocument -Document $configuration -Name 'v3-contract-configuration.json'
        $result = Test-SkillsCatalogContract -CatalogPath $script:CatalogV3Example -LockPath $script:LockV3Example -ManifestPath $manifestPath -ConfigurationPath $configurationPath
        $result.SkillCount | Should Be 2
    }

    # Scenario: A v3 projection uses an ID outside the closed projection table.
    # Purpose: Prevent readers from accepting an arbitrary destination namespace.
    It 'UnitT11b_rejects_an_unknown_v3_projection_id' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        @($catalog.projections)[1].id = 'user-unknown'
        { Assert-SkillsCatalogV3 -Catalog $catalog } | Should Throw 'Unknown Skills Catalog projection ID: user-unknown'
    }

    # Scenario: A known v3 projection ID is paired with another projection's scope or root.
    # Purpose: Bind each projection identity to exactly one reviewed destination root.
    It 'UnitT11c_rejects_a_mismatched_v3_projection_tuple' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        @($catalog.projections)[1].root = '.copilot/skills'
        { Assert-SkillsCatalogV3 -Catalog $catalog } | Should Throw "Skills Catalog projection 'user-claude' must use scope 'user' and root '.claude/skills'."
    }

    # Scenario: A v3 Catalog declares the same projection ID twice.
    # Purpose: Keep projection target resolution unambiguous.
    It 'UnitT11d_rejects_a_duplicate_v3_projection_id' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $catalog.projections += $catalog.projections[0].PSObject.Copy()
        { Assert-SkillsCatalogV3 -Catalog $catalog } | Should Throw 'Duplicate Skills Catalog projection ID: user-agents'
    }

    # Scenario: A v3 Catalog omits the compatibility-preserving USER Agents projection.
    # Purpose: Preserve the current USER installation location in every v3 projection contract.
    It 'UnitT11e_requires_the_user_agents_v3_projection' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $catalog.projections = @($catalog.projections | Where-Object { $_.id -cne 'user-agents' })
        { Assert-SkillsCatalogV3 -Catalog $catalog } | Should Throw "Skills Catalog projections must include 'user-agents'."
    }

    # Scenario: A v3 Skill source attempts to retain the v2 targetPath property.
    # Purpose: Require all destinations to come from reviewed projections.
    It 'UnitT11f_rejects_targetPath_in_a_v3_skill_source' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        @($catalog.skills)[0].source | Add-Member -NotePropertyName targetPath -NotePropertyValue '.agents/skills/work-with-jira'
        { Assert-SkillsCatalogV3 -Catalog $catalog } | Should Throw "Skills Catalog Skill 'work-with-jira' source contains unsupported property 'targetPath'."
    }

    # Scenario: A v3 Skill source path does not equal skills/<stable-id>.
    # Purpose: Preserve canonical source package identity independently of projection roots.
    It 'UnitT11g_rejects_a_noncanonical_v3_skill_sourcePath' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        @($catalog.skills)[0].source.sourcePath = '.agents/skills/work-with-jira'
        { Assert-SkillsCatalogV3 -Catalog $catalog } | Should Throw "Skills Catalog v3 Skill 'work-with-jira' must use canonical source path 'skills/work-with-jira'."
    }

    # Scenario: A v3 Lock Skill attempts to retain a targetPath property.
    # Purpose: Prevent Lock data from reintroducing an arbitrary install destination.
    It 'UnitT11h_rejects_targetPath_in_a_v3_lock_skill' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        @($lock.skills)[0] | Add-Member -NotePropertyName targetPath -NotePropertyValue '.agents/skills/manage-task-handoff'
        { Assert-SkillsCatalogLockV3 -Lock $lock -Catalog $catalog } | Should Throw "Skills Catalog lock Skill contains unsupported property 'targetPath'."
    }

    # Scenario: A v3 Lock carries a projection digest for different projection bytes.
    # Purpose: Bind immutable content locks to the exact reviewed projection contract.
    It 'UnitT11i_rejects_a_mismatched_v3_projection_digest' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        $lock.projectionContractSha256 = '0' * 64
        $message = $null
        try { Assert-SkillsCatalogLockV3 -Lock $lock -Catalog $catalog }
        catch { $message = $_.Exception.Message }
        $message | Should Match '^Skills Catalog lock projectionContractSha256 does not match the Catalog projections:'
    }

    # Scenario: A v3 Catalog is paired with a v2 Lock.
    # Purpose: Reject cross-version interpretation before catalogSha256 can hide the semantic mismatch.
    It 'UnitT11j_rejects_a_v3_catalog_paired_with_a_v2_lock' {
        { Test-SkillsCatalogLockDocument -CatalogPath $script:CatalogV3Example -LockPath $script:LockV2Example } |
            Should Throw "Skills Catalog lock schemaVersion '2' does not match Skills Catalog schemaVersion '3'."
    }

    # Scenario: A v3 Catalog carries an undeclared top-level property.
    # Purpose: Keep parser behavior aligned with additionalProperties=false.
    It 'UnitT11k_rejects_an_unknown_v3_top_level_property' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $catalog | Add-Member -NotePropertyName targetRoot -NotePropertyValue '.agents/skills'
        { Assert-SkillsCatalogV3 -Catalog $catalog } | Should Throw "Skills Catalog contains unsupported property 'targetRoot'."
    }

    # Scenario: The reader receives the checked-in multi-projection USER manifest.
    # Purpose: Establish v3 reader support without changing the v1/v2 reconciler writer.
    It 'UnitT11l_accepts_the_user_manifest_v3_example' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Not Throw
        @($manifest.projections).Count | Should Be 2
        [string]$manifest.catalogId | Should Be ([string]$catalog.catalogId)
        [string]$manifest.lockSha256 | Should Be (Get-TestRawSha256 -Path $script:LockV3Example)
        [string]$manifest.projectionContractSha256 | Should Be (Get-SkillsCatalogProjectionContractSha256 -Projections $catalog.projections)
    }

    # Scenario: A v3 USER manifest is bound to the exact catalog projections and raw Lock bytes used by its installer.
    # Purpose: Keep document-only validation separate from the Catalog and Lock context required for safe installation.
    It 'UnitT11l1_binds_the_v3_user_manifest_to_the_catalog_and_lock' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        $lockSha256 = Get-TestRawSha256 -Path $script:LockV3Example

        { Assert-UserSkillsManagedManifestBinding -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 $lockSha256 -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ([string]$manifest.catalogCommit) } | Should Not Throw

        $repositoryMismatchMessage = $null
        try { Assert-UserSkillsManagedManifestBinding -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 $lockSha256 -ExpectedCatalogRepository 'https://github.com/example/other-catalog.git' -ExpectedCatalogCommit ([string]$manifest.catalogCommit) }
        catch { $repositoryMismatchMessage = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($repositoryMismatchMessage)) { throw 'Expected the catalog repository binding mismatch to fail.' }
        $repositoryMismatchMessage.Contains('catalog repository does not match') | Should Be $true

        $commitMismatchMessage = $null
        try { Assert-UserSkillsManagedManifestBinding -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 $lockSha256 -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ('f' * 40) }
        catch { $commitMismatchMessage = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($commitMismatchMessage)) { throw 'Expected the catalog commit binding mismatch to fail.' }
        $commitMismatchMessage.Contains('catalog commit does not match') | Should Be $true

        $projectionDigestMismatch = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $projectionDigestMismatch.projectionContractSha256 = '0' * 64
        { Assert-UserSkillsManagedManifestBinding -Manifest $projectionDigestMismatch -Catalog $catalog -Lock $lock -LockSha256 $lockSha256 -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ([string]$manifest.catalogCommit) } | Should Throw

        $lockDigestMismatch = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        { Assert-UserSkillsManagedManifestBinding -Manifest $lockDigestMismatch -Catalog $catalog -Lock $lock -LockSha256 ('0' * 64) -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ([string]$manifest.catalogCommit) } | Should Throw

        $unknownProjection = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $unknownProjection.projections[1] = 'user-copilot'
        { Assert-UserSkillsManagedManifestBinding -Manifest $unknownProjection -Catalog $catalog -Lock $lock -LockSha256 $lockSha256 -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ([string]$manifest.catalogCommit) } | Should Throw

        $unknownSkill = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        foreach ($file in @($unknownSkill.files | Where-Object { $_.skillId -ceq 'manage-task-handoff' })) {
            $file.skillId = 'unknown-skill'
            $file.sourcePath = 'skills/unknown-skill/SKILL.md'
            $file.targetPath = ([string]$file.targetPath).Replace('manage-task-handoff','unknown-skill')
        }
        { Assert-UserSkillsManagedManifestBinding -Manifest $unknownSkill -Catalog $catalog -Lock $lock -LockSha256 $lockSha256 -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ([string]$manifest.catalogCommit) } | Should Throw

        $sourceIdMismatch = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        foreach ($file in @($sourceIdMismatch.files | Where-Object { $_.skillId -ceq 'work-with-jira' })) { $file.sourceId = 'other-source' }
        { Assert-UserSkillsManagedManifestBinding -Manifest $sourceIdMismatch -Catalog $catalog -Lock $lock -LockSha256 $lockSha256 -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ([string]$manifest.catalogCommit) } | Should Throw
    }

    # Scenario: The binding digest uses exactly the same inventory bytes as source acquisition.
    # Purpose: Keep manifest-owned payload hashes interoperable with immutable lock generation.
    It 'UnitT11l2_cross_validates_v3_payload_hashes_with_source_acquisition' {
        Import-Module (Join-Path $script:RepositoryRoot 'scripts\skills-source-acquisition.psm1') -Force
        $repositoryRoot = Join-Path $TestDrive 'source-repository'
        $skillRoot = Join-Path $repositoryRoot 'skills\work-with-jira'
        New-Item -ItemType Directory -Path (Join-Path $skillRoot 'references') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'),'# Skill',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $skillRoot 'references\one.md'),'one',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $skillRoot 'references\two.md'),'two',[Text.UTF8Encoding]::new($false))
        $acquisitionHash = Get-SkillInventorySha256 -RepositoryRoot $repositoryRoot -SkillRoot $skillRoot

        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        $hashByRelativePath = @{}
        foreach ($relativePath in @('SKILL.md','references/one.md','references/two.md')) {
            $hashByRelativePath[$relativePath] = Get-TestRawSha256 -Path (Join-Path $skillRoot $relativePath.Replace('/','\'))
        }
        $workFiles = @($manifest.files | Where-Object { $_.skillId -ceq 'work-with-jira' })
        foreach ($file in $workFiles) { $file.sha256 = $hashByRelativePath['SKILL.md'] }
        foreach ($projectionId in @($manifest.projections)) {
            $template = @($workFiles | Where-Object { $_.projectionId -ceq $projectionId })[0]
            foreach ($relativePath in @('references/one.md','references/two.md')) {
                $entry = $template.PSObject.Copy()
                $entry.sourcePath = "skills/work-with-jira/$relativePath"
                $entry.targetPath = ([string]$template.targetPath).Replace('SKILL.md',$relativePath)
                $entry.sha256 = $hashByRelativePath[$relativePath]
                $manifest.files += $entry
            }
        }
        @($lock.skills | Where-Object { $_.id -ceq 'work-with-jira' })[0].contentSha256 = $acquisitionHash

        { Assert-UserSkillsManagedManifestBinding -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedCatalogRepository ([string]$manifest.catalogRepository) -ExpectedCatalogCommit ([string]$manifest.catalogCommit) } | Should Not Throw
    }

    # Scenario: Projection parity alone is insufficient if matching payload hashes are forged.
    # Purpose: Bind every installed payload inventory to the immutable content hash in the Lock.
    It 'UnitT11l3_rejects_a_v3_manifest_with_parity_preserving_payload_hash_changes' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
        $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        foreach ($file in @($manifest.files | Where-Object { $_.skillId -ceq 'work-with-jira' -and $_.sourcePath -ceq 'skills/work-with-jira/SKILL.md' })) { $file.sha256 = '0' * 64 }
        Assert-UserManifestBindingFailure -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedMessage 'content hash does not match the lock'
    }

    # Scenario: A manifest provenance field differs from the selected immutable source.
    # Purpose: Prevent otherwise valid payload bytes from being attributed to another source revision.
    It 'UnitT11l4_rejects_a_v3_manifest_with_mismatched_sourceCommit' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'; $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'; $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        foreach ($file in @($manifest.files | Where-Object { $_.skillId -ceq 'work-with-jira' })) { $file.sourceCommit = 'f' * 40 }
        Assert-UserManifestBindingFailure -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedMessage 'source provenance does not match the Lock'
    }

    It 'UnitT11l5_rejects_a_v3_manifest_with_mismatched_sourceRepository' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'; $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'; $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        foreach ($file in @($manifest.files | Where-Object { $_.skillId -ceq 'work-with-jira' })) { $file.sourceRepository = 'https://github.com/example/other.git' }
        Assert-UserManifestBindingFailure -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedMessage 'source provenance does not match the Lock'
    }

    It 'UnitT11l6_rejects_a_v3_manifest_with_mismatched_sourceRef' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'; $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'; $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        foreach ($file in @($manifest.files | Where-Object { $_.skillId -ceq 'work-with-jira' })) { $file.sourceRef = 'v2.0.0' }
        Assert-UserManifestBindingFailure -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedMessage 'source provenance does not match the Lock'
    }

    It 'UnitT11l7_rejects_a_v3_manifest_with_mismatched_sourceVersion' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'; $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'; $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        foreach ($file in @($manifest.files | Where-Object { $_.skillId -ceq 'work-with-jira' })) { $file.sourceVersion = '2.0.0' }
        Assert-UserManifestBindingFailure -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedMessage 'source provenance does not match the Lock'
    }

    It 'UnitT11l8_rejects_a_v3_manifest_with_mismatched_catalogId' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'; $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'; $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        $manifest.catalogId = 'other-catalog'
        Assert-UserManifestBindingFailure -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedMessage 'catalogId does not match the Catalog and Lock'
    }

    It 'UnitT11l9_rejects_a_v3_manifest_with_an_unlocked_payload_file' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'; $catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'; $lock = Import-SkillsCatalogJson -Path $script:LockV3Example -DocumentName 'Skills Catalog lock v3'
        foreach ($projectionId in @($manifest.projections)) {
            $template = @($manifest.files | Where-Object { $_.skillId -ceq 'work-with-jira' -and $_.projectionId -ceq $projectionId -and $_.sourcePath -ceq 'skills/work-with-jira/SKILL.md' })[0]
            $entry = $template.PSObject.Copy(); $entry.sourcePath = 'skills/work-with-jira/extra.md'; $entry.targetPath = ([string]$template.targetPath).Replace('SKILL.md','extra.md'); $entry.sha256 = '4' * 64; $manifest.files += $entry
        }
        Assert-UserManifestBindingFailure -Manifest $manifest -Catalog $catalog -Lock $lock -LockSha256 (Get-TestRawSha256 -Path $script:LockV3Example) -ExpectedMessage 'content hash does not match the lock'
    }

    # Scenario: A versioned USER manifest uses traversal syntax in source or target ownership paths.
    # Purpose: Reject unsafe paths before canonical mapping rules can mistake them for a Skill-owned payload.
    It 'UnitT11la_rejects_unsafe_v2_and_v3_user_manifest_paths' {
        $v2Manifest = Import-SkillsCatalogJson -Path $script:UserManifestV2Example -DocumentName 'user Skills managed manifest v2'
        @($v2Manifest.files)[0].sourcePath = 'skills/work-with-jira/../secret'
        $v2Error = $null
        try { Assert-UserSkillsManagedManifest -Manifest $v2Manifest }
        catch { $v2Error = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($v2Error)) { throw 'Expected the v2 manifest to reject the unsafe source path.' }
        $v2Error.Contains('unsafe') | Should Be $true
        $v2Error.Contains('work-with-jira') | Should Be $true

        $v3Manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        @($v3Manifest.files)[0].sourcePath = 'skills/work-with-jira/../secret'
        $v3SourceError = $null
        try { Assert-UserSkillsManagedManifest -Manifest $v3Manifest }
        catch { $v3SourceError = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($v3SourceError)) { throw 'Expected the v3 manifest to reject the unsafe source path.' }
        $v3SourceError.Contains('unsafe') | Should Be $true
        $v3SourceError.Contains('work-with-jira') | Should Be $true

        $v3TargetManifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        @($v3TargetManifest.files)[0].targetPath = '.agents/skills/work-with-jira/../secret'
        $v3TargetError = $null
        try { Assert-UserSkillsManagedManifest -Manifest $v3TargetManifest }
        catch { $v3TargetError = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($v3TargetError)) { throw 'Expected the v3 manifest to reject the unsafe target path.' }
        $v3TargetError.Contains('unsafe') | Should Be $true
        $v3TargetError.Contains('work-with-jira') | Should Be $true
    }

    # Scenario: An ordinary payload changes its filename between the canonical source package and a USER target.
    # Purpose: Preserve per-file source provenance rather than permitting arbitrary source-to-target remapping.
    It 'UnitT11lb_rejects_mismatched_v2_and_v3_user_manifest_payload_paths' {
        $v2Manifest = Import-SkillsCatalogJson -Path $script:UserManifestV2Example -DocumentName 'user Skills managed manifest v2'
        @($v2Manifest.files)[0].sourcePath = 'skills/work-with-jira/not-the-target.md'
        $v2Error = $null
        try { Assert-UserSkillsManagedManifest -Manifest $v2Manifest } catch { $v2Error = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($v2Error) -or -not $v2Error.Contains('source and target paths must match')) { throw 'Expected the v2 manifest to reject mismatched payload paths.' }

        $v3Manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        @($v3Manifest.files)[0].sourcePath = 'skills/work-with-jira/not-the-target.md'
        $v3Error = $null
        try { Assert-UserSkillsManagedManifest -Manifest $v3Manifest } catch { $v3Error = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($v3Error) -or -not $v3Error.Contains('source and target paths must match')) { throw 'Expected the v3 manifest to reject mismatched payload paths.' }
    }

    # Scenario: A USER manifest projection ID is not in the fixed projection table.
    # Purpose: Reject invented USER destination namespaces.
    It 'UnitT11m_rejects_an_unknown_user_manifest_projection' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest.projections[1] = 'user-unknown'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A USER manifest selects a known project-scoped projection.
    # Purpose: Keep USER ownership separate from project projection roots.
    It 'UnitT11n_rejects_a_non_user_manifest_projection' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest.projections[1] = 'project-agents'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A USER manifest lists a projection twice.
    # Purpose: Keep projection parity comparison unambiguous.
    It 'UnitT11o_rejects_duplicate_user_manifest_projections' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest.projections = @('user-agents','user-agents')
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A file names a valid USER projection omitted from the manifest projection set.
    # Purpose: Bind every owned path to an explicitly selected projection.
    It 'UnitT11p_rejects_a_file_projection_not_listed_by_the_manifest' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest.projections = @('user-agents')
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A file target uses another projection's root.
    # Purpose: Bind projectionId to its fixed target root and Skill namespace.
    It 'UnitT11q_rejects_a_target_outside_its_projection_root' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        @($manifest.files | Where-Object { $_.projectionId -ceq 'user-claude' })[0].targetPath = '.agents/skills/work-with-jira/SKILL.md'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: Two entries claim target paths that differ only by case.
    # Purpose: Preserve the v2 duplicate-path protection for Windows USER roots.
    It 'UnitT11r_rejects_duplicate_user_manifest_target_paths' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $duplicate = $manifest.files[0].PSObject.Copy()
        $duplicate.targetPath = '.agents/skills/work-with-jira/skill.md'
        $manifest.files += $duplicate
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: One projection omits a relative payload file present in the baseline projection.
    # Purpose: Require complete per-Skill projection parity.
    It 'UnitT11s_rejects_projection_parity_with_a_missing_file' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest.files = @($manifest.files | Where-Object { $_.targetPath -cne '.claude/skills/work-with-jira/.ai-instructions-licenses/source/THIRD_PARTY_LICENSES.md' })
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: Corresponding projection files contain different content hashes.
    # Purpose: Prevent projection destinations from silently diverging.
    It 'UnitT11t_rejects_projection_parity_with_a_different_hash' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        @($manifest.files | Where-Object { $_.targetPath -ceq '.claude/skills/work-with-jira/SKILL.md' })[0].sha256 = '9' * 64
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: Corresponding projection files differ only by the case of their relative paths.
    # Purpose: Keep parity portable across case-sensitive and case-insensitive filesystems.
    It 'UnitT11t1_rejects_projection_parity_with_a_case_only_path_difference' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $file = @($manifest.files | Where-Object { $_.targetPath -ceq '.claude/skills/work-with-jira/SKILL.md' })[0]
        $file.sourcePath = 'skills/work-with-jira/skill.md'
        $file.targetPath = '.claude/skills/work-with-jira/skill.md'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A Skill appears in only one selected projection.
    # Purpose: Require every selected projection to contain every managed Skill.
    It 'UnitT11u_rejects_a_skill_missing_from_one_projection' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest.files = @($manifest.files | Where-Object { -not ($_.skillId -ceq 'manage-task-handoff' -and $_.projectionId -ceq 'user-claude') })
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: Corresponding files for one Skill disagree on immutable source provenance.
    # Purpose: Prevent projections from claiming different source identities for the same Skill.
    It 'UnitT11v_rejects_inconsistent_source_fields_for_one_skill' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        @($manifest.files | Where-Object { $_.targetPath -ceq '.claude/skills/work-with-jira/SKILL.md' })[0].sourceRef = 'v2.0.0'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A license delivery entry is placed under another projection root.
    # Purpose: Keep license ownership inside the file's declared projection namespace.
    It 'UnitT11w_rejects_a_license_path_outside_its_projection_root' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        @($manifest.files | Where-Object { $_.targetPath -cmatch '^\.claude/.+THIRD_PARTY_LICENSES' })[0].targetPath = '.agents/skills/work-with-jira/.ai-instructions-licenses/source/THIRD_PARTY_LICENSES.md'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A USER manifest uses generation zero.
    # Purpose: Reserve positive generations for persisted projection state.
    It 'UnitT11x_rejects_generation_zero' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest.generation = 0
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A USER manifest carries an undeclared top-level property.
    # Purpose: Keep parser behavior aligned with additionalProperties=false.
    It 'UnitT11y_rejects_an_unknown_user_manifest_top_level_property' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV3Example -DocumentName 'user Skills managed manifest v3'
        $manifest | Add-Member -NotePropertyName targetRoot -NotePropertyValue '.agents/skills'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A user Skills v2 manifest carries source-root licensing documents and its generated delivery receipt.
    # Purpose: Keep license provenance explicit without weakening canonical source validation for ordinary Skill files.
    It 'UnitT14_accepts_v2_license_delivery_provenance_and_rejects_it_on_payload_files' {
        $manifest = Import-SkillsCatalogJson -Path $script:UserManifestV2Example -DocumentName 'user Skills managed manifest v2'
        $base = @($manifest.files)[0]
        $newEntry = {
            param([string]$SourcePath,[string]$TargetPath)
            [pscustomobject][ordered]@{
                skillId = [string]$base.skillId
                sourceId = [string]$base.sourceId
                sourceRepository = [string]$base.sourceRepository
                sourceRef = [string]$base.sourceRef
                sourceCommit = [string]$base.sourceCommit
                sourceVersion = [string]$base.sourceVersion
                sourcePath = $SourcePath
                targetPath = $TargetPath
                sha256 = ('2' * 64)
            }
        }
        $licenseEntry = & $newEntry 'LICENSE' '.agents/skills/work-with-jira/.ai-instructions-licenses/source/LICENSE'
        $receiptEntry = & $newEntry '.ai-instructions-generated/delivery.json' '.agents/skills/work-with-jira/.ai-instructions-licenses/delivery.json'
        $thirdPartyEntry = & $newEntry 'THIRD_PARTY_LICENSES.md' '.agents/skills/work-with-jira/.ai-instructions-licenses/source/THIRD_PARTY_LICENSES.md'
        $manifest.files = @($base,$licenseEntry,$thirdPartyEntry,$receiptEntry)

        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Not Throw

        $thirdPartyEntry.sourcePath = 'THIRD_PARTY_LICENSES.py'
        $thirdPartyEntry.targetPath = '.agents/skills/work-with-jira/.ai-instructions-licenses/source/THIRD_PARTY_LICENSES.py'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
        $thirdPartyEntry.sourcePath = 'THIRD_PARTY_LICENSES.md'
        $thirdPartyEntry.targetPath = '.agents/skills/work-with-jira/.ai-instructions-licenses/source/THIRD_PARTY_LICENSES.md'

        $licenseEntry.targetPath = '.agents/skills/work-with-jira/references/LICENSE'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw

        $licenseEntry.targetPath = '.agents/skills/work-with-jira/.ai-instructions-licenses/source/LICENSE'
        $receiptEntry.sourcePath = 'LICENSE'
        { Assert-UserSkillsManagedManifest -Manifest $manifest } | Should Throw
    }

    # Scenario: A versioned document claims a schema or source/target mapping outside the published contract.
    # Purpose: Fail closed rather than silently interpreting a future schema as the current one.
    It 'UnitT12_rejects_unknown_versions_and_noncanonical_versioned_mappings' {
        $catalogV2 = Import-SkillsCatalogJson -Path $script:CatalogV2Example -DocumentName 'Skills Catalog v2'
        $catalogV2.schemaVersion = 99
        { Assert-SkillsCatalogV2 -Catalog $catalogV2 } | Should Throw

        $manifestV3 = Import-SkillsCatalogJson -Path $script:ManifestV3Example -DocumentName 'managed manifest v3'
        $manifestV3.schemaVersion = 99
        { Assert-ManagedManifest -Manifest $manifestV3 } | Should Throw

        $canonicalManifest = Import-SkillsCatalogJson -Path $script:ManifestV3Example -DocumentName 'managed manifest v3'
        @($canonicalManifest.files)[0].sourcePath = '.agents/skills/work-with-jira/SKILL.md'
        { Assert-ManagedManifestV3 -Manifest $canonicalManifest } | Should Throw
    }

    # Scenario: Existing production manifest v2 remains readable while canonical source paths require manifest v3.
    # Purpose: Preserve old ownership evidence and prevent a global path rewrite from changing legacy semantics.
    It 'UnitT13_preserves_legacy_manifest_read_semantics_during_the_versioned_migration' {
        $legacyManifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest v2'
        { Assert-ManagedManifest -Manifest $legacyManifest } | Should Not Throw

        $legacyManifest.files = @($legacyManifest.files)
        $legacyManifest.files | Where-Object { $_.artifactType -eq 'skill' } | ForEach-Object {
            $_.sourcePath = 'skills/work-with-jira/SKILL.md'
        }
        { Assert-ManagedManifestV2 -Manifest $legacyManifest } | Should Throw
    }

    # Scenario: A Skill is renamed while its immutable old ID remains as a removed tombstone.
    # Purpose: Prove that profile resolution can migrate an alias without reusing or losing the old identity.
    It 'UnitT15_accepts_a_rename_with_a_removed_tombstone_and_replacement_alias' {
        $catalog = Test-SkillsCatalogDocument -CatalogPath (Join-Path $script:FixtureRoot 'valid-rename-removal.json')
        $oldSkill = @($catalog.skills | Where-Object { $_.id -eq 'old-skill' })[0]
        $newSkill = @($catalog.skills | Where-Object { $_.id -eq 'new-skill' })[0]

        $oldSkill.lifecycle.status | Should Be 'removed'
        $oldSkill.lifecycle.replacementId | Should Be 'new-skill'
        @($newSkill.lifecycle.aliases)[0] | Should Be 'old-skill'
    }

    # Scenario: A catalog uses a schema version that this implementation does not understand.
    # Purpose: Prevent newer or incompatible metadata from being interpreted with older rules.
    It 'UnitT20_rejects_an_unknown_catalog_schema_version' {
        $errorMessage = Get-ContractValidationError -CatalogPath (Join-Path $script:FixtureRoot 'unknown-schema.json')

        $errorMessage | Should Match 'Unsupported Skills Catalog schemaVersion'
    }

    # Scenario: Two catalog entries claim the same stable Skill ID.
    # Purpose: Prevent first-wins or last-wins resolution from silently selecting the wrong Skill.
    It 'UnitT30_rejects_duplicate_stable_skill_ids' {
        $errorMessage = Get-ContractValidationError -CatalogPath (Join-Path $script:FixtureRoot 'duplicate-stable-id.json')

        $errorMessage | Should Match 'Duplicate stable Skill ID'
    }

    # Scenario: A catalog source path escapes or bypasses the flat .agents/skills layout.
    # Purpose: Protect target repositories from traversal and unexpected fan-out locations.
    It 'UnitT40_rejects_unsafe_or_non_flat_skill_paths' {
        $errorMessage = Get-ContractValidationError -CatalogPath (Join-Path $script:FixtureRoot 'unsafe-path.json')

        $errorMessage | Should Match 'Unsafe Skill source path'
    }

    # Scenario: A dependency declares a type outside the stable hard, conditional, and recommended set.
    # Purpose: Ensure dependency semantics never degrade to an unvalidated default.
    It 'UnitT50_rejects_an_unknown_dependency_type' {
        $errorMessage = Get-ContractValidationError -CatalogPath (Join-Path $script:FixtureRoot 'invalid-dependency.json')

        $errorMessage | Should Match 'Unsupported dependency type'
    }

    # Scenario: Capability declarations violate the stable kind, ID, or state vocabulary.
    # Purpose: Keep the executable validator aligned with the capability object in the JSON Schema.
    It 'UnitT52_rejects_invalid_required_and_alternative_capability_declarations' {
        $cases = @(
            @{ Name = 'required-kind'; Collection = 'requiredCapabilities'; Index = 0; Property = 'kind'; Value = 'COMMAND'; Expected = 'Unsupported .* compatibility requirement kind' },
            @{ Name = 'required-id'; Collection = 'requiredCapabilities'; Index = 0; Property = 'id'; Value = 'Git Command'; Expected = 'compatibility requirement id must be lowercase kebab-case' },
            @{ Name = 'required-state'; Collection = 'requiredCapabilities'; Index = 0; Property = 'state'; Value = 'AVAILABLE'; Expected = 'Unsupported .* compatibility requirement state' },
            @{ Name = 'alternative-kind'; Collection = 'anyOfCapabilities'; Index = 0; Property = 'kind'; Value = 'CONNECTOR'; Expected = 'Unsupported .* compatibility alternative kind' }
        )

        foreach ($case in $cases) {
            $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
            $skill = @($catalog.skills | Where-Object { $_.id -eq 'review-bitbucket-pull-request' })[0]
            if ($case.Collection -eq 'requiredCapabilities') {
                $capability = @($skill.compatibility.requiredCapabilities)[$case.Index]
            }
            else {
                $capability = @(@($skill.compatibility.anyOfCapabilities)[0])[$case.Index]
            }
            $capability.PSObject.Properties[$case.Property].Value = $case.Value
            $catalogPath = Write-TestJsonDocument -Document $catalog -Name "$($case.Name).json"

            $errorMessage = Get-ContractValidationError -CatalogPath $catalogPath

            $errorMessage | Should Match $case.Expected
        }
    }

    # Scenario: A conditional dependency uses an unstable capability ID, unknown operator, or missing fallback explanation.
    # Purpose: Ensure conditional dependency behavior cannot bypass the JSON Schema contract.
    It 'UnitT54_rejects_invalid_conditional_dependency_contracts' {
        $cases = @(
            @{ Name = 'condition-capability'; Target = 'condition'; Property = 'capability'; Value = 'Jira Cloud API'; Expected = 'condition capability must be lowercase kebab-case' },
            @{ Name = 'condition-operator'; Target = 'condition'; Property = 'operator'; Value = 'MISSING'; Expected = 'Unsupported conditional dependency operator' },
            @{ Name = 'fallback-capability'; Target = 'fallback'; Property = 'capability'; Value = 'Jira Cloud Connector'; Expected = 'fallback capability must be lowercase kebab-case' },
            @{ Name = 'fallback-description'; Target = 'fallback'; Property = 'description'; Value = ''; Expected = 'fallback description must be a non-empty string' }
        )

        foreach ($case in $cases) {
            $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
            $skill = @($catalog.skills | Where-Object { $_.id -eq 'work-with-jira' })[0]
            $dependency = @($skill.dependencies | Where-Object { $_.type -eq 'conditional' })[0]
            $target = $dependency.PSObject.Properties[$case.Target].Value
            $target.PSObject.Properties[$case.Property].Value = $case.Value
            $catalogPath = Write-TestJsonDocument -Document $catalog -Name "$($case.Name).json"

            $errorMessage = Get-ContractValidationError -CatalogPath $catalogPath

            $errorMessage | Should Match $case.Expected
        }
    }

    # Scenario: Conditional IDs are absent, duplicated, or split across unrelated compatibility alternatives.
    # Purpose: Give selection one authoritative kind/state tuple for both the condition and fallback evidence.
    It 'UnitT55_requires_unique_conditional_capability_contracts_in_one_alternative_set' {
        $cases = @(
            @{
                Name = 'undeclared-condition'
                Expected = 'must declare exactly one compatibility requirement with its required kind and state'
                Apply = {
                    param($skill,$dependency)
                    $dependency.condition.capability = 'undeclared-jira-api'
                }
            },
            @{
                Name = 'duplicate-fallback'
                Expected = 'must declare exactly one compatibility requirement with its required kind and state'
                Apply = {
                    param($skill,$dependency)
                    $alternativeSet = @($skill.compatibility.anyOfCapabilities)[0]
                    $skill.compatibility.anyOfCapabilities[0] = @($alternativeSet) + @(
                        [pscustomobject]@{ kind='connector'; id='jira-cloud-connector'; state='configured' }
                    )
                }
            },
            @{
                Name = 'split-alternatives'
                Expected = 'must be declared together in exactly one compatibility anyOfCapabilities set'
                Apply = {
                    param($skill,$dependency)
                    $alternativeSet = @($skill.compatibility.anyOfCapabilities)[0]
                    $skill.compatibility.anyOfCapabilities = @(
                        [object[]]@($alternativeSet[0]),
                        [object[]]@($alternativeSet[1])
                    )
                }
            }
        )

        foreach ($case in $cases) {
            $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
            $skill = @($catalog.skills | Where-Object { $_.id -eq 'work-with-jira' })[0]
            $dependency = @($skill.dependencies | Where-Object { $_.type -eq 'conditional' })[0]
            & $case.Apply $skill $dependency
            $catalogPath = Write-TestJsonDocument -Document $catalog -Name "$($case.Name).json"

            (Get-ContractValidationError -CatalogPath $catalogPath) | Should Match $case.Expected
        }
    }

    # Scenario: Catalog, lock, and manifest enum values differ from the schema only by letter casing.
    # Purpose: Keep PowerShell validation as case-sensitive as the JSON Schema contract.
    It 'UnitT56_rejects_case_variant_enum_values_across_catalog_lock_and_manifest' {
        $cases = @(
            @{
                Name = 'compatibility-platform'
                Target = 'Catalog'
                Expected = 'Unsupported .* compatibility platform'
                Apply = {
                    param($document)
                    @($document.skills)[0].compatibility.platforms = @('Any')
                }
            },
            @{
                Name = 'dependency-type'
                Target = 'Catalog'
                Expected = 'Unsupported dependency type'
                Apply = {
                    param($document)
                    $skill = @($document.skills | Where-Object { $_.id -eq 'work-with-jira' })[0]
                    $dependency = @($skill.dependencies | Where-Object { $_.type -eq 'conditional' })[0]
                    $dependency.type = 'Conditional'
                }
            },
            @{
                Name = 'lifecycle-status'
                Target = 'Catalog'
                Expected = 'Unsupported lifecycle status'
                Apply = {
                    param($document)
                    $skill = @($document.skills | Where-Object { $_.lifecycle.status -eq 'active' })[0]
                    $skill.lifecycle.status = 'Active'
                }
            },
            @{
                Name = 'requested-ref-type'
                Target = 'Lock'
                Expected = 'Unsupported requestedRefType'
                Apply = {
                    param($document)
                    @($document.sources)[0].requestedRefType = 'Tag'
                }
            },
            @{
                Name = 'resolved-commit-uppercase'
                Target = 'Lock'
                Expected = 'resolvedCommit must be a full 40-character commit SHA'
                Apply = {
                    param($document)
                    @($document.sources)[0].resolvedCommit = ('A' * 40)
                }
            },
            @{
                Name = 'archive-hash-uppercase'
                Target = 'Lock'
                Expected = 'archiveSha256 must be a lowercase 64-character SHA-256 hash'
                Apply = {
                    param($document)
                    @($document.sources)[0].archiveSha256 = ('A' * 64)
                }
            },
            @{
                Name = 'content-hash-uppercase'
                Target = 'Lock'
                Expected = 'contentSha256 must be a lowercase 64-character SHA-256 hash'
                Apply = {
                    param($document)
                    @($document.skills)[0].contentSha256 = ('A' * 64)
                }
            },
            @{
                Name = 'artifact-type'
                Target = 'Manifest'
                Expected = 'Unsupported managed manifest artifactType'
                Apply = {
                    param($document)
                    @($document.files)[0].artifactType = 'Instruction'
                }
            },
            @{
                Name = 'manifest-commit-uppercase'
                Target = 'Manifest'
                Expected = 'sourceCommit must be a full 40-character commit SHA'
                Apply = {
                    param($document)
                    @($document.files)[0].sourceCommit = ('A' * 40)
                }
            },
            @{
                Name = 'manifest-hash-uppercase'
                Target = 'Manifest'
                Expected = 'sha256 must be a lowercase 64-character SHA-256 hash'
                Apply = {
                    param($document)
                    @($document.files)[0].sha256 = ('A' * 64)
                }
            }
        )

        foreach ($case in $cases) {
            # Given
            $catalogPath = $script:CatalogExample
            $lockPath = $script:LockExample
            $manifestPath = $script:ManifestExample
            switch ($case.Target) {
                'Catalog' {
                    $document = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
                    & $case.Apply $document
                    $catalogPath = Write-TestJsonDocument -Document $document -Name "$($case.Name).json"
                }
                'Lock' {
                    $document = Import-SkillsCatalogJson -Path $script:LockExample -DocumentName 'Skills Catalog lock'
                    & $case.Apply $document
                    $lockPath = Write-TestJsonDocument -Document $document -Name "$($case.Name).json"
                }
                'Manifest' {
                    $document = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
                    & $case.Apply $document
                    $manifestPath = Write-TestJsonDocument -Document $document -Name "$($case.Name).json"
                }
            }

            # When
            $errorMessage = Get-ContractValidationError `
                -CatalogPath $catalogPath `
                -LockPath $lockPath `
                -ManifestPath $manifestPath

            # Then
            $errorMessage | Should Match $case.Expected
        }
    }

    # Scenario: A managed manifest uses a string schema version or carries fields outside the published v2 schema.
    # Purpose: Keep executable ownership validation from accepting documents rejected by portable JSON Schema tooling.
    It 'UnitT57_rejects_schema_type_and_unknown_managed_manifest_properties' {
        $cases = @(
            @{
                Name = 'manifest-schema-string'
                Expected = 'schemaVersion.*integer'
                Apply = { param($document) $document.schemaVersion = '2' }
            },
            @{
                Name = 'manifest-top-level-property'
                Expected = 'unsupported property.*unexpected'
                Apply = { param($document) $document | Add-Member -NotePropertyName unexpected -NotePropertyValue $true }
            },
            @{
                Name = 'manifest-file-property'
                Expected = 'file.*unsupported property.*unexpected'
                Apply = { param($document) @($document.files)[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true }
            }
        )

        foreach ($case in $cases) {
            $manifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
            & $case.Apply $manifest
            $manifestPath = Write-TestJsonDocument -Document $manifest -Name "$($case.Name).json"

            $errorMessage = Get-ContractValidationError -CatalogPath $script:CatalogExample -ManifestPath $manifestPath

            $errorMessage | Should Match $case.Expected
        }
    }

    # Scenario: A legacy schema-v1 manifest is used as migration or pollution-cleanup ownership evidence.
    # Purpose: Accept only the exact historical shape and reject unknown fields before any ignore or index mutation.
    It 'UnitT58_validates_the_exact_legacy_managed_manifest_v1_shape' {
        $legacyManifest = [pscustomobject][ordered]@{
            schemaVersion = 1
            sourceRepository = 'https://github.com/example/catalog.git'
            sourceRef = 'main'
            files = @([pscustomobject][ordered]@{
                sourcePath = '.codex/AGENTS.en.md'
                targetPath = 'AGENTS.md'
                sha256 = ('a' * 64)
            })
        }

        Assert-LegacyManagedManifestV1 -Manifest $legacyManifest

        $legacyManifest.files[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        try { Assert-LegacyManagedManifestV1 -Manifest $legacyManifest; $errorMessage = $null }
        catch { $errorMessage = $_.Exception.Message }
        $errorMessage | Should Match 'legacy managed manifest file.*unsupported property.*unexpected'
    }

    # Scenario: A schema-v2 manifest uses a singleton array where sha256 must be a string.
    # Purpose: Keep executable ownership checks aligned with the portable schema instead of relying on coercion.
    It 'UnitT59_rejects_singleton_arrays_in_manifest_hash_fields' {
        $manifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
        @($manifest.files)[0].sha256 = @(('a' * 64))
        $manifestPath = Write-TestJsonDocument -Document $manifest -Name 'manifest-array-hash.json'

        (Get-ContractValidationError -CatalogPath $script:CatalogExample -ManifestPath $manifestPath) |
            Should Match 'sha256.*string'
    }

    # Scenario: A manifest labels a flat Skill path as an instruction to bypass the Skill artifact/path relationship.
    # Purpose: Prevent forged ownership evidence from overwriting or staging deletion of a Repository-owned Skill.
    It 'UnitT60_rejects_instruction_artifacts_that_claim_skill_paths' {
        $manifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
        $skillFile = @($manifest.files | Where-Object { $_.artifactType -eq 'skill' })[0]
        $skillFile.artifactType = 'instruction'
        $manifestPath = Write-TestJsonDocument -Document $manifest -Name 'manifest-instruction-skill-path.json'

        (Get-ContractValidationError -CatalogPath $script:CatalogExample -ManifestPath $manifestPath) |
            Should Match 'Managed instruction.*must not claim a .agents/skills path'

        $schema = Import-SkillsCatalogJson `
            -Path (Join-Path $script:RepositoryRoot 'catalog\schemas\managed-manifest-v2.schema.json') `
            -DocumentName 'managed manifest schema'
        $typeRule = @($schema.properties.files.items.allOf | Where-Object {
            [string]$_.if.properties.artifactType.const -ceq 'skill'
        })
        $typeRule.Count | Should Be 1
        [string]$typeRule[0].then.properties.targetPath.pattern | Should Be '^\.agents/skills/'
        [string]$typeRule[0].else.properties.targetPath.not.pattern | Should Be '^\.agents/skills/'
    }

    # Scenario: A repository-relative path contains a control character or a segment that can normalize ambiguously.
    # Purpose: Keep the portable schemas and executable manifest validators on the same traversal-safe path grammar.
    It 'UnitT65_keeps_manifest_repository_path_schema_and_parser_behavior_aligned' {
        $managedSchema = Import-SkillsCatalogJson `
            -Path (Join-Path $script:RepositoryRoot 'catalog\schemas\managed-manifest-v2.schema.json') `
            -DocumentName 'managed manifest schema'
        $userSchema = Import-SkillsCatalogJson `
            -Path (Join-Path $script:RepositoryRoot 'catalog\schemas\user-skills-managed-manifest-v1.schema.json') `
            -DocumentName 'user Skills managed manifest schema'
        $userV3Schema = Import-SkillsCatalogJson `
            -Path (Join-Path $script:RepositoryRoot 'catalog\schemas\user-skills-managed-manifest-v3.schema.json') `
            -DocumentName 'user Skills managed manifest v3 schema'
        $managedPattern = [string]$managedSchema.'$defs'.repositoryPath.pattern
        $userPattern = [string]$userSchema.'$defs'.repositoryPath.pattern
        $userV3Pattern = [string]$userV3Schema.'$defs'.repositoryPath.pattern
        $userV3Pattern | Should Be $userPattern
        $catalogV3Schema = Import-SkillsCatalogJson `
            -Path (Join-Path $script:RepositoryRoot 'catalog\schemas\skills-catalog-v3.schema.json') `
            -DocumentName 'Skills Catalog v3 schema'
        $lockV3Schema = Import-SkillsCatalogJson `
            -Path (Join-Path $script:RepositoryRoot 'catalog\schemas\skills-catalog-lock-v3.schema.json') `
            -DocumentName 'Skills Catalog lock v3 schema'
        $catalogV3SourcePattern = [string]$catalogV3Schema.'$defs'.source.properties.sourcePath.pattern
        $lockV3SourcePattern = [string]$lockV3Schema.'$defs'.skill.properties.sourcePath.pattern
        $catalogV3SourcePattern | Should Be $lockV3SourcePattern
        ('skills/work-with-jira' -cmatch $catalogV3SourcePattern) | Should Be $true
        ('.agents/skills/work-with-jira' -cmatch $catalogV3SourcePattern) | Should Be $false
        ('skills/Work-with-jira' -cmatch $catalogV3SourcePattern) | Should Be $false
        foreach ($v3SourceCase in @(
            @{ Path='skills/work-with-jira'; Valid=$true },
            @{ Path='.agents/skills/work-with-jira'; Valid=$false },
            @{ Path='skills/Work-with-jira'; Valid=$false }
        )) {
            $v3Catalog = Import-SkillsCatalogJson -Path $script:CatalogV3Example -DocumentName 'Skills Catalog v3'
            @($v3Catalog.skills)[0].source.sourcePath = [string]$v3SourceCase.Path
            $v3Error = $null
            try { Assert-SkillsCatalogV3 -Catalog $v3Catalog }
            catch { $v3Error = $_.Exception.Message }
            [string]::IsNullOrWhiteSpace($v3Error) | Should Be ([bool]$v3SourceCase.Valid)
        }
        $cases = @(
            @{ Name='valid'; Path='.agents/skills/work-with-jira/SKILL.md'; Valid=$true },
            @{ Name='empty'; Path=''; Valid=$false },
            @{ Name='absolute'; Path='/outside'; Valid=$false },
            @{ Name='trailing-slash'; Path='folder/'; Valid=$false },
            @{ Name='empty-segment'; Path='folder//file'; Valid=$false },
            @{ Name='dot-segment'; Path='folder/./file'; Valid=$false },
            @{ Name='parent-segment'; Path='folder/../file'; Valid=$false },
            @{ Name='whitespace-segment'; Path='folder/   /file'; Valid=$false },
            @{ Name='backslash'; Path='folder\file'; Valid=$false },
            @{ Name='colon'; Path='folder/file:stream'; Valid=$false },
            @{ Name='tab'; Path="folder/file`tname"; Valid=$false },
            @{ Name='newline'; Path="folder/file`nname"; Valid=$false },
            @{ Name='delete-control'; Path=('folder/file' + [char]0x7f + 'name'); Valid=$false },
            @{ Name='c1-control'; Path=('folder/file' + [char]0x85 + 'name'); Valid=$false }
        )

        foreach ($case in $cases) {
            ([string]$case.Path -cmatch $managedPattern) | Should Be ([bool]$case.Valid)
            ([string]$case.Path -cmatch $userPattern) | Should Be ([bool]$case.Valid)
            if ([bool]$case.Valid) { continue }

            foreach ($propertyName in @('sourcePath','targetPath')) {
                $managedManifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
                @($managedManifest.files)[0].PSObject.Properties[$propertyName].Value = [string]$case.Path
                $managedError = $null
                try { Assert-ManagedManifestV2 -Manifest $managedManifest }
                catch { $managedError = $_.Exception.Message }
                if ([string]::IsNullOrWhiteSpace($managedError)) {
                    throw "Managed manifest accepted unsafe $propertyName case '$($case.Name)'."
                }
                $managedError | Should Match 'Unsafe .*path|must preserve the flat'

                $userManifest = Import-SkillsCatalogJson -Path $script:UserManifestExample -DocumentName 'user Skills managed manifest'
                @($userManifest.files)[0].PSObject.Properties[$propertyName].Value = [string]$case.Path
                $userError = $null
                try { Assert-UserSkillsManagedManifestV1 -Manifest $userManifest }
                catch { $userError = $_.Exception.Message }
                if ([string]::IsNullOrWhiteSpace($userError)) {
                    throw "User Skills managed manifest accepted unsafe $propertyName case '$($case.Name)'."
                }
                $userError | Should Match 'Unsafe .*path|must preserve the flat'
            }
        }
    }

    # Scenario: Catalog, source-pin, and lock objects carry fields forbidden by their additionalProperties=false schemas.
    # Purpose: Ensure the executable verifier rejects schema drift before updater or bootstrap trust the documents.
    It 'UnitT61_rejects_unknown_catalog_source_pin_and_lock_properties' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
        @($catalog.skills)[0].compatibility | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        $catalogPath = Write-TestJsonDocument -Document $catalog -Name 'catalog-unknown-property.json'
        try { Test-SkillsCatalogDocument -CatalogPath $catalogPath | Out-Null; $catalogError = $null }
        catch { $catalogError = $_.Exception.Message }
        $catalogError | Should Match 'compatibility.*unsupported property.*unexpected'

        $sourcePins = Import-SkillsCatalogJson -Path (Join-Path $script:RepositoryRoot 'catalog\skills-catalog.sources.json') -DocumentName 'Skills Catalog source pins'
        @($sourcePins.sources)[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        $sourcePinsPath = Write-TestJsonDocument -Document $sourcePins -Name 'source-pins-unknown-property.json'
        try { Test-SkillsCatalogSourcePinsDocument -SourcePinsPath $sourcePinsPath -CatalogPath $script:ProductionCatalog | Out-Null; $sourcePinsError = $null }
        catch { $sourcePinsError = $_.Exception.Message }
        $sourcePinsError | Should Match 'source pin.*unsupported property.*unexpected'

        $lock = Import-SkillsCatalogJson -Path $script:LockExample -DocumentName 'Skills Catalog lock'
        @($lock.sources)[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        $lockPath = Write-TestJsonDocument -Document $lock -Name 'lock-unknown-property.json'
        (Get-ContractValidationError -CatalogPath $script:CatalogExample -LockPath $lockPath) |
            Should Match 'lock source.*unsupported property.*unexpected'
    }

    # Scenario: Catalog and Lock identity fields differ only by letter casing.
    # Purpose: Keep authoring-time contract validation exactly as strict as runtime routing.
    It 'UnitT62_rejects_case_variant_catalog_lock_identity_fields' {
        $cases = @(
            @{ Name = 'catalog-id'; Expected = 'catalogId does not match'; Apply = { param($lock) $lock.catalogId = ([string]$lock.catalogId).ToUpperInvariant() } },
            @{ Name = 'repository'; Expected = 'repository does not match'; Apply = { param($lock) @($lock.sources)[0].repository = 'https://github.com/example/Agent-Skills-Catalog.git' } },
            @{ Name = 'source-id'; Expected = 'must be lowercase kebab-case'; Apply = { param($lock) @($lock.sources)[0].id = ([string]@($lock.sources)[0].id).ToUpperInvariant() } },
            @{ Name = 'skill-id'; Expected = 'must be lowercase kebab-case'; Apply = { param($lock) @($lock.skills)[0].id = ([string]@($lock.skills)[0].id).ToUpperInvariant() } },
            @{ Name = 'source-path'; Expected = 'lock source does not match'; Apply = { param($lock) @($lock.skills)[0].sourcePath = '.agents/skills/Capture-Private-Course-Knowledge' } }
        )

        foreach ($case in $cases) {
            # Given
            $lock = Import-SkillsCatalogJson -Path $script:LockExample -DocumentName 'Skills Catalog lock'
            & $case.Apply $lock
            $lockPath = Write-TestJsonDocument -Document $lock -Name "$($case.Name)-case-variant-lock.json"

            # When
            $errorMessage = Get-ContractValidationError -CatalogPath $script:CatalogExample -LockPath $lockPath

            # Then
            $errorMessage | Should Match $case.Expected
        }
    }

    # Scenario: Catalog and manifest Skill paths differ from their stable IDs only by case.
    # Purpose: Preserve exact flat-path identity across authoring validation and runtime routing.
    It 'UnitT63_rejects_case_variant_catalog_and_manifest_skill_paths' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
        $catalogSkill = @($catalog.skills | Where-Object { $_.id -eq 'capture-private-course-knowledge' })[0]
        $catalogSkill.source.path = ([string]$catalogSkill.source.path).Replace('/capture-', '/Capture-')
        $catalogPath = Write-TestJsonDocument -Document $catalog -Name 'case-variant-catalog-path.json'
        (Get-ContractValidationError -CatalogPath $catalogPath -LockPath $script:LockExample) | Should Match 'Unsafe Skill source path'

        $manifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
        $skillFile = @($manifest.files | Where-Object { $_.artifactType -eq 'skill' })[0]
        $skillFile.sourcePath = ([string]$skillFile.sourcePath).Replace('/work-', '/Work-')
        $manifestPath = Write-TestJsonDocument -Document $manifest -Name 'case-variant-manifest-path.json'
        (Get-ContractValidationError -CatalogPath $script:CatalogExample -LockPath $script:LockExample -ManifestPath $manifestPath) |
            Should Match 'must preserve the flat .agents/skills path'
    }

    # Scenario: A requested ref has no immutable commit in the lock document.
    # Purpose: Prevent a mutable branch or tag from being treated as reproducible input.
    It 'UnitT64_rejects_an_unresolved_source_pin' {
        $errorMessage = Get-ContractValidationError `
            -CatalogPath $script:CatalogExample `
            -LockPath (Join-Path $script:FixtureRoot 'unresolved-pin.json')

        $errorMessage | Should Match 'resolvedCommit must be a full 40-character commit SHA'
    }

    # Scenario: Jira API setup is needed only when the Jira workflow cannot use a configured connector.
    # Purpose: Preserve work-with-jira's conditional fallback without forcing an unnecessary hard dependency.
    It 'UnitT70_models_the_jira_api_setup_skill_as_a_conditional_fallback_dependency' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
        $jiraSkill = @($catalog.skills | Where-Object { $_.id -eq 'work-with-jira' })[0]
        $dependency = @($jiraSkill.dependencies | Where-Object { $_.skillId -eq 'configure-jira-api-access' })[0]

        $dependency.type | Should Be 'conditional'
        $dependency.condition.capability | Should Be 'jira-cloud-api'
        $dependency.fallback.capability | Should Be 'jira-cloud-connector'
        $requirements = @(@($jiraSkill.compatibility.anyOfCapabilities)[0])
        $requirements.Count | Should Be 2
        $connectorRequirement = @($requirements | Where-Object { [string]$_.id -eq 'jira-cloud-connector' })[0]
        $apiRequirement = @($requirements | Where-Object { [string]$_.id -eq 'jira-cloud-api' })[0]
        [string]$connectorRequirement.kind | Should Be 'connector'
        [string]$connectorRequirement.state | Should Be 'configured'
        [string]$apiRequirement.kind | Should Be 'environment'
        [string]$apiRequirement.state | Should Be 'configured'
    }

    # Scenario: The catalog source uses a human-selected ref that is resolved in the lock document.
    # Purpose: Make every installation reproducible without requiring Git submodules.
    It 'UnitT80_resolves_each_requested_ref_to_an_immutable_commit_and_content_hash' {
        $lock = Import-SkillsCatalogJson -Path $script:LockExample -DocumentName 'Skills Catalog lock'

        foreach ($source in @($lock.sources)) {
            $source.requestedRef | Should Not BeNullOrEmpty
            $source.resolvedCommit | Should Match '^[0-9a-f]{40}$'
            $source.archiveSha256 | Should Match '^[0-9a-f]{64}$'
        }
    }

    # Scenario: A lock Skill entry omits one of the fields that identifies its catalog source.
    # Purpose: Return the standard contract error instead of leaking a StrictMode property access exception.
    It 'UnitT82_rejects_lock_skill_entries_missing_required_source_fields' {
        foreach ($propertyName in @('sourceId', 'sourcePath')) {
            # Given
            $lock = Import-SkillsCatalogJson -Path $script:LockExample -DocumentName 'Skills Catalog lock'
            $skill = @($lock.skills)[0]
            $skill.PSObject.Properties.Remove($propertyName)
            $lockPath = Write-TestJsonDocument -Document $lock -Name "missing-lock-skill-$propertyName.json"

            # When
            $errorMessage = Get-ContractValidationError `
                -CatalogPath $script:CatalogExample `
                -LockPath $lockPath

            # Then
            $errorMessage | Should Match "Skills Catalog lock Skill '.*' is missing required property '$propertyName'"
        }
    }

    # Scenario: A lock Skill sourceId uses a JSON scalar or collection that PowerShell can coerce to text.
    # Purpose: Keep the executable validator aligned with the schema's stable-ID string boundary.
    It 'UnitT83_rejects_non_string_lock_skill_source_ids_before_comparison' {
        $cases = @(
            @{ Name='number'; Value=[long]1 },
            @{ Name='singleton-array'; Value=[object[]]@('agent-skills') }
        )
        foreach ($case in $cases) {
            $lock = Import-SkillsCatalogJson -Path $script:LockExample -DocumentName 'Skills Catalog lock'
            @($lock.skills)[0].sourceId = $case.Value
            $lockPath = Write-TestJsonDocument -Document $lock -Name "$($case.Name)-lock-source-id.json"

            (Get-ContractValidationError -CatalogPath $script:CatalogExample -LockPath $lockPath) |
                Should Match 'sourceId must be a non-empty string'
        }
    }

    # Scenario: A managed file is reconstructed from its target manifest entry.
    # Purpose: Preserve per-file provenance across independent Instructions and Skill sources.
    It 'UnitT90_records_per_file_source_skill_version_commit_and_hash_provenance' {
        $manifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
        $skillEntry = @($manifest.files | Where-Object { $_.artifactType -eq 'skill' })[0]

        $skillEntry.artifactId | Should Be 'work-with-jira'
        $skillEntry.sourceRepository | Should Be 'https://github.com/example/agent-skills-catalog.git'
        $skillEntry.sourceVersion | Should Not BeNullOrEmpty
        $skillEntry.sourceCommit | Should Match '^[0-9a-f]{40}$'
        $skillEntry.sourcePath | Should Be '.agents/skills/work-with-jira/SKILL.md'
        $skillEntry.targetPath | Should Be '.agents/skills/work-with-jira/SKILL.md'
        $skillEntry.sha256 | Should Match '^[0-9a-f]{64}$'
    }

    # Scenario: The personal sync configuration selects profiles and explicit per-Skill overrides.
    # Purpose: Keep user selection separate from catalog availability and the resolved lock.
    It 'UnitT92_keeps_profile_and_include_exclude_selection_in_sync_configuration_v4' {
        $configuration = Import-SkillsCatalogJson -Path $script:ConfigurationExample -DocumentName 'sync configuration'

        $configuration.schemaVersion | Should Be 4
        @($configuration.catalog.profiles).Count | Should BeGreaterThan 0
        ($configuration.catalog.PSObject.Properties.Name -contains 'includeSkills') | Should Be $true
        ($configuration.catalog.PSObject.Properties.Name -contains 'excludeSkills') | Should Be $true
        $configuration.updates.mode | Should Be 'notify-only'
        $configuration.updates.channel | Should Be 'protected-branch'
        $configuration.updates.ref | Should Be 'main'
    }

    # Scenario: A personal sync configuration sets the update interval above the installer-supported Int32 range.
    # Purpose: Keep the Catalog contract parser aligned with the v4 schema and runtime migration boundary.
    It 'UnitT93_rejects_an_update_interval_outside_the_v4_contract' {
        $configuration = Import-SkillsCatalogJson -Path $script:ConfigurationExample -DocumentName 'sync configuration'
        $configuration.updates.minimumCheckIntervalMinutes = [long][int]::MaxValue + 1
        $configurationPath = Write-TestJsonDocument -Document $configuration -Name 'out-of-range-update-interval.json'

        (Get-ContractValidationError `
            -CatalogPath $script:CatalogExample `
            -ConfigurationPath $configurationPath) |
            Should Match 'minimumCheckIntervalMinutes must be at most 2147483647'
    }

    # Scenario: A personal selection differs from a known stable ID only by invalid casing.
    # Purpose: Prevent PowerShell's case-insensitive lookup from accepting values rejected by the JSON Schema.
    It 'UnitT94_rejects_non_stable_profile_and_skill_selection_ids' {
        $cases = @(
            @{ Name = 'profile'; Property = 'profiles'; Value = 'CORE' },
            @{ Name = 'include-skill'; Property = 'includeSkills'; Value = 'Work-With-Jira' },
            @{ Name = 'exclude-skill'; Property = 'excludeSkills'; Value = 'Capture-Private-Course-Knowledge' }
        )

        foreach ($case in $cases) {
            $configuration = Import-SkillsCatalogJson -Path $script:ConfigurationExample -DocumentName 'sync configuration'
            $configuration.catalog.PSObject.Properties[$case.Property].Value = @($case.Value)
            $configurationPath = Write-TestJsonDocument -Document $configuration -Name "$($case.Name).json"

            $errorMessage = Get-ContractValidationError `
                -CatalogPath $script:CatalogExample `
                -ConfigurationPath $configurationPath

            $errorMessage | Should Match "catalog $($case.Property) item must be lowercase kebab-case"
        }
    }

    # Scenario: Every current Skill remains a flat, client-discoverable directory regardless of profile grouping.
    # Purpose: Ensure metadata grouping does not introduce nested packages or Git submodule requirements.
    It 'UnitT95_preserves_the_flat_agents_skills_layout_without_submodule_metadata' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'

        foreach ($skill in @($catalog.skills)) {
            $skill.source.path | Should Be ".agents/skills/$($skill.id)"
        }
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.gitmodules') | Should Be $false
    }
}
