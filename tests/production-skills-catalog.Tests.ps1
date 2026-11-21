Describe 'production Skills Catalog' {
    BeforeAll {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $catalogPath = Join-Path $repositoryRoot 'catalog\skills-catalog.json'
        $sourcePinsPath = Join-Path $repositoryRoot 'catalog\skills-catalog.sources.json'
        $lockPath = Join-Path $repositoryRoot 'catalog\skills-catalog-lock.json'
        $contractModule = Join-Path $repositoryRoot 'scripts\skills-catalog-contract.psm1'

        Import-Module $contractModule -Force
        Import-Module (Join-Path $repositoryRoot 'scripts\skills-selection.psm1') -Force
        $script:catalog = Test-SkillsCatalogDocument -CatalogPath $catalogPath
        $script:pins = Test-SkillsCatalogSourcePinsDocument -SourcePinsPath $sourcePinsPath -CatalogPath $catalogPath
        $script:lock = Test-SkillsCatalogLockDocument -LockPath $lockPath -CatalogPath $catalogPath

        function Assert-StringSequence {
            param([object[]] $Actual, [object[]] $Expected, [string] $Message = 'String sequences differ.')

            $actualValues = @($Actual | ForEach-Object { [string]$_ })
            $expectedValues = @($Expected | ForEach-Object { [string]$_ })
            if ($actualValues.Count -ne $expectedValues.Count) {
                throw "$Message Expected count '$($expectedValues.Count)', got '$($actualValues.Count)'."
            }
            for ($index = 0; $index -lt $expectedValues.Count; $index++) {
                if ($actualValues[$index] -cne $expectedValues[$index]) {
                    throw "$Message Index '$index' expected '$($expectedValues[$index])', got '$($actualValues[$index])'."
                }
            }
        }

        function New-TestCatalogSourceArchive {
            param(
                [Parameter(Mandatory=$true)][string]$ArchivePath,
                [Parameter(Mandatory=$true)][string[]]$SkillIds
            )
            Add-Type -AssemblyName System.IO.Compression
            if(Test-Path -LiteralPath $ArchivePath){Remove-Item -LiteralPath $ArchivePath -Force}
            $stream=[IO.File]::Open($ArchivePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{
                $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
                try{
                    foreach($skillId in @($SkillIds|Sort-Object)){
                        $entry=$archive.CreateEntry("fixture-root/skills/$skillId/SKILL.md",[IO.Compression.CompressionLevel]::Optimal)
                        $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)))
                        try{$writer.Write("---`nname: $skillId`ndescription: Offline lock fixture for $skillId.`n---`n`n# Fixture`n")}finally{$writer.Dispose()}
                    }
                }finally{$archive.Dispose()}
            }finally{$stream.Dispose()}
            return $ArchivePath
        }

        function New-TestCatalogLockInputs {
            param([Parameter(Mandatory=$true)][string]$Root,[string[]]$SkillIds=@('work-with-jira'))
            New-Item -ItemType Directory -Force -Path $Root|Out-Null
            $catalog=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repositoryRoot 'catalog/examples/skills-catalog-v3.example.json')|ConvertFrom-Json
            $catalog.skills=@($catalog.skills|Where-Object{[string]$_.id -cin $SkillIds})
            $catalog.profiles[0].includes=@($SkillIds)
            foreach($skillId in @($SkillIds)){
                if(@($catalog.skills|Where-Object id -ceq $skillId).Count-eq0){
                    $template=($catalog.skills[0]|ConvertTo-Json -Depth 20|ConvertFrom-Json)
                    $template.id=$skillId;$template.group='fixture';$template.source.sourcePath="skills/$skillId";$template.profiles=@('core')
                    $catalog.skills=@($catalog.skills)+@($template)
                }
            }
            $catalogPath=Join-Path $Root 'catalog.json'
            $pinsPath=Join-Path $Root 'pins.json'
            $lockOutputPath=Join-Path $Root 'lock.json'
            $archivePath=New-TestCatalogSourceArchive -ArchivePath (Join-Path $Root 'source.zip') -SkillIds $SkillIds
            [IO.File]::WriteAllText($catalogPath,(($catalog|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
            $pins=[ordered]@{
                schemaVersion=1;catalogId=[string]$catalog.catalogId
                sources=@([ordered]@{id='agent-skills';requestedRef='v1.0.0';requestedRefType='tag';resolvedCommit='0123456789abcdef0123456789abcdef01234567';resolvedVersion='1.0.0'})
            }
            [IO.File]::WriteAllText($pinsPath,(($pins|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{CatalogPath=$catalogPath;PinsPath=$pinsPath;OutputPath=$lockOutputPath;ArchivePath=$archivePath}
        }
    }

    # Scenario: The tracked production catalog defines the repositories available to installed consumers.
    # Purpose: Prevent the bootstrap repository or an unapproved source from re-entering production routing.
    It 'InterT10_uses_the_four_external_Skill_repositories_as_the_only_production_sources' {
        $expected = @(
            'atlassian-ecosystem',
            'code-collaboration',
            'general',
            'knowledge-content'
        )
        Assert-StringSequence -Actual @($script:catalog.sources.id | Sort-Object) -Expected $expected
        @($script:catalog.sources | Where-Object { $_.repository -match 'SyuanTsai-AI-Instructions' }).Count | Should Be 0
        @($script:catalog.sources | Where-Object { $_.repository -match 'Skill-Darktide-Translate' }).Count | Should Be 0
    }

    # Scenario: The AI-Instructions repository has completed its cutover to externally owned shared Skills.
    # Purpose: Keep external repositories as the only shared Skill sources and prevent legacy copies from returning.
    It 'InterT12_contains_no_built_in_shared_Skill_source' {
        $builtInSkillRoot = Join-Path $repositoryRoot '.agents\skills'
        if (Test-Path -LiteralPath $builtInSkillRoot -PathType Container) {
            @(
                Get-ChildItem -LiteralPath $builtInSkillRoot -Recurse -Force -File |
                    Where-Object { $_.Name -ne '.gitkeep' }
            ).Count | Should Be 0
        }
        else {
            Test-Path -LiteralPath $builtInSkillRoot | Should Be $false
        }
    }

    # Scenario: Product workflows expose API setup only as an explicit or conditional fallback.
    # Purpose: A configured connector must not install credential-setup Skills merely because a product profile was selected.
    It 'InterT14_keeps_API_setup_Skills_out_of_product_profile_membership' {
        $setupSkills = @(
            @{ Id='configure-bitbucket-api-access'; Profile='code-collaboration' },
            @{ Id='configure-confluence-api-access'; Profile='atlassian' },
            @{ Id='configure-jira-api-access'; Profile='atlassian' }
        )
        foreach ($setup in $setupSkills) {
            $profile = @($script:catalog.profiles | Where-Object { [string]$_.id -eq [string]$setup.Profile })[0]
            $skill = @($script:catalog.skills | Where-Object { [string]$_.id -eq [string]$setup.Id })[0]
            @($profile.includes | Where-Object { [string]$_ -eq [string]$setup.Id }).Count | Should Be 0
            @($skill.profiles).Count | Should Be 0
        }
    }

    # Scenario: A product profile is selected before either connector or API evidence exists.
    # Purpose: Keep setup Skills conditional while still installing the workflow and the setup fallback that can make it usable.
    It 'InterT13_selects_API_setup_fallbacks_only_when_product_capabilities_are_missing' {
        $cases = @(
            @{
                Profile='code-collaboration'
                Expected=@('configure-bitbucket-api-access','review-bitbucket-pull-request','write-implementation-prompt')
            },
            @{
                Profile='atlassian'
                Expected=@('configure-confluence-api-access','configure-jira-api-access','manage-confluence-docs-as-code','publish-requirements-to-confluence','work-with-jira')
            }
        )
        $currentPlatform = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            'windows'
        }
        elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
            'macos'
        }
        elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
            'linux'
        }
        else {
            'unix'
        }
        try {
            Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue
            foreach ($case in $cases) {
                $selection = [pscustomobject]@{ profiles=@([string]$case.Profile); includeSkills=@(); excludeSkills=@() }
                $expected = @(
                    foreach ($skillId in @($case.Expected)) {
                        $skill = @($script:catalog.skills | Where-Object { [string]$_.id -ceq $skillId })[0]
                        $platforms = @($skill.compatibility.platforms)
                        if (($platforms -contains 'any') -or ($platforms -contains $currentPlatform)) {
                            $skillId
                        }
                    }
                )
                Assert-StringSequence `
                    -Actual @(Resolve-SkillsSelection -Catalog $script:catalog -Selection $selection) `
                    -Expected $expected
            }
        }
        finally { Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue }
    }

    # Scenario: Active migrated Skills remain routed while the retired FELO wrapper keeps only its stable-ID tombstone.
    # Purpose: Prevent the custom FELO Skill from re-entering profiles or the production lock without losing removal history.
    It 'InterT15_maps_fourteen_active_Skills_and_keeps_the_removed_FELO_tombstone' {
        $activeSkills = @($script:catalog.skills | Where-Object { $_.lifecycle.status -eq 'active' })
        $activeSkills.Count | Should Be 14

        $expectedSourceBySkill = @{
            'plan-production-change' = 'general'
            'verify-data-access-performance' = 'general'
            'investigate-datadog-logs' = 'general'
            'manage-ai-memory' = 'general'
            'manage-task-handoff' = 'general'
            'write-implementation-prompt' = 'code-collaboration'
            'capture-private-course-knowledge' = 'knowledge-content'
            'configure-bitbucket-api-access' = 'atlassian-ecosystem'
            'configure-confluence-api-access' = 'atlassian-ecosystem'
            'configure-jira-api-access' = 'atlassian-ecosystem'
            'manage-confluence-docs-as-code' = 'atlassian-ecosystem'
            'publish-requirements-to-confluence' = 'atlassian-ecosystem'
            'review-bitbucket-pull-request' = 'atlassian-ecosystem'
            'work-with-jira' = 'atlassian-ecosystem'
        }

        foreach ($skill in $activeSkills) {
            $expectedSourceBySkill.ContainsKey([string]$skill.id) | Should Be $true
            [string]$skill.source.sourceId | Should Be $expectedSourceBySkill[[string]$skill.id]
            [string]$skill.source.sourcePath | Should Be "skills/$($skill.id)"
            $null -eq $skill.source.PSObject.Properties['targetPath'] | Should Be $true
        }

        $removedFelo = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'search-with-felo' })
        $removedFelo.Count | Should Be 1
        [string]$removedFelo[0].lifecycle.status | Should Be 'removed'
        @($removedFelo[0].lifecycle.aliases).Count | Should Be 0
        @($removedFelo[0].lifecycle.PSObject.Properties.Name | Where-Object { $_ -eq 'replacementId' }).Count | Should Be 0
        @($removedFelo[0].profiles).Count | Should Be 0

        $externalResearch = @($script:catalog.profiles | Where-Object { [string]$_.id -eq 'external-research' })
        $externalResearch.Count | Should Be 1
        @($externalResearch[0].includes | Where-Object { $_ -eq 'search-with-felo' }).Count | Should Be 0

        @($script:catalog.skills | Where-Object { [string]$_.id -match 'darktide' }).Count | Should Be 0
    }

    # Scenario: Both Codex and Copilot runtime Instructions publish the official FELO replacement routes.
    # Purpose: Keep system-level official Skills canonical and prevent any route back to the retired repository-local wrapper.
    It 'InterT16_routes_FELO_workflows_only_to_the_four_official_canonical_Skills' {
        $instructionPaths = @(
            '.codex/AGENTS.md',
            '.codex/AGENTS.en.md',
            '.github/copilot-instructions.md',
            '.github/copilot-instructions.en.md'
        )
        $officialPaths = @(
            '~/.agents/skills/felo-search/SKILL.md',
            '~/.agents/skills/felo-slides/SKILL.md',
            '~/.agents/skills/felo-x-search/SKILL.md',
            '~/.agents/skills/felo-landingpage/SKILL.md'
        )
        foreach ($instructionPath in $instructionPaths) {
            $content = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $repositoryRoot $instructionPath)
            $content | Should Not Match '\.agents/skills/search-with-felo/SKILL\.md'
            foreach ($officialPath in $officialPaths) { $content | Should Match ([regex]::Escape($officialPath)) }
        }
    }

    # Scenario: Bitbucket PR review can repair missing or invalid API access without forcing setup when a connector is available.
    # Purpose: Keep API setup conditional and preserve the connector fallback boundary.
    It 'InterT17_routes_Bitbucket_API_failures_to_the_setup_Skill_conditionally' {
        $skill = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'review-bitbucket-pull-request' })[0]
        @($skill.dependencies).Count | Should Be 1
        [string]$skill.dependencies[0].skillId | Should Be 'configure-bitbucket-api-access'
        [string]$skill.dependencies[0].type | Should Be 'conditional'
        [string]$skill.dependencies[0].condition.capability | Should Be 'bitbucket-cloud-api'
        [string]$skill.dependencies[0].condition.operator | Should Be 'missing-or-invalid'
        [string]$skill.dependencies[0].fallback.capability | Should Be 'bitbucket-cloud-connector'
        $connectorRequirement = @(@($skill.compatibility.anyOfCapabilities)[0] | Where-Object { [string]$_.kind -eq 'connector' })[0]
        $apiRequirement = @(@($skill.compatibility.anyOfCapabilities)[0] | Where-Object { [string]$_.kind -eq 'environment' })[0]
        [string]$connectorRequirement.id | Should Be ([string]$skill.dependencies[0].fallback.capability)
        [string]$connectorRequirement.state | Should Be 'configured'
        [string]$apiRequirement.id | Should Be ([string]$skill.dependencies[0].condition.capability)
        [string]$apiRequirement.state | Should Be 'configured'
    }

    # Scenario: Confluence publishing can repair missing or invalid scoped API access without forcing setup when a connector is available.
    # Purpose: Keep API setup conditional and preserve the connector fallback boundary.
    It 'InterT18_routes_Confluence_API_failures_to_the_setup_Skill_conditionally' {
        $skill = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'publish-requirements-to-confluence' })[0]
        @($skill.dependencies).Count | Should Be 1
        [string]$skill.dependencies[0].skillId | Should Be 'configure-confluence-api-access'
        [string]$skill.dependencies[0].type | Should Be 'conditional'
        [string]$skill.dependencies[0].condition.capability | Should Be 'confluence-cloud-api'
        [string]$skill.dependencies[0].condition.operator | Should Be 'missing-or-invalid'
        [string]$skill.dependencies[0].fallback.capability | Should Be 'confluence-cloud-connector'
        $connectorRequirement = @(@($skill.compatibility.anyOfCapabilities)[0] | Where-Object { [string]$_.kind -eq 'connector' })[0]
        $apiRequirement = @(@($skill.compatibility.anyOfCapabilities)[0] | Where-Object { [string]$_.kind -eq 'environment' })[0]
        [string]$connectorRequirement.id | Should Be ([string]$skill.dependencies[0].fallback.capability)
        [string]$connectorRequirement.state | Should Be 'configured'
        [string]$apiRequirement.id | Should Be ([string]$skill.dependencies[0].condition.capability)
        [string]$apiRequirement.state | Should Be 'configured'
    }

    # Scenario: Each workflow is explicitly selected with exact, weaker-state, or wrong-kind capability evidence.
    # Purpose: Suppress setup only for the complete declared tuple and keep it for ID-only false matches.
    It 'InterT21_requires_the_exact_capability_tuple_to_suppress_setup_fallbacks' {
        $positiveCases = @(
            @{ Skill='review-bitbucket-pull-request'; Kind='connector'; Capability='bitbucket-cloud-connector' },
            @{ Skill='review-bitbucket-pull-request'; Kind='environment'; Capability='bitbucket-cloud-api' },
            @{ Skill='publish-requirements-to-confluence'; Kind='connector'; Capability='confluence-cloud-connector' },
            @{ Skill='publish-requirements-to-confluence'; Kind='environment'; Capability='confluence-cloud-api' },
            @{ Skill='work-with-jira'; Kind='connector'; Capability='jira-cloud-connector' },
            @{ Skill='work-with-jira'; Kind='environment'; Capability='jira-cloud-api' }
        )
        try {
            foreach ($case in $positiveCases) {
                $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE = "[{`"kind`":`"$($case.Kind)`",`"id`":`"$($case.Capability)`",`"state`":`"configured`"}]"
                $selection = [pscustomobject]@{ profiles=@('external-research'); includeSkills=@([string]$case.Skill); excludeSkills=@() }
                Assert-StringSequence `
                    -Actual @(Resolve-SkillsSelection -Catalog $script:catalog -Selection $selection) `
                    -Expected @([string]$case.Skill)
            }

            $negativeCases = @(
                @{
                    Skill='work-with-jira'; Setup='configure-jira-api-access'
                    Evidence='[{"kind":"connector","id":"jira-cloud-connector","state":"available"}]'
                },
                @{
                    Skill='review-bitbucket-pull-request'; Setup='configure-bitbucket-api-access'
                    Evidence='[{"kind":"environment","id":"bitbucket-cloud-connector","state":"configured"}]'
                }
            )
            foreach ($case in $negativeCases) {
                $env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE = [string]$case.Evidence
                $selection = [pscustomobject]@{ profiles=@('external-research'); includeSkills=@([string]$case.Skill); excludeSkills=@() }
                Assert-StringSequence `
                    -Actual @(Resolve-SkillsSelection -Catalog $script:catalog -Selection $selection) `
                    -Expected @([string]$case.Setup,[string]$case.Skill)
            }
        }
        finally { Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue }
    }

    # Scenario: Durable AI memory is selected with an opt-in profile, and the previous stable ID resolves through its tombstone.
    # Purpose: Keep existing selections working across the rename without requiring any connector at installation time.
    It 'InterT19_routes_AI_memory_through_the_opt_in_profile_and_legacy_alias' {
        $profile = @($script:catalog.profiles | Where-Object { [string]$_.id -eq 'ai-memory' })
        $skill = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'manage-ai-memory' })
        $legacy = @($script:catalog.skills | Where-Object { [string]$_.id -eq 'manage-notion-ai-memory' })

        $profile.Count | Should Be 1
        [bool]$profile[0].default | Should Be $false
        Assert-StringSequence -Actual @($profile[0].includes) -Expected @('manage-ai-memory','manage-task-handoff')
        $skill.Count | Should Be 1
        [string]$skill[0].group | Should Be 'knowledge-management'
        Assert-StringSequence -Actual @($skill[0].profiles) -Expected @('ai-memory')
        @($skill[0].compatibility.requiredCapabilities).Count | Should Be 0
        Assert-StringSequence -Actual @($skill[0].lifecycle.aliases) -Expected @('manage-notion-ai-memory')
        $legacy.Count | Should Be 1
        [string]$legacy[0].lifecycle.status | Should Be 'removed'
        [string]$legacy[0].lifecycle.replacementId | Should Be 'manage-ai-memory'
        @($legacy[0].profiles).Count | Should Be 0

        try {
            Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue
            $selection = [pscustomobject]@{ profiles=@('ai-memory'); includeSkills=@(); excludeSkills=@() }
            Assert-StringSequence `
                -Actual @(Resolve-SkillsSelection -Catalog $script:catalog -Selection $selection) `
                -Expected @('manage-ai-memory','manage-task-handoff')
            $legacySelection = [pscustomobject]@{ profiles=@(); includeSkills=@('manage-notion-ai-memory'); excludeSkills=@() }
            Assert-StringSequence `
                -Actual @(Resolve-SkillsSelection -Catalog $script:catalog -Selection $legacySelection) `
                -Expected @('manage-ai-memory','plan-production-change','verify-data-access-performance')
            $excludedLegacySelection = [pscustomobject]@{ profiles=@('ai-memory'); includeSkills=@(); excludeSkills=@('manage-notion-ai-memory') }
            Assert-StringSequence `
                -Actual @(Resolve-SkillsSelection -Catalog $script:catalog -Selection $excludedLegacySelection) `
                -Expected @('manage-task-handoff')
        }
        finally { Remove-Item Env:AI_INSTRUCTIONS_CAPABILITY_EVIDENCE -ErrorAction SilentlyContinue }
    }

    # Scenario: The production catalog contains the profiles used by a new installation.
    # Purpose: Keep installation defaults deterministic and limited to the intended core profile.
    It 'InterT20_keeps_core_as_the_only_default_profile' {
        @($script:catalog.profiles | Where-Object { $_.default -eq $true }).Count | Should Be 1
        [string]@($script:catalog.profiles | Where-Object { $_.default -eq $true })[0].id | Should Be 'core'
    }

    # Scenario: Production source pins are loaded together with the tracked catalog.
    # Purpose: Ensure every source resolves from an immutable commit while preserving its operator-facing branch metadata.
    It 'InterT25_pins_every_production_source_to_a_full_immutable_commit' {
        $script:pins.schemaVersion | Should Be 1
        ([string]$script:pins.catalogId) | Should Be ([string]$script:catalog.catalogId)
        @($script:pins.sources).Count | Should Be @($script:catalog.sources).Count

        foreach ($source in @($script:catalog.sources)) {
            $matches = @($script:pins.sources | Where-Object { [string]$_.id -eq [string]$source.id })
            $matches.Count | Should Be 1
            [string]$matches[0].requestedRef | Should Be 'main'
            [string]$matches[0].requestedRefType | Should Be 'branch'
            [string]$matches[0].resolvedCommit | Should Match '^[0-9a-f]{40}$'
            [string]$matches[0].resolvedVersion | Should Not BeNullOrEmpty
        }
    }

    # Scenario: The production catalog is distributed with its generated immutable lock.
    # Purpose: Make installation reproducible from tracked bytes and give CI a stale-lock gate.
    It 'InterT30_tracks_a_complete_lock_for_every_production_source_and_skill' {
        Test-Path -LiteralPath $lockPath -PathType Leaf | Should Be $true
        ([string]$script:lock.catalogId) | Should Be ([string]$script:catalog.catalogId)
        @($script:lock.sources).Count | Should Be @($script:catalog.sources).Count
        @($script:lock.skills).Count | Should Be @($script:catalog.skills | Where-Object { $_.lifecycle.status -ne 'removed' }).Count
        foreach ($source in @($script:lock.sources)) {
            [string]$source.resolvedCommit | Should Match '^[0-9a-f]{40}$'
            [string]$source.archiveSha256 | Should Match '^[0-9a-f]{64}$'
        }
        foreach ($skill in @($script:lock.skills)) {
            [string]$skill.contentSha256 | Should Match '^[0-9a-f]{64}$'
        }
        @($script:lock.skills | Where-Object { [string]$_.id -eq 'search-with-felo' }).Count | Should Be 0
    }

    # Scenario: Production uses the projection-aware Catalog while preserving canonical source packages.
    # Purpose: Guard the v3 cutover without dropping a Skill, changing a source package, or adding an unsupported projection.
    It 'InterT31_binds_production_catalog_and_lock_to_the_two_USER_projections' {
        $script:catalog.schemaVersion | Should Be 3
        $script:lock.schemaVersion | Should Be 3
        Assert-StringSequence -Actual @($script:catalog.projections.id) -Expected @('user-agents','user-claude')
        Assert-StringSequence -Actual @($script:catalog.projections.scope) -Expected @('user','user')
        Assert-StringSequence -Actual @($script:catalog.projections.root) -Expected @('.agents/skills','.claude/skills')
        [string]$script:lock.projectionContractSha256 | Should Match '^[0-9a-f]{64}$'
        $active = @($script:catalog.skills | Where-Object { $_.lifecycle.status -eq 'active' })
        $active.Count | Should Be 14
        foreach ($skill in $active) {
            [string]$skill.source.sourcePath | Should Be "skills/$($skill.id)"
            $null -eq $skill.source.PSObject.Properties['targetPath'] | Should Be $true
            $locked = @($script:lock.skills | Where-Object { $_.id -eq $skill.id })
            $locked.Count | Should Be 1
            [string]$locked[0].sourcePath | Should Be $skill.source.sourcePath
            $null -eq $locked[0].PSObject.Properties['targetPath'] | Should Be $true
        }
        @($script:catalog.skills | Where-Object { $null -ne $_.source.PSObject.Properties['path'] }).Count | Should Be 0
    }

    # Scenario: The projection-aware production Lock is compared with the immutable v2 Lock from the approved 34366ae baseline.
    # Purpose: Prove that the v3 format migration changes neither source pins nor per-Skill content hashes.
    It 'InterT32_preserves_every_v2_source_pin_and_content_hash_in_the_v3_lock' {
        $baselineText = @(& git -C $repositoryRoot show '34366ae:catalog/skills-catalog-lock.json') -join "`n"
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($baselineText)) {
            throw 'The approved 34366ae v2 Lock baseline is unavailable.'
        }
        $baseline = $baselineText | ConvertFrom-Json
        [int]$baseline.schemaVersion | Should Be 2

        @($script:lock.sources).Count | Should Be @($baseline.sources).Count
        foreach ($expected in @($baseline.sources)) {
            $actual = @($script:lock.sources | Where-Object { [string]$_.id -ceq [string]$expected.id })
            $actual.Count | Should Be 1
            foreach ($property in @('repository','requestedRef','requestedRefType','resolvedCommit','resolvedVersion','archiveSha256')) {
                [string]$actual[0].$property | Should Be ([string]$expected.$property)
            }
        }

        @($script:lock.skills).Count | Should Be @($baseline.skills).Count
        foreach ($expected in @($baseline.skills)) {
            $actual = @($script:lock.skills | Where-Object { [string]$_.id -ceq [string]$expected.id })
            $actual.Count | Should Be 1
            foreach ($property in @('sourceId','sourcePath','contentSha256')) {
                [string]$actual[0].$property | Should Be ([string]$expected.$property)
            }
        }
    }

    # Scenario: The approved v2 Lock is explicitly supplied as the conversion base for the production v3 Lock.
    # Purpose: Keep the one-time offline production conversion reproducible without treating the output as its own authority.
    It 'InterT33_generates_the_v3_lock_from_an_explicit_v2_base_with_identical_bytes' {
        $baselineText = @(& git -C $repositoryRoot show '34366ae:catalog/skills-catalog-lock.json') -join "`n"
        $baselinePath = Join-Path $TestDrive 'skills-catalog-lock-v2.json'
        $generatedPath = Join-Path $TestDrive 'skills-catalog-lock-v3.json'
        [IO.File]::WriteAllText($baselinePath,$baselineText+"`n",[Text.UTF8Encoding]::new($false))
        $generator = Join-Path $repositoryRoot 'scripts/update-skills-catalog-lock.ps1'
        $engine = (Get-Process -Id $PID).Path

        $generateOutput = @(& $engine -NoProfile -NonInteractive -File $generator `
            -CatalogPath $catalogPath -SourcePinsPath $sourcePinsPath -OutputPath $generatedPath -BaseLockPath $baselinePath 2>&1)
        $LASTEXITCODE | Should Be 0
        ($generateOutput -join "`n") | Should Match 'existing immutable pins'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($generatedPath)) | Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)))
    }

    # Scenario: A generated v3 Lock has a syntactically valid content hash changed before ordinary -Check uses a local immutable archive.
    # Purpose: Recompute archive and Skill hashes so a checked Lock cannot validate itself.
    It 'InterT34_rejects_a_tampered_64_hex_hash_during_ordinary_archive_check' {
        $fixture=New-TestCatalogLockInputs -Root (Join-Path $TestDrive 'ordinary-check')
        $generator=Join-Path $repositoryRoot 'scripts/update-skills-catalog-lock.ps1'
        & $generator -CatalogPath $fixture.CatalogPath -SourcePinsPath $fixture.PinsPath -OutputPath $fixture.OutputPath -SourceArchivePaths @{'agent-skills'=$fixture.ArchivePath}|Out-Null
        $candidate=Get-Content -Raw -Encoding UTF8 -LiteralPath $fixture.OutputPath|ConvertFrom-Json
        $candidate.skills[0].contentSha256='f'*64
        [IO.File]::WriteAllText($fixture.OutputPath,(($candidate|ConvertTo-Json -Depth 20 -Compress)+"`n"),[Text.UTF8Encoding]::new($false))

        {& $generator -CatalogPath $fixture.CatalogPath -SourcePinsPath $fixture.PinsPath -OutputPath $fixture.OutputPath -SourceArchivePaths @{'agent-skills'=$fixture.ArchivePath} -Check|Out-Null}|Should Throw 'Skills Catalog lock is stale. Run scripts/update-skills-catalog-lock.ps1 and commit the result.'
    }

    # Scenario: The explicitly supplied conversion base resolves to the same file as the requested output.
    # Purpose: Prevent conversion and Check from using the candidate output as a trust source.
    It 'InterT35_rejects_an_explicit_conversion_base_that_equals_the_output' {
        $fixture=New-TestCatalogLockInputs -Root (Join-Path $TestDrive 'same-base-output')
        $generator=Join-Path $repositoryRoot 'scripts/update-skills-catalog-lock.ps1'
        & $generator -CatalogPath $fixture.CatalogPath -SourcePinsPath $fixture.PinsPath -OutputPath $fixture.OutputPath -SourceArchivePaths @{'agent-skills'=$fixture.ArchivePath}|Out-Null

        {& $generator -CatalogPath $fixture.CatalogPath -SourcePinsPath $fixture.PinsPath -OutputPath $fixture.OutputPath -BaseLockPath $fixture.OutputPath|Out-Null}|Should Throw 'Skills Catalog base Lock path must not equal the output path.'
    }

    # Scenario: An existing v3 Lock is followed by a source pin advance and a newly active Skill with a matching local archive.
    # Purpose: Keep ordinary generation on the archive path instead of blocking valid maintenance in conversion checks.
    It 'InterT36_recomputes_from_archives_when_a_pin_advances_and_a_Skill_is_added' {
        $fixture=New-TestCatalogLockInputs -Root (Join-Path $TestDrive 'ordinary-maintenance')
        $generator=Join-Path $repositoryRoot 'scripts/update-skills-catalog-lock.ps1'
        & $generator -CatalogPath $fixture.CatalogPath -SourcePinsPath $fixture.PinsPath -OutputPath $fixture.OutputPath -SourceArchivePaths @{'agent-skills'=$fixture.ArchivePath}|Out-Null

        $updated=New-TestCatalogLockInputs -Root (Join-Path $TestDrive 'ordinary-maintenance-updated') -SkillIds @('work-with-jira','new-fixture-skill')
        Copy-Item -LiteralPath $updated.CatalogPath -Destination $fixture.CatalogPath -Force
        $pins=Get-Content -Raw -Encoding UTF8 -LiteralPath $updated.PinsPath|ConvertFrom-Json
        $pins.sources[0].resolvedCommit='89abcdef0123456789abcdef0123456789abcdef'
        $pins.sources[0].resolvedVersion='1.1.0'
        [IO.File]::WriteAllText($fixture.PinsPath,(($pins|ConvertTo-Json -Depth 10)+"`n"),[Text.UTF8Encoding]::new($false))

        {& $generator -CatalogPath $fixture.CatalogPath -SourcePinsPath $fixture.PinsPath -OutputPath $fixture.OutputPath -SourceArchivePaths @{'agent-skills'=$updated.ArchivePath}|Out-Null}|Should Not Throw
        $lock=Get-Content -Raw -Encoding UTF8 -LiteralPath $fixture.OutputPath|ConvertFrom-Json
        [string]$lock.sources[0].resolvedCommit|Should Be '89abcdef0123456789abcdef0123456789abcdef'
        (@($lock.skills.id|Sort-Object)-join ',')|Should Be 'new-fixture-skill,work-with-jira'
    }
}
