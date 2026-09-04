Describe 'License delivery packages' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../scripts/license-delivery.psm1') -Force -ErrorAction Stop
        function Write-LicenseFixture {
            param([string]$Root,[string]$Path,[string]$Text)
            $full = Join-Path $Root $Path
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [IO.File]::WriteAllText($full,$Text,(New-Object Text.UTF8Encoding($false)))
        }
        function New-LicenseFixturePackage {
            param([string]$Root,[string[]]$Paths = @('skills/one/SKILL.md'))
            New-LicenseDeliveryPackage -SourceRoot $Root -ArtifactPaths $Paths -SourceRepository 'https://example.org/skills.git' -SourceCommit ('a' * 40) -ArtifactId 'one'
        }
        function Assert-LicenseThrows {
            param([scriptblock] $Action)
            $caught = $false
            try { & $Action | Out-Null } catch { $caught = $true }
            $caught | Should Be $true
        }
    }
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-LicenseFixture $root 'skills/one/SKILL.md' '# one'
    }

    # Scenario: One selected Skill inherits root and ancestor notices and has a local license.
    # Purpose: Deliver the applicable declarations without copying another Skill's content.
    It 'UnitT10_preserves_root_ancestor_and_local_documents_with_exact_source_paths' {
        Write-LicenseFixture $root 'LICENSE' "root license`r`n"
        Write-LicenseFixture $root 'NOTICE' 'root attribution'
        Write-LicenseFixture $root 'skills/NOTICE.md' 'ancestor notice'
        Write-LicenseFixture $root 'skills/one/LICENSE' 'local license'
        Write-LicenseFixture $root 'skills/two/LICENSE' 'unrelated'
        $package = New-LicenseFixturePackage $root
        @($package.Files | Where-Object kind -eq 'source').Count | Should Be 4
        ($package.Files.sourcePath -contains 'skills/one/LICENSE') | Should Be $true
        ($package.Files.sourcePath -contains 'skills/two/LICENSE') | Should Be $false
        $license = $package.Files | Where-Object sourcePath -eq 'LICENSE'
        [Convert]::ToBase64String($license.bytes) | Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'LICENSE'))))
        $license.relativePath | Should Be 'source/LICENSE'
        $receipt = [Text.Encoding]::UTF8.GetString(($package.Files | Where-Object kind -eq 'receipt').bytes) | ConvertFrom-Json
        $receipt.sourceCommit | Should Be ('a' * 40)
        $receipt.sourceRepository | Should Be 'https://example.org/skills.git'
        $receipt.documents[0].sha256 | Should Match '^[0-9a-f]{64}$'
    }

    # Scenario: License texts live in a LICENSES directory and binary bytes must remain unchanged.
    # Purpose: Preserve alternate license layouts and nested third-party attributions.
    It 'UnitT20_includes_license_directories_and_selected_nested_notices' {
        Write-LicenseFixture $root 'LICENSES/MIT.txt' 'MIT text'
        Write-LicenseFixture $root 'skills/one/vendor/NOTICE' 'vendor attribution'
        Write-LicenseFixture $root 'skills/one/vendor/code.txt' 'code'
        $package = New-LicenseFixturePackage $root @('skills/one/SKILL.md','skills/one/vendor/code.txt')
        ($package.Files.sourcePath -contains 'LICENSES/MIT.txt') | Should Be $true
        ($package.Files.sourcePath -contains 'skills/one/vendor/NOTICE') | Should Be $true
    }

    # Scenario: A selected runtime script is named license-delivery.psm1 alongside a text declaration.
    # Purpose: Avoid classifying executable implementation code as a licensing document.
    It 'UnitT25_omits_code_files_whose_name_starts_with_license' {
        Write-LicenseFixture $root 'scripts/license-delivery.psm1' 'code'
        Write-LicenseFixture $root 'LICENSE' 'license'
        $package = New-LicenseFixturePackage $root @('scripts/license-delivery.psm1')
        @($package.Files | Where-Object kind -eq 'source').Count | Should Be 1
        $package.Files[0].sourcePath | Should Be 'LICENSE'
    }

    # Scenario: An old immutable source has no licensing declarations.
    # Purpose: Preserve legacy compatibility while explicitly reporting missing evidence.
    It 'UnitT30_reports_missing_licenses_without_inventing_a_grant' {
        $warnings = @()
        $package = New-LicenseDeliveryPackage -SourceRoot $root -ArtifactPaths @('skills/one/SKILL.md') -SourceRepository 'https://example.org/skills.git' -SourceCommit ('a' * 40) -ArtifactId 'one' -WarningVariable warnings
        $package.Status | Should Be 'missing'
        @($package.Files).Count | Should Be 0
        ($warnings -join ' ') | Should Match 'one.*missing'
        Write-LicenseFixture $root 'NOTICE' 'Attribution without a license text'
        $package = New-LicenseFixturePackage $root
        $package.Status | Should Be 'unconfirmed'
    }

    # Scenario: A per-file scope expressly withholds an additional license for the selected file.
    # Purpose: Retain the exact exclusion and warn even when a root LICENSE exists.
    It 'UnitT40_preserves_NOASSERTION_and_unlisted_scope_boundaries' {
        Write-LicenseFixture $root 'LICENSE' 'Apache text'
        Write-LicenseFixture $root 'licensing-scope.json' '{"schemaVersion":1,"files":[{"path":"skills/one/SKILL.md","license":"NOASSERTION"}]}'
        $warnings = @()
        $package = New-LicenseDeliveryPackage -SourceRoot $root -ArtifactPaths @('skills/one/SKILL.md') -SourceRepository 'https://example.org/skills.git' -SourceCommit ('a' * 40) -ArtifactId 'one' -WarningVariable warnings
        $package.Status | Should Be 'unconfirmed'
        ($warnings -join ' ') | Should Match 'NOASSERTION'
        $receipt = [Text.Encoding]::UTF8.GetString(($package.Files | Where-Object kind -eq 'receipt').bytes) | ConvertFrom-Json
        $receipt.artifacts[0].license | Should Be 'NOASSERTION'
    }

    # Scenario: Identical source bytes and identity are packaged twice.
    # Purpose: Avoid timestamps or nondeterminism that make every reconciliation an update.
    It 'UnitT50_produces_identical_bytes_for_a_repeated_package' {
        Write-LicenseFixture $root 'LICENSE' 'license'
        $first = New-LicenseFixturePackage $root
        $second = New-LicenseFixturePackage $root
        ($first.Files.sha256 -join ',') | Should Be ($second.Files.sha256 -join ',')
    }

    # Scenario: A source scope is malformed, contains duplicate/unsafe paths, or uses an unknown version.
    # Purpose: Stop before packaging ambiguous licensing metadata.
    It 'UnitT60_rejects_unknown_or_unsafe_scope_metadata' {
        Write-LicenseFixture $root 'LICENSE' 'license'
        foreach ($json in @('{"schemaVersion":2,"files":[]}','{"schemaVersion":1,"files":[{"path":"../x","license":"MIT"}]}','{"schemaVersion":1,"files":[{"path":"x","license":"MIT"},{"path":"x","license":"MIT"}]}')) {
            Write-LicenseFixture $root 'licensing-scope.json' $json
            Assert-LicenseThrows { New-LicenseFixturePackage $root }
        }
    }

    # Scenario: The caller supplies an escaping path or an invalid source commit.
    # Purpose: Keep evidence bound to an actual safe immutable source.
    It 'UnitT70_rejects_escaping_paths_and_mutable_references' {
        Assert-LicenseThrows { New-LicenseFixturePackage $root @('../LICENSE') }
        Assert-LicenseThrows { New-LicenseDeliveryPackage -SourceRoot $root -ArtifactPaths @('skills/one/SKILL.md') -SourceRepository 'https://example.org/skills.git' -SourceCommit 'main' -ArtifactId 'one' }
    }

    # Scenario: A license is exposed through a symbolic link outside the source.
    # Purpose: Prevent packaging bytes outside the verified archive boundary.
    It 'UnitT80_rejects_reparse_points_before_reading_source_documents' {
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Force -Path $outside | Out-Null
        $link = Join-Path $root 'LICENSES'
        $kind = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $kind -Path $link -Target $outside -ErrorAction Stop | Out-Null
        Assert-LicenseThrows { New-LicenseFixturePackage $root }
    }
}
