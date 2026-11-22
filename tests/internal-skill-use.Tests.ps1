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
            $toolRoot = $root
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
                $toolRoot = Join-Path $script:InternalUseTrustedUnixRoot ([guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($toolRoot)
                [IO.File]::SetUnixFileMode($toolRoot, [IO.UnixFileMode]448)
            }
            $tools = foreach ($id in @('powershell', 'git')) {
                $path = Join-Path $toolRoot "$id.fixture"
                [IO.File]::WriteAllText($path, "frozen $id fixture", [Text.UTF8Encoding]::new($false))
                if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
                    [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]384)
                }
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
        $script:InternalUseTrustedUnixRoot = $null
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
            $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
            if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'A Unix user profile is required for trusted-path tests.' }
            $script:InternalUseTrustedUnixRoot = Join-Path $userProfile ('.internal-use-tests-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($script:InternalUseTrustedUnixRoot)
            [IO.File]::SetUnixFileMode($script:InternalUseTrustedUnixRoot, [IO.UnixFileMode]448)
        }
    }
    AfterAll {
        if ($null -ne $script:InternalUseTrustedUnixRoot -and (Test-Path -LiteralPath $script:InternalUseTrustedUnixRoot)) {
            Remove-Item -LiteralPath $script:InternalUseTrustedUnixRoot -Recurse -Force
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

    # Scenario: A registered approval produces an approved v1 decision on any supported host.
    # Purpose: Preserve the exact required-tools contract without leaking validator-only tool identity details.
    It 'UnitT75_ReturnsTheExactV1RequiredToolShapeAndRegistryValues' {
        $fixture = New-InternalUseFixture
        $registered = @($fixture.policy.internalUseApprovals[0].requiredTools)

        $decision = Invoke-InternalUseFixture $fixture

        $decision.status | Should -Be 'approved'
        @($decision.requiredTools).Count | Should -Be $registered.Count
        for ($index = 0; $index -lt $registered.Count; $index++) {
            (@($decision.requiredTools[$index].PSObject.Properties.Name) -join ',') | Should -Be 'id,minimumVersion'
            $decision.requiredTools[$index].id | Should -Be $registered[$index].id
            $decision.requiredTools[$index].minimumVersion | Should -Be $registered[$index].minimumVersion
        }
    }

    # Scenario: A resolved Unix tool or ancestor exposes ordinary, special, writable, or symbolic-link mode text.
    # Purpose: Evaluate permissions from numeric bits, accept harmless special bits, and reject link mode before its 0777 bits are considered.
    It 'UnitT79_ClassifiesTrustedUnixMode_<ModeLabel>' -TestCases @(
        @{ ModeLabel='0755_file'; UnixMode='-rwxr-xr-x'; Mode=493; Expected='accepted' },
        @{ ModeLabel='0777_link'; UnixMode='lrwxrwxrwx'; Mode=511; Expected='type-rejected' },
        @{ ModeLabel='4555_setuid_file'; UnixMode='-rwsr-xr-x'; Mode=2541; Expected='accepted' },
        @{ ModeLabel='1777_sticky_directory'; UnixMode='drwxrwxrwt'; Mode=1023; Expected='write-rejected' },
        @{ ModeLabel='0775_group_writable_file'; UnixMode='-rwxrwxr-x'; Mode=509; Expected='write-rejected' },
        @{ ModeLabel='0757_other_writable_file'; UnixMode='-rwxr-xrwx'; Mode=495; Expected='write-rejected' }
    ) {
        param($ModeLabel, $UnixMode, $Mode, $Expected)
        $action = {
            Assert-StandardValidationTrustedUnixMode -UnixMode $UnixMode -Mode ([uint32]$Mode) `
                -ExpectedType $(if ($UnixMode[0] -ceq 'd') { 'd' } else { '-' }) -Path '/fixture/tool' -Context 'test tool'
        }
        switch ($Expected) {
            'accepted' { $action | Should Not Throw }
            'type-rejected' {
                $message = try { & $action; $null } catch { $_.Exception.Message }
                $message | Should Match 'type could not be verified'
            }
            'write-rejected' {
                $message = try { & $action; $null } catch { $_.Exception.Message }
                $message | Should Match 'group-write or other-write'
            }
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

    # Register only on the native host because Unix package managers expose executable tools through symbolic links.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
        # Scenario: A frozen tool path is a symbolic link to the reviewed regular executable file.
        # Purpose: Bind approval to the final regular file bytes without rejecting ordinary Unix package-manager layouts.
        It 'UnitT81_AcceptsAUnixToolSymlinkToTheReviewedRegularFile' {
            $fixture = New-InternalUseFixture
            $targetPath = Join-Path $script:InternalUseTrustedUnixRoot 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path (Split-Path -Parent ([string]$fixture.tools[1].path)) 'git-link'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath | Out-Null
            $fixture.tools[1].path = $linkPath

            $decision = Invoke-InternalUseFixture $fixture
            $decision.status | Should -Be 'approved'
        }

        # Scenario: A frozen tool path is a symbolic link whose final target is a directory.
        # Purpose: Preserve the regular-file boundary after resolving an allowed Unix tool link.
        It 'UnitT82_RejectsAUnixToolSymlinkToANonRegularTarget' {
            $fixture = New-InternalUseFixture
            $parent = Split-Path -Parent ([string]$fixture.tools[1].path)
            $directoryPath = Join-Path $script:InternalUseTrustedUnixRoot 'tool-directory'
            New-Item -ItemType Directory -Path $directoryPath | Out-Null
            [IO.File]::SetUnixFileMode($directoryPath, [IO.UnixFileMode]448)
            $linkPath = Join-Path $parent 'git-directory-link'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $directoryPath | Out-Null
            $fixture.tools[1].path = $linkPath

            { Invoke-InternalUseFixture $fixture } | Should -Throw 'regular file'
        }

        # Scenario: A frozen tool link resolves to a FIFO that would block a pathname hash.
        # Purpose: Reject non-regular Unix file types before any content read or hash can open them.
        It 'UnitT83_RejectsAUnixToolSymlinkToAFifoWithoutBlocking' {
            $fifoPath = Join-Path $script:InternalUseTrustedUnixRoot 'tool-fifo'
            $mkfifo = @('/usr/bin/mkfifo', '/bin/mkfifo') | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($mkfifo)) { throw 'A native mkfifo executable is required for this Unix regression.' }
            & $mkfifo $fifoPath
            if ($LASTEXITCODE -ne 0) { throw 'The FIFO fixture could not be created.' }
            $linkPath = Join-Path $script:InternalUseTrustedUnixRoot 'fifo-link'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $fifoPath | Out-Null
            $scriptPath = Join-Path $script:InternalUseRoot 'scripts/Invoke-StandardValidation.ps1'
            $job = Start-Job -ScriptBlock {
                param($ValidationScript, $CandidateRoot, $LinkPath)
                . $ValidationScript -CandidateRoot $CandidateRoot -AdapterPath (Join-Path $CandidateRoot 'unused.json') -ArtifactsRoot $CandidateRoot -SourceRepository 'https://example.test/internal.git' -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly
                $resolved = Resolve-StandardValidationInternalUseToolPath -Path $LinkPath -Context 'internal use tool'
                Get-StandardValidationFileSha256 -Path $resolved -Context 'internal use tool'
            } -ArgumentList $scriptPath, $TestDrive, $linkPath
            try {
                Wait-Job -Job $job -Timeout 5 | Out-Null
                $job.State | Should -Not -Be 'Running'
                $job.State | Should -Be 'Failed'
                $job.ChildJobs[0].JobStateInfo.Reason.Message | Should -Match 'regular file'
            }
            finally {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }

        # Scenario: A frozen tool link resolves to a regular file writable by a non-owner class.
        # Purpose: Prevent another account from changing reviewed tool bytes after validation.
        It 'UnitT84_RejectsAUnixToolSymlinkToA_<PermissionClass>WritableFile' -TestCases @(
            @{ PermissionClass = 'Group'; Mode = [IO.UnixFileMode]400 },
            @{ PermissionClass = 'World'; Mode = [IO.UnixFileMode]386 }
        ) {
            param($PermissionClass, $Mode)
            $fixture = New-InternalUseFixture
            $targetPath = Join-Path $script:InternalUseTrustedUnixRoot ("$PermissionClass-writable-tool".ToLowerInvariant())
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, $Mode)
            $linkPath = Join-Path (Split-Path -Parent ([string]$fixture.tools[1].path)) ("$PermissionClass-writable-link".ToLowerInvariant())
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath | Out-Null
            $fixture.tools[1].path = $linkPath

            { Invoke-InternalUseFixture $fixture } | Should -Throw 'group-write or other-write'
        }

        # Scenario: A frozen tool link resolves below a group/world-writable ancestor directory.
        # Purpose: Prevent pathname replacement after hashing, including below sticky directories.
        It 'UnitT86_RejectsAUnixToolSymlinkBelowAWritableDirectory' {
            $fixture = New-InternalUseFixture
            $writableDirectory = Join-Path $script:InternalUseTrustedUnixRoot 'writable-directory'
            [void][IO.Directory]::CreateDirectory($writableDirectory)
            [IO.File]::SetUnixFileMode($writableDirectory, [IO.UnixFileMode]511)
            $targetPath = Join-Path $writableDirectory 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path (Split-Path -Parent ([string]$fixture.tools[1].path)) 'writable-directory-link'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath | Out-Null
            $fixture.tools[1].path = $linkPath

            { Invoke-InternalUseFixture $fixture } | Should -Throw 'group-write or other-write'
        }

        # Scenario: A frozen tool path is a symbolic-link cycle.
        # Purpose: Bound link traversal and fail closed instead of looping or hashing an unresolved path.
        It 'UnitT88_RejectsAUnixToolSymlinkLoop' {
            $fixture = New-InternalUseFixture
            $parent = Split-Path -Parent ([string]$fixture.tools[1].path)
            $firstLink = Join-Path $parent 'loop-a'
            $secondLink = Join-Path $parent 'loop-b'
            New-Item -ItemType SymbolicLink -Path $firstLink -Target $secondLink | Out-Null
            New-Item -ItemType SymbolicLink -Path $secondLink -Target $firstLink | Out-Null
            $fixture.tools[1].path = $firstLink

            { Invoke-InternalUseFixture $fixture } | Should -Throw 'symbolic-link chain'
        }

        # Scenario: A Homebrew-style bin link traverses user-owned 0755 directories to a reviewed Cellar executable.
        # Purpose: Preserve ordinary relative package-manager links while validating every namespace directory.
        It 'UnitT89_AcceptsAHomebrewStyleUnixToolSymlink' {
            $fixture = New-InternalUseFixture
            $root = Join-Path $script:InternalUseTrustedUnixRoot 'homebrew'
            $bin = Join-Path $root 'bin'
            $cellarBin = Join-Path $root 'Cellar/git/x/bin'
            foreach ($directory in @($root, $bin, (Join-Path $root 'Cellar'), (Join-Path $root 'Cellar/git'), (Join-Path $root 'Cellar/git/x'), $cellarBin)) {
                [void][IO.Directory]::CreateDirectory($directory)
                [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]493)
            }
            $targetPath = Join-Path $cellarBin 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path $bin 'git'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target '../Cellar/git/x/bin/git' | Out-Null
            $fixture.tools[1].path = $linkPath

            (Invoke-InternalUseFixture $fixture).status | Should -Be 'approved'
        }

        # Scenario: A distro-style usr/bin link and its target analogue are current-user-owned below 0755 directories.
        # Purpose: Accept the same safe namespace shape as a root-owned system package link without requiring root in tests.
        It 'UnitT91_AcceptsADistroStyleUnixToolSymlinkAnalogue' {
            $fixture = New-InternalUseFixture
            $root = Join-Path $script:InternalUseTrustedUnixRoot 'distro'
            $usrBin = Join-Path $root 'usr/bin'
            $libexec = Join-Path $root 'usr/libexec/git-core'
            foreach ($directory in @($root, (Join-Path $root 'usr'), $usrBin, (Join-Path $root 'usr/libexec'), $libexec)) {
                [void][IO.Directory]::CreateDirectory($directory)
                [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]493)
            }
            $targetPath = Join-Path $libexec 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path $usrBin 'git'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target '../libexec/git-core/git' | Out-Null
            $fixture.tools[1].path = $linkPath

            (Invoke-InternalUseFixture $fixture).status | Should -Be 'approved'
        }

        # Scenario: The original reviewed tool link is stored below a group- or world-writable directory while its final target remains trusted.
        # Purpose: Reject a replaceable inventory namespace even when final target ownership, mode and bytes are valid.
        It 'UnitT92_RejectsAUnixToolSymlinkBelowA_<PermissionClass>WritableOriginalParent' -TestCases @(
            @{ PermissionClass = 'Group'; Mode = [IO.UnixFileMode]509 },
            @{ PermissionClass = 'World'; Mode = [IO.UnixFileMode]495 }
        ) {
            param($PermissionClass, $Mode)
            $fixture = New-InternalUseFixture
            $root = Join-Path $script:InternalUseTrustedUnixRoot ("original-$PermissionClass".ToLowerInvariant())
            $targetDirectory = Join-Path $root 'target'
            $linkDirectory = Join-Path $root 'bin'
            foreach ($directory in @($root, $targetDirectory, $linkDirectory)) {
                [void][IO.Directory]::CreateDirectory($directory)
                [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]493)
            }
            $targetPath = Join-Path $targetDirectory 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path $linkDirectory 'git'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target '../target/git' | Out-Null
            [IO.File]::SetUnixFileMode($linkDirectory, $Mode)
            $fixture.tools[1].path = $linkPath

            { Invoke-InternalUseFixture $fixture } | Should -Throw 'group-write or other-write'
        }

        # Scenario: A trusted original link resolves through a second link stored in a writable directory to a valid final target.
        # Purpose: Validate every intermediate link namespace instead of checking only the first link and final executable.
        It 'UnitT93_RejectsAnIntermediateUnixToolSymlinkBelowAWritableParent' {
            $fixture = New-InternalUseFixture
            $root = Join-Path $script:InternalUseTrustedUnixRoot 'two-hop'
            $entryDirectory = Join-Path $root 'bin'
            $hopDirectory = Join-Path $root 'writable-hop'
            $targetDirectory = Join-Path $root 'target'
            foreach ($directory in @($root, $entryDirectory, $hopDirectory, $targetDirectory)) {
                [void][IO.Directory]::CreateDirectory($directory)
                [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]493)
            }
            $targetPath = Join-Path $targetDirectory 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $intermediateLink = Join-Path $hopDirectory 'git-hop'
            New-Item -ItemType SymbolicLink -Path $intermediateLink -Target '../target/git' | Out-Null
            $linkPath = Join-Path $entryDirectory 'git'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target '../writable-hop/git-hop' | Out-Null
            [IO.File]::SetUnixFileMode($hopDirectory, [IO.UnixFileMode]511)
            $fixture.tools[1].path = $linkPath

            { Invoke-InternalUseFixture $fixture } | Should -Throw 'group-write or other-write'
        }

        # Scenario: The link metadata owner lookup reports an account other than root or the current user while the target remains trusted.
        # Purpose: Exercise the lstat owner boundary through the existing mockable owner-lookup seam without requiring root.
        It 'UnitT94_RejectsAUnixToolSymlinkOwnedByAnotherAccount' {
            $fixture = New-InternalUseFixture
            $targetPath = Join-Path $script:InternalUseTrustedUnixRoot 'owner-target'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path (Split-Path -Parent ([string]$fixture.tools[1].path)) 'owner-link'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath | Out-Null
            $fixture.tools[1].path = $linkPath
            $script:InternalUseOwnerLinkPath = [IO.Path]::GetFullPath($linkPath)
            $script:InternalUseOwnerCurrentUid = Get-StandardValidationUnixCurrentUid -Context 'owner regression'
            Mock Get-StandardValidationUnixOwnerUid {
                param($Path, $Context)
                if ([IO.Path]::GetFullPath($Path) -ceq $script:InternalUseOwnerLinkPath) {
                    return [uint64]($script:InternalUseOwnerCurrentUid + 1)
                }
                return [uint64]$script:InternalUseOwnerCurrentUid
            }

            { Invoke-InternalUseFixture $fixture } | Should -Throw 'owned by root or the current user'
        }

        # Scenario: An inventory path traverses a parent component after a symbolic-link directory.
        # Purpose: Reject paths whose lexical normalization would disagree with POSIX symbolic-link traversal.
        It 'UnitT95_RejectsParentComponentAfterAUnixSymlinkDirectory' {
            $fixture = New-InternalUseFixture
            $root = Join-Path $script:InternalUseTrustedUnixRoot 'parent-component'
            $trusted = Join-Path $root 'trusted'
            $packageSubdirectory = Join-Path $root 'package/subdirectory'
            foreach ($directory in @($root, $trusted, (Join-Path $root 'package'), $packageSubdirectory)) {
                [void][IO.Directory]::CreateDirectory($directory)
                [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]493)
            }
            $targetPath = Join-Path (Split-Path -Parent $packageSubdirectory) 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path $trusted 'current'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $packageSubdirectory | Out-Null
            $fixture.tools[1].path = "$linkPath/../git"

            { Invoke-InternalUseFixture $fixture } | Should -Throw "INVALID|internal use tool path must be an absolute path without '.' or '..' components: $linkPath/../git"
        }

        # Scenario: An inventory path contains an explicit current-directory component.
        # Purpose: Reject non-canonical inventory paths before normalization hides the component.
        It 'UnitT96_RejectsCurrentDirectoryComponentInAUnixToolPath' {
            $fixture = New-InternalUseFixture
            $toolPath = [string]$fixture.tools[1].path
            $parent = Split-Path -Parent $toolPath
            $leaf = Split-Path -Leaf $toolPath
            $fixture.tools[1].path = "$parent/./$leaf"

            { Invoke-InternalUseFixture $fixture } | Should -Throw "INVALID|internal use tool path must be an absolute path without '.' or '..' components: $parent/./$leaf"
        }

        # Scenario: An intermediate directory link has a relative target ending in a separator.
        # Purpose: Accept a valid POSIX link target while still resolving and validating the reviewed regular file.
        It 'UnitT97_AcceptsAUnixDirectorySymlinkTargetWithATrailingSeparator' {
            $fixture = New-InternalUseFixture
            $root = Join-Path $script:InternalUseTrustedUnixRoot 'trailing-separator'
            $release = Join-Path $root 'releases/v1'
            $releaseBin = Join-Path $release 'bin'
            foreach ($directory in @($root, (Join-Path $root 'releases'), $release, $releaseBin)) {
                [void][IO.Directory]::CreateDirectory($directory)
                [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]493)
            }
            $targetPath = Join-Path $releaseBin 'git'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path $root 'current'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target 'releases/v1/' | Out-Null
            $fixture.tools[1].path = Join-Path $linkPath 'bin/git'

            (Invoke-InternalUseFixture $fixture).status | Should -Be 'approved'
        }

        # Scenario: A trusted link target traverses through a regular file before a parent component.
        # Purpose: Preserve POSIX ENOTDIR semantics instead of allowing later '..' processing to hide the invalid intermediate.
        It 'UnitT98_RejectsAUnixLinkTargetWithANonDirectoryIntermediate' {
            $fixture = New-InternalUseFixture
            $root = Join-Path $script:InternalUseTrustedUnixRoot 'non-directory-intermediate'
            [void][IO.Directory]::CreateDirectory($root)
            [IO.File]::SetUnixFileMode($root, [IO.UnixFileMode]493)
            $blockerPath = Join-Path $root 'blocker'
            [IO.File]::WriteAllText($blockerPath, 'not a directory', [Text.UTF8Encoding]::new($false))
            [IO.File]::SetUnixFileMode($blockerPath, [IO.UnixFileMode]384)
            $targetPath = Join-Path $root 'tool'
            Copy-Item -LiteralPath ([string]$fixture.tools[1].path) -Destination $targetPath
            [IO.File]::SetUnixFileMode($targetPath, [IO.UnixFileMode]384)
            $linkPath = Join-Path $root 'current'
            New-Item -ItemType SymbolicLink -Path $linkPath -Target 'blocker/../tool' | Out-Null
            $fixture.tools[1].path = $linkPath

            { Invoke-InternalUseFixture $fixture } | Should -Throw "path component is not a directory: $blockerPath"
        }
    }

    # Scenario: Package bytes change only after the initial inventory, during final authority binding.
    # Purpose: Reject late replacement, additions and deletion rather than return a stale approval.
    It 'UnitT85_RejectsPackageDriftDuringApproval_<Change>' -TestCases @(
        @{ Change = 'changed' }, @{ Change = 'added' }, @{ Change = 'removed' }
    ) {
        param($Change)
        $script:InternalUseRaceFixture = New-InternalUseFixture
        $script:InternalUseRaceChange = $Change
        $script:InternalUseRaceTriggered = $false
        Mock Get-StandardValidationFileSha256 {
            param($Path, $Context)
            if ($Context -ceq 'internal use final authority binding' -and -not $script:InternalUseRaceTriggered) {
                $script:InternalUseRaceTriggered = $true
                $file = Join-Path $script:InternalUseRaceFixture.skill 'SKILL.md'
                switch ($script:InternalUseRaceChange) {
                    changed { [IO.File]::AppendAllText($file, 'late drift') }
                    added { [IO.File]::WriteAllText((Join-Path $script:InternalUseRaceFixture.skill 'late.txt'), 'late file') }
                    removed { Remove-Item -LiteralPath $file }
                }
            }
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        { Invoke-InternalUseFixture $script:InternalUseRaceFixture } | Should -Throw
        $script:InternalUseRaceTriggered | Should -BeTrue
    }

    # Scenario: A required tool is replaced during final authority binding after its initial hash passes.
    # Purpose: Reject a decision over stale tool bytes before returning approval.
    It 'UnitT87_RejectsRequiredToolDriftDuringApproval' {
        $script:InternalUseRaceFixture = New-InternalUseFixture
        $script:InternalUseRaceTriggered = $false
        Mock Get-StandardValidationFileSha256 {
            param($Path, $Context)
            if ($Context -ceq 'internal use final authority binding' -and -not $script:InternalUseRaceTriggered) {
                $script:InternalUseRaceTriggered = $true
                [IO.File]::AppendAllText($script:InternalUseRaceFixture.tools[1].path, 'late drift')
            }
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        { Invoke-InternalUseFixture $script:InternalUseRaceFixture } | Should -Throw
        $script:InternalUseRaceTriggered | Should -BeTrue
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

Describe 'Committed internal Skill approval integration' {
    # Scenario: The committed registry is read against the actual renewed SYP-362 archive without replacing its inventory.
    # Purpose: Catch mistyped production pins/digests and protect the retained historical report and drift boundary in normal CI.
    It 'InterT10_ApprovesTheReviewedArchiveAndRejectsDriftWithTheCommittedRegistry' {
        $root = Split-Path -Parent $PSScriptRoot
        . (Join-Path $root 'scripts/Invoke-StandardValidation.ps1') -CandidateRoot $TestDrive -AdapterPath (Join-Path $TestDrive 'unused.json') -ArtifactsRoot $TestDrive -SourceRepository 'https://example.test/internal.git' -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly
        $archive = Join-Path $TestDrive 'reviewed-syp362.zip'
        Invoke-WebRequest -Uri 'https://codeload.github.com/SyuanTsai/Skill-Atlassian-Ecosystem/zip/f2a12c6338e9a76dc807c84329ffaae1aaf5bef4' -OutFile $archive -TimeoutSec 60
        $skill = Join-Path $TestDrive 'reviewed-skill'
        $files = @('SKILL.md', 'agents/openai.yaml', 'references/bitbucket-cloud-api.md', 'references/review-actions.md', 'scripts/Invoke-BitbucketReviewActions.ps1')
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($path in $files) {
                $entry = $zip.GetEntry('Skill-Atlassian-Ecosystem-f2a12c6338e9a76dc807c84329ffaae1aaf5bef4/skills/review-bitbucket-pull-request/' + $path)
                $entry | Should -Not -BeNullOrEmpty
                $target = Join-Path $skill $path
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                $inputStream = $entry.Open()
                try {
                    $outputStream = [IO.File]::Create($target)
                    try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
                }
                finally { $inputStream.Dispose() }
            }
        }
        finally { $zip.Dispose() }
        $approval = (Get-Content -Raw -LiteralPath (Join-Path $root 'docs/standards/internal-source-continuation.json') | ConvertFrom-Json -Depth 100).internalUseApprovals |
            Where-Object { $_.id -ceq 'atlassian-bitbucket-review-f2a12c6' }
        $approval | Should -Not -BeNullOrEmpty
        foreach ($file in $approval.files) {
            (Get-FileHash -LiteralPath (Join-Path $skill $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $file.sha256
        }
        $pins = @('scripts/Invoke-StandardValidation.ps1', 'docs/standards/internal-source-continuation.json', 'docs/standards/schemas/internal-source-continuation-v1.schema.json' | ForEach-Object {
            [pscustomobject]@{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
        $trustedToolRoot = $null
        try {
            $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            $gitVersion = [regex]::Match((& $git --version), '\d+\.\d+\.\d+').Value
            $powerShellExecutable = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            if (-not $IsWindows) {
                $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
                if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'A Unix user profile is required for trusted integration tools.' }
                $trustedToolRoot = Join-Path $userProfile ('.internal-use-integration-' + [guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($trustedToolRoot)
                [IO.File]::SetUnixFileMode($trustedToolRoot, [IO.UnixFileMode]448)
                $powerShellCopy = Join-Path $trustedToolRoot 'pwsh'
                $gitCopy = Join-Path $trustedToolRoot 'git'
                Copy-Item -LiteralPath $powerShellExecutable -Destination $powerShellCopy
                Copy-Item -LiteralPath $git -Destination $gitCopy
                [IO.File]::SetUnixFileMode($powerShellCopy, [IO.UnixFileMode]320)
                [IO.File]::SetUnixFileMode($gitCopy, [IO.UnixFileMode]320)
                $powerShellExecutable = $powerShellCopy
                $git = $gitCopy
            }
            $tools = @(
                [pscustomobject]@{ id = 'powershell'; version = $PSVersionTable.PSVersion.ToString(); path = $powerShellExecutable; sha256 = (Get-FileHash -LiteralPath $powerShellExecutable -Algorithm SHA256).Hash.ToLowerInvariant() },
                [pscustomobject]@{ id = 'git'; version = $gitVersion; path = $git; sha256 = (Get-FileHash -LiteralPath $git -Algorithm SHA256).Hash.ToLowerInvariant() }
            )
            $parameters = @{ SkillRoot = $skill; SourceRepository = 'https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem.git'; SourceRevision = 'f2a12c6338e9a76dc807c84329ffaae1aaf5bef4'; SkillId = 'review-bitbucket-pull-request'; Purpose = 'local-pr-review'; ExpectedAuthorityFiles = $pins; ToolInventory = $tools }
            $before = (Get-FileHash -LiteralPath (Join-Path $root 'docs/standards/internal-source-continuation.json') -Algorithm SHA256).Hash
            $decision = Resolve-StandardValidationInternalSkillUse @parameters
            $decision.status | Should -Be 'approved'
            $decision.approvalId | Should -Be 'atlassian-bitbucket-review-f2a12c6'
            $decision.contentSha256 | Should -Be 'b373f844d8c0a268f39fc1e613704cb22d3ce05136109d55c52096a9b6322e5c'
            $decision.reviewedSourceRevision | Should -Be $parameters.SourceRevision
            $decision.retainedFindings[0].reportSha256 | Should -Be '55c41e494fe318fcb0365c1addc1dd359162c1798ac67e12b8155caa2c7b16d0'
            $decision.retainedFindings[0].severity | Should -Be 'MEDIUM'
            $decision.retainedFindings[0].reportRelation | Should -Be 'historical-context'
            $decision.releaseEligible | Should -BeFalse
            (Get-FileHash -LiteralPath (Join-Path $root 'docs/standards/internal-source-continuation.json') -Algorithm SHA256).Hash | Should -Be $before
            [IO.File]::AppendAllText((Join-Path $skill 'SKILL.md'), 'unreviewed drift')
            { Resolve-StandardValidationInternalSkillUse @parameters } | Should -Throw 'not registered'
        }
        finally {
            if ($null -ne $trustedToolRoot -and (Test-Path -LiteralPath $trustedToolRoot)) {
                Remove-Item -LiteralPath $trustedToolRoot -Recurse -Force
            }
        }
    }
}
