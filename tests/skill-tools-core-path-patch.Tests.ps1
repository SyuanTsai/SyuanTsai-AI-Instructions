Describe 'Skill-tools core path patch' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1') -ValidatePolicyOnly | Out-Null

        function Write-PatchTestUtf8File {
            param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][string] $Text)
            $directory = [IO.Path]::GetDirectoryName($Path)
            if (-not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
            [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
        }

        function Assert-PatchFailure {
            param(
                [Parameter(Mandatory = $true)][scriptblock] $Action,
                [Parameter(Mandatory = $true)][string] $ExpectedReason
            )
            $caught = $null
            try { & $Action } catch { $caught = $_.Exception }
            $caught | Should Not BeNullOrEmpty
            $caught.Message | Should Match ([regex]::Escape($ExpectedReason))
            $caught.Message | Should Match ([regex]::Escape('removing or updating this patch'))
        }

        function New-SyntheticCoreInstall {
            param([Parameter(Mandatory = $true)][string] $Root)
            $coreRoot = Join-Path $Root 'node_modules/@skill-tools/core'
            [IO.Directory]::CreateDirectory((Join-Path $coreRoot 'dist')) | Out-Null
            Write-PatchTestUtf8File -Path (Join-Path $coreRoot 'package.json') -Text "{`"name`":`"@skill-tools/core`",`"version`":`"9.8.7`"}`n"
            $files = @(
                [pscustomobject]@{
                    relativePath = 'dist/index.js'
                    original = '${resolve(dirPath)}/'
                    replacement = '${join(resolve(dirPath), "/")}'
                    text = ("const a = '" + '${resolve(dirPath)}/' + "';`nconst b = '" + '${resolve(dirPath)}/' + "';`n")
                }
                [pscustomobject]@{
                    relativePath = 'dist/index.cjs'
                    original = '${path.resolve(dirPath)}/'
                    replacement = '${path.join(path.resolve(dirPath), "/")}'
                    text = ("const a = '" + '${path.resolve(dirPath)}/' + "';`nconst b = '" + '${path.resolve(dirPath)}/' + "';`n")
                }
            )
            $specFiles = @()
            foreach ($file in $files) {
                $path = Join-Path $coreRoot $file.relativePath
                Write-PatchTestUtf8File -Path $path -Text $file.text
                $postText = $file.text.Replace($file.original, $file.replacement)
                $specFiles += [pscustomobject][ordered]@{
                    relativePath = $file.relativePath
                    original = $file.original
                    replacement = $file.replacement
                    occurrenceCount = 2
                    preSha256 = Get-FileSha256 -Path $path
                    postSha256 = Get-BytesSha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($postText))
                }
            }
            return [pscustomobject]@{
                InstallRoot = $Root
                CoreRoot = $coreRoot
                Spec = [pscustomobject][ordered]@{
                    packageName = '@skill-tools/core'
                    packageVersion = '9.8.7'
                    files = $specFiles
                }
            }
        }
    }

    # Scenario: The exact reviewed @skill-tools/core 0.2.2 patch contract drifts in resolver source.
    # Purpose: Pin package identity, both replacements, occurrence counts, and all pre/post digests.
    It 'UnitT00_pins_the_reviewed_core_patch_specification' {
        $spec = Get-SkillToolsCorePathPatchSpec
        $spec.packageName | Should Be '@skill-tools/core'
        $spec.packageVersion | Should Be '0.2.2'
        @($spec.files).Count | Should Be 2
        $spec.files[0].relativePath | Should Be 'dist/index.js'
        $spec.files[0].original | Should Be '${resolve(dirPath)}/'
        $spec.files[0].replacement | Should Be '${join(resolve(dirPath), "/")}'
        $spec.files[0].occurrenceCount | Should Be 2
        $spec.files[0].preSha256 | Should Be 'f9c227266c695892757483b6bf9adea047d19d1b3b94992c965604d78ff66d9a'
        $spec.files[0].postSha256 | Should Be '4c2449953f3622df3e41f6a6e93d2e2c045d35ffe5ec62c5174f21a6fbb9e518'
        $spec.files[1].relativePath | Should Be 'dist/index.cjs'
        $spec.files[1].original | Should Be '${path.resolve(dirPath)}/'
        $spec.files[1].replacement | Should Be '${path.join(path.resolve(dirPath), "/")}'
        $spec.files[1].occurrenceCount | Should Be 2
        $spec.files[1].preSha256 | Should Be '1863bb6c957923c9bfee037b332ec36e485420a060874a35b337d4587dc541ca'
        $spec.files[1].postSha256 | Should Be 'bc0fa565f0150af06a6d0c7dd9848b9e14ca70307e2f15b2f37fa6d15be7e403'
    }

    # Scenario: One verified core package contains exactly the two reviewed path comparisons.
    # Purpose: Replace only those ordinal strings and return complete pre/post evidence.
    It 'UnitT10_applies_both_files_and_returns_patch_records' {
        $fixture = New-SyntheticCoreInstall -Root (Join-Path $TestDrive 'success')
        $before = @{}
        foreach ($file in $fixture.Spec.files) { $before[$file.relativePath] = [IO.File]::ReadAllText((Join-Path $fixture.CoreRoot $file.relativePath)) }
        $records = @(Invoke-SkillToolsCorePathPatch -InstallPath $fixture.InstallRoot -Spec $fixture.Spec)
        $records.Count | Should Be 2
        foreach ($file in $fixture.Spec.files) {
            $after = [IO.File]::ReadAllText((Join-Path $fixture.CoreRoot $file.relativePath))
            $after | Should Be $before[$file.relativePath].Replace($file.original, $file.replacement)
            $record = @($records | Where-Object { $_.relativePath -ceq $file.relativePath })
            $record.Count | Should Be 1
            $record[0].package | Should Be '@skill-tools/core'
            $record[0].version | Should Be '9.8.7'
            $record[0].preSha256 | Should Be $file.preSha256
            $record[0].postSha256 | Should Be $file.postSha256
        }
    }

    # Scenario: Installed bytes no longer match the pinned pre-patch digest.
    # Purpose: Reject drift before changing either target file.
    It 'UnitT20_rejects_pre_hash_drift_without_modifying_files' {
        $fixture = New-SyntheticCoreInstall -Root (Join-Path $TestDrive 'pre-hash')
        $fixture.Spec.files[0].preSha256 = '0' * 64
        $before = [IO.File]::ReadAllBytes((Join-Path $fixture.CoreRoot 'dist/index.js'))
        Assert-PatchFailure -Action { Invoke-SkillToolsCorePathPatch -InstallPath $fixture.InstallRoot -Spec $fixture.Spec } -ExpectedReason 'pre-SHA256 mismatch'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fixture.CoreRoot 'dist/index.js'))) | Should Be ([Convert]::ToBase64String($before))
    }

    # Scenario: A prior run or upstream package already contains the patched path comparison.
    # Purpose: Treat post-patch input as version drift instead of silently accepting an unreviewed state.
    It 'UnitT21_rejects_already_patched_content' {
        $fixture = New-SyntheticCoreInstall -Root (Join-Path $TestDrive 'already-patched')
        $file = $fixture.Spec.files[0]
        $path = Join-Path $fixture.CoreRoot $file.relativePath
        Write-PatchTestUtf8File -Path $path -Text ([IO.File]::ReadAllText($path).Replace($file.original, $file.replacement))
        (Get-FileSha256 -Path $path) | Should Be $file.postSha256
        Assert-PatchFailure -Action { Invoke-SkillToolsCorePathPatch -InstallPath $fixture.InstallRoot -Spec $fixture.Spec } -ExpectedReason 'already matches the pinned post-patch SHA256'
    }

    # Scenario: The discovered package claims a different npm name or version.
    # Purpose: Bind mutation to exactly the reviewed package identity.
    It 'UnitT22_rejects_package_name_or_version_drift' {
        foreach ($case in @(
            @{ Name = 'wrong-name'; Json = "{`"name`":`"other`",`"version`":`"9.8.7`"}`n" },
            @{ Name = 'wrong-version'; Json = "{`"name`":`"@skill-tools/core`",`"version`":`"9.8.8`"}`n" }
        )) {
            $fixture = New-SyntheticCoreInstall -Root (Join-Path $TestDrive $case.Name)
            Write-PatchTestUtf8File -Path (Join-Path $fixture.CoreRoot 'package.json') -Text $case.Json
            Assert-PatchFailure -Action { Invoke-SkillToolsCorePathPatch -InstallPath $fixture.InstallRoot -Spec $fixture.Spec } -ExpectedReason 'package identity mismatch'
        }
    }

    # Scenario: A target contains fewer or more path comparisons than the reviewed upstream bytes.
    # Purpose: Prevent a broad or incomplete replacement even when a synthetic pre-hash is updated.
    It 'UnitT23_rejects_one_or_three_source_occurrences' {
        foreach ($count in @(1, 3)) {
            $fixture = New-SyntheticCoreInstall -Root (Join-Path $TestDrive "count-$count")
            $file = $fixture.Spec.files[0]
            $path = Join-Path $fixture.CoreRoot $file.relativePath
            $text = ((1..$count) | ForEach-Object { "const p$_ = '" + $file.original + "';" }) -join "`n"
            Write-PatchTestUtf8File -Path $path -Text ($text + "`n")
            $file.preSha256 = Get-FileSha256 -Path $path
            Assert-PatchFailure -Action { Invoke-SkillToolsCorePathPatch -InstallPath $fixture.InstallRoot -Spec $fixture.Spec } -ExpectedReason 'string count mismatch'
        }
    }

    # Scenario: The reviewed replacement does not produce the pinned post-patch digest.
    # Purpose: Detect an incorrect patch specification before replacing installed bytes.
    It 'UnitT24_rejects_post_hash_drift' {
        $fixture = New-SyntheticCoreInstall -Root (Join-Path $TestDrive 'post-hash')
        $fixture.Spec.files[1].postSha256 = 'f' * 64
        Assert-PatchFailure -Action { Invoke-SkillToolsCorePathPatch -InstallPath $fixture.InstallRoot -Spec $fixture.Spec } -ExpectedReason 'post-SHA256 mismatch'
    }

    # Scenario: npm did not install @skill-tools/core anywhere in the dependency tree.
    # Purpose: Fail closed instead of producing an unpatched validation runtime.
    It 'UnitT25_rejects_a_missing_core_package' {
        $root = Join-Path $TestDrive 'missing'
        [IO.Directory]::CreateDirectory((Join-Path $root 'node_modules')) | Out-Null
        Assert-PatchFailure -Action { Invoke-SkillToolsCorePathPatch -InstallPath $root -Spec ([pscustomobject]@{ packageName='@skill-tools/core'; packageVersion='9.8.7'; files=@() }) } -ExpectedReason 'exactly one @skill-tools/core'
    }

    # Scenario: npm installs both the expected root dependency and another nested core copy.
    # Purpose: Refuse ambiguous dependency closures even if one package occupies the expected path.
    It 'UnitT26_rejects_a_second_nested_core_package' {
        $fixture = New-SyntheticCoreInstall -Root (Join-Path $TestDrive 'duplicate')
        $nestedParent = Join-Path $fixture.InstallRoot 'node_modules/other/node_modules/@skill-tools'
        [IO.Directory]::CreateDirectory($nestedParent) | Out-Null
        Copy-Item -Recurse -LiteralPath $fixture.CoreRoot -Destination (Join-Path $nestedParent 'core')
        Assert-PatchFailure -Action { Invoke-SkillToolsCorePathPatch -InstallPath $fixture.InstallRoot -Spec $fixture.Spec } -ExpectedReason 'exactly one @skill-tools/core'
    }
}
