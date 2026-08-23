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
}
