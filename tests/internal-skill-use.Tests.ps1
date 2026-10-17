# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Internal Skill use approvals' {
    BeforeAll {
        $script:InternalUseRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:InternalUseRoot 'scripts/Invoke-StandardValidation.ps1') -CandidateRoot $TestDrive -AdapterPath (Join-Path $TestDrive 'unused.json') -ArtifactsRoot $TestDrive -SourceRepository 'https://example.test/internal.git' -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly
        function New-InternalUseFixture {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $authority = Join-Path $root 'authority'
            $skill = Join-Path $root 'skill'
            [void][IO.Directory]::CreateDirectory($skill)
            [IO.File]::WriteAllText((Join-Path $skill 'SKILL.md'), 'internal review fixture', [Text.UTF8Encoding]::new($false))
            $paths = @('scripts/Invoke-StandardValidation.ps1', 'docs/standards/internal-source-continuation.json', 'docs/standards/schemas/internal-source-continuation-v1.schema.json')
            foreach ($path in $paths) {
                $target = Join-Path $authority $path
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                Copy-Item -LiteralPath (Join-Path $script:InternalUseRoot $path) -Destination $target
            }
            $policyPath = Join-Path $authority $paths[1]
            $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -Depth 100
            $entry = $policy.internalUseApprovals[0]
            $entry.sourceRepository = 'https://github.com/example/internal-skills.git'
            $entry.sourceRevision = 'a' * 40
            $entry.skillId = 'review-fixture'
            $entry.id = 'review-fixture-v1'
            $entry.review.owner = 'internal-maintainer'
            $entry.review.reviewedAt = '2026-01-01'
            $entry.review.expiresAt = '2099-01-01'
            $inventory = Get-StandardValidationInventory -Root $skill -Context 'test package'
            $entry.files = @($inventory | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.sha256 } })
            $entry.contentSha256 = Get-StandardValidationInventorySha256 -Inventory $inventory
            $policy | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $policyPath -Encoding utf8NoBOM
            $tools = foreach ($id in @('powershell', 'git')) {
                $path = Join-Path $root "$id.fixture"
                [IO.File]::WriteAllText($path, "frozen $id fixture", [Text.UTF8Encoding]::new($false))
                [pscustomobject]@{ id = $id; version = '7.6.6'; path = $path; sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            [pscustomobject]@{ authority = $authority; skill = $skill; policyPath = $policyPath; policy = $policy; tools = @($tools); paths = $paths }
        }
        function Save-InternalUsePolicy {
            param($Fixture)
            $Fixture.policy | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Fixture.policyPath -Encoding utf8NoBOM
        }
        function Get-InternalUsePins {
            param($Fixture)
            @($Fixture.paths | ForEach-Object { [pscustomobject]@{ path = $_; sha256 = (Get-FileHash (Join-Path $Fixture.authority $_) -Algorithm SHA256).Hash.ToLowerInvariant() } })
        }
        function Invoke-InternalUseFixture {
            param($Fixture, [hashtable] $Override = @{})
            $parameters = @{
                SkillRoot = $Fixture.skill; SourceRepository = 'https://github.com/example/internal-skills.git'
                SourceRevision = ('a' * 40); SkillId = 'review-fixture'; Purpose = 'local-pr-review'
                ExpectedAuthorityFiles = @(Get-InternalUsePins $Fixture); ToolInventory = $Fixture.tools
            }
            foreach ($key in $Override.Keys) { $parameters[$key] = $Override[$key] }
            $previous = $script:StandardValidationRepositoryRoot
            try {
                $script:StandardValidationRepositoryRoot = $Fixture.authority
                Resolve-StandardValidationInternalSkillUse @parameters
            }
            finally { $script:StandardValidationRepositoryRoot = $previous }
        }
    }
    # Scenario: A consumer requests the new internal-use reader from its pinned central runner.
    # Purpose: Require an executable reader; a review-only consistency assessment cannot authorize internal use.
    It 'UnitT10_ExposesTheInternalUseReader' {
        Get-Command Resolve-StandardValidationInternalSkillUse -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    # Scenario: The exact reviewed package, local use, pinned authority and frozen tools match.
    # Purpose: Permit that internal use while retaining the MEDIUM and independent release/action boundary.
    It 'UnitT20_ApprovesExactInternalUseAndPreservesTheFinding' {
        $fixture = New-InternalUseFixture
        $before = (Get-FileHash $fixture.policyPath -Algorithm SHA256).Hash
        $decision = Invoke-InternalUseFixture $fixture
        $decision.status | Should -Be 'approved'
        $decision.authorizationGranted | Should -BeTrue
        ($decision.authorizedOperations -join ',') | Should -Be 'local-pr-review'
        $decision.retainedFindings[0].severity | Should -Be 'MEDIUM'
        $decision.retainedFindings[0].reportRelation | Should -Be 'historical-context'
        $decision.hostToolPreauthorization | Should -BeFalse
        $decision.requiresExactTargetActionAuthorization | Should -BeTrue
        $decision.releaseEligible | Should -BeFalse
        (Get-FileHash $fixture.policyPath -Algorithm SHA256).Hash | Should -Be $before
    }

    # Scenario: A caller names another repository/Skill or a non-immutable current source revision.
    # Purpose: Prevent an internal approval from extending to an unregistered source identity.
    It 'UnitT30_RejectsUnregisteredSourceIdentity' {
        foreach ($override in @(@{SourceRepository='https://github.com/example/other.git'}, @{SkillId='other-skill'})) {
            $fixture = New-InternalUseFixture
            { Invoke-InternalUseFixture $fixture $override } | Should -Throw 'not registered'
        }
        { Invoke-InternalUseFixture (New-InternalUseFixture) @{SourceRevision='main'} } | Should -Throw
    }

    # Scenario: A consumer changes only its reader/repository revision while the entire reviewed Skill package stays byte-identical.
    # Purpose: Avoid a central/consumer repinning cycle without extending approval to changed Skill bytes or hiding review provenance.
    It 'UnitT35_AcceptsIdenticalPackageContentAtAnotherImmutableSourceRevision' {
        $fixture = New-InternalUseFixture
        $decision = Invoke-InternalUseFixture $fixture @{SourceRevision=('b'*40)}
        $decision.status | Should -Be 'approved'
        $decision.sourceRevision | Should -Be ('b'*40)
        $decision.reviewedSourceRevision | Should -Be ('a'*40)
        $decision.contentSha256 | Should -Be $fixture.policy.internalUseApprovals[0].contentSha256
    }

    # Scenario: A caller requests publication, installation or an API mutation using a local-review approval.
    # Purpose: Keep internal registration separate from operation-specific human authorization and release.
    It 'UnitT40_RejectsUnapprovedPurposes' {
        $fixture = New-InternalUseFixture
        foreach ($purpose in @('Create', 'Reply', 'Resolve', 'install', 'release', 'local-pr-review*')) {
            { Invoke-InternalUseFixture $fixture @{Purpose=$purpose} } | Should -Throw 'not approved'
        }
    }

    # Scenario: A file changes, is added, or is removed after package review.
    # Purpose: Require complete exact package bytes, not just SKILL.md or a caller content claim.
    It 'UnitT50_RejectsChangedAddedOrRemovedPackageFiles' {
        foreach ($change in @('changed', 'added', 'removed')) {
            $fixture = New-InternalUseFixture
            $file = Join-Path $fixture.skill 'SKILL.md'
            switch ($change) {
                changed { [IO.File]::WriteAllText($file, 'drifted') }
                added { [IO.File]::WriteAllText((Join-Path $fixture.skill 'extra.ps1'), 'drifted') }
                removed { Remove-Item -LiteralPath $file }
            }
            { Invoke-InternalUseFixture $fixture } | Should -Throw
        }
    }

    # Scenario: Authority bytes differ from the trusted reader pins, or a required pin is missing/duplicated.
    # Purpose: Reject a local replacement registry, schema or runner instead of accepting its declarations.
    It 'UnitT60_RejectsAuthorityDriftAndMissingOrDuplicatePins' {
        foreach ($path in @('scripts/Invoke-StandardValidation.ps1', 'docs/standards/internal-source-continuation.json', 'docs/standards/schemas/internal-source-continuation-v1.schema.json')) {
            $fixture = New-InternalUseFixture
            $pins = Get-InternalUsePins $fixture
            [IO.File]::AppendAllText((Join-Path $fixture.authority $path), 'drifted')
            { Invoke-InternalUseFixture $fixture @{ExpectedAuthorityFiles=$pins} } | Should -Throw 'drifted'
        }
        $fixture = New-InternalUseFixture
        $pins = Get-InternalUsePins $fixture
        { Invoke-InternalUseFixture $fixture @{ExpectedAuthorityFiles=@($pins[0],$pins[1])} } | Should -Throw 'Missing'
        { Invoke-InternalUseFixture $fixture @{ExpectedAuthorityFiles=@($pins)+@($pins[0])} } | Should -Throw 'Duplicate'
    }

    # Scenario: A review is revoked, expired, incomplete or attempts to allow a wildcard purpose.
    # Purpose: Make the human disposition and finite approved scope mandatory registry data.
    It 'UnitT70_RejectsRevokedExpiredOrMalformedApprovals' {
        foreach ($change in @('revoked', 'expired', 'missing-evidence', 'wildcard', 'duplicate')) {
            $fixture = New-InternalUseFixture
            $entry = $fixture.policy.internalUseApprovals[0]
            switch ($change) {
                revoked { $entry.status = 'revoked' }
                expired { $entry.review.expiresAt = '2020-01-01' }
                missing-evidence { $entry.review.evidence = @() }
                wildcard { $entry.permittedUses = @('*') }
                duplicate { $fixture.policy.internalUseApprovals += $entry }
            }
            Save-InternalUsePolicy $fixture
            { Invoke-InternalUseFixture $fixture } | Should -Throw
        }
    }

    # Scenario: A needed tool is absent, changed, too old or duplicated in the frozen consumer inventory.
    # Purpose: Keep dependency readiness bound to real file identities without downloading or executing them.
    It 'UnitT80_RejectsMissingChangedOldOrDuplicateTools' {
        foreach ($change in @('missing', 'changed', 'old', 'duplicate')) {
            $fixture = New-InternalUseFixture
            switch ($change) {
                missing { $fixture.tools = @($fixture.tools[0]) }
                changed { [IO.File]::AppendAllText($fixture.tools[1].path, 'changed') }
                old { $fixture.tools[0].version = '1.0' }
                duplicate { $fixture.tools += $fixture.tools[0] }
            }
            { Invoke-InternalUseFixture $fixture } | Should -Throw
        }
    }

    # Scenario: A previously valid review-only registry has no internal-use approval section.
    # Purpose: Preserve old assessment compatibility without silently treating it as permission to use a Skill.
    It 'UnitT90_RejectsReviewOnlyRegistryAsInternalUseApproval' {
        $fixture = New-InternalUseFixture
        $fixture.policy.PSObject.Properties.Remove('internalUseApprovals')
        Save-InternalUsePolicy $fixture
        { Invoke-InternalUseFixture $fixture } | Should -Throw 'No internal use approvals'
    }
}
