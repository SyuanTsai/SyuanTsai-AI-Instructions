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
    }
}

function Get-RuntimeContractError {
    param([Parameter(Mandatory = $true)][scriptblock] $Action)
    try { & $Action; return $null }
    catch { return $_.Exception.Message }
}

Describe 'AI instructions runtime contracts' {
    BeforeAll {
        Import-Module $script:RuntimeContractModule -Force
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
        $bundleSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'catalog\schemas\runtime-bundle-v2.schema.json') | ConvertFrom-Json

        [string]$configurationSchema.properties.catalog.properties.repository.const | Should Be $script:CanonicalRepository
        [string]$bundleSchema.properties.repository.const | Should Be $script:CanonicalRepository

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
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null

        (Get-RuntimeContractError {
            Assert-AiInstructionsMutationPath -Path $wrongFilePath -ExpectedType File -Context 'receipt'
        }) | Should Match 'non-reparse file'
        (Get-RuntimeContractError {
            Get-AiInstructionsRuntimeInventory -RuntimeRoot $junction
        }) | Should Match 'non-reparse directory|reparse point'
    }
}
