$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ContractModule = Join-Path $script:RepositoryRoot 'scripts\skills-catalog-contract.psm1'
$script:CatalogExample = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog.example.json'
$script:LockExample = Join-Path $script:RepositoryRoot 'catalog\examples\skills-catalog-lock.example.json'
$script:ManifestExample = Join-Path $script:RepositoryRoot 'catalog\examples\managed-manifest-v2.example.json'
$script:ConfigurationExample = Join-Path $script:RepositoryRoot 'catalog\examples\ai-instructions-sync-v3.example.json'
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

Describe 'Skills Catalog contract' {
    # Scenario: Every checked-in JSON Schema document is loaded by the repository's oldest supported PowerShell runtime.
    # Purpose: Detect malformed schema artifacts before downstream tools depend on them.
    It 'UnitT05_parses_every_checked_in_json_schema_document' {
        $schemaRoot = Join-Path $script:RepositoryRoot 'catalog\schemas'
        $schemaFiles = @(Get-ChildItem -LiteralPath $schemaRoot -File -Filter '*.schema.json')

        $schemaFiles.Count | Should Be 4
        foreach ($schemaFile in $schemaFiles) {
            $schema = Import-SkillsCatalogJson -Path $schemaFile.FullName -DocumentName $schemaFile.Name
            $schema.'$schema' | Should Be 'https://json-schema.org/draft/2020-12/schema'
            $schema.type | Should Be 'object'
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

        $result.SkillCount | Should Be 10
        $result.ProfileCount | Should Be 6
        $result.SourceCount | Should Be 1
        $result.ManifestFileCount | Should Be 2

        $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'
        $actualSkillIds = @(
            Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot '.agents\skills') -Directory |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )
        $catalogSkillIds = @($catalog.skills | Select-Object -ExpandProperty id | Sort-Object)
        ($catalogSkillIds -join "`n") | Should Be ($actualSkillIds -join "`n")

        $expectedProfileIds = @('atlassian', 'code-collaboration', 'core', 'external-research', 'knowledge-capture', 'observability')
        $catalogProfileIds = @($catalog.profiles | Select-Object -ExpandProperty id | Sort-Object)
        ($catalogProfileIds -join "`n") | Should Be ($expectedProfileIds -join "`n")
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
                Name = 'artifact-type'
                Target = 'Manifest'
                Expected = 'Unsupported managed manifest artifactType'
                Apply = {
                    param($document)
                    @($document.files)[0].artifactType = 'Instruction'
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

    # Scenario: A requested ref has no immutable commit in the lock document.
    # Purpose: Prevent a mutable branch or tag from being treated as reproducible input.
    It 'UnitT60_rejects_an_unresolved_source_pin' {
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

    # Scenario: A managed file is reconstructed from its target manifest entry.
    # Purpose: Preserve per-file provenance across independent Instructions and Skill sources.
    It 'UnitT90_records_per_file_source_skill_version_commit_and_hash_provenance' {
        $manifest = Import-SkillsCatalogJson -Path $script:ManifestExample -DocumentName 'managed manifest'
        $skillEntry = @($manifest.files | Where-Object { $_.artifactType -eq 'skill' })[0]

        $skillEntry.artifactId | Should Be 'work-with-jira'
        $skillEntry.sourceRepository | Should Match '^https://example\.(com|org|test)/'
        $skillEntry.sourceVersion | Should Not BeNullOrEmpty
        $skillEntry.sourceCommit | Should Match '^[0-9a-f]{40}$'
        $skillEntry.sourcePath | Should Be '.agents/skills/work-with-jira/SKILL.md'
        $skillEntry.targetPath | Should Be '.agents/skills/work-with-jira/SKILL.md'
        $skillEntry.sha256 | Should Match '^[0-9a-f]{64}$'
    }

    # Scenario: The personal sync configuration selects profiles and explicit per-Skill overrides.
    # Purpose: Keep user selection separate from catalog availability and the resolved lock.
    It 'UnitT92_keeps_profile_and_include_exclude_selection_in_sync_configuration_v3' {
        $configuration = Import-SkillsCatalogJson -Path $script:ConfigurationExample -DocumentName 'sync configuration'

        $configuration.schemaVersion | Should Be 3
        @($configuration.catalog.profiles).Count | Should BeGreaterThan 0
        ($configuration.catalog.PSObject.Properties.Name -contains 'includeSkills') | Should Be $true
        ($configuration.catalog.PSObject.Properties.Name -contains 'excludeSkills') | Should Be $true
    }

    # Scenario: A personal selection differs from a known stable ID only by invalid casing.
    # Purpose: Prevent PowerShell's case-insensitive lookup from accepting values rejected by the JSON Schema.
    It 'UnitT93_rejects_non_stable_profile_and_skill_selection_ids' {
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
    It 'UnitT94_preserves_the_flat_agents_skills_layout_without_submodule_metadata' {
        $catalog = Import-SkillsCatalogJson -Path $script:CatalogExample -DocumentName 'Skills Catalog'

        foreach ($skill in @($catalog.skills)) {
            $skill.source.path | Should Be ".agents/skills/$($skill.id)"
        }
        Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.gitmodules') | Should Be $false
    }
}
