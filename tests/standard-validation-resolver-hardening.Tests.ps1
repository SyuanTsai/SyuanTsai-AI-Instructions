Describe 'Standard validation resolver hardening' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ResolverPath = Join-Path $script:RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1'
        $script:ToolchainPath = Join-Path $script:RepositoryRoot 'docs/standards/validation-toolchain.json'
        $script:LifecyclePath = Join-Path $script:RepositoryRoot 'docs/standards/managed-skill-lifecycle.md'
        $script:LifecycleSchemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'
        $script:ValidationSecurityGatePath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'

        function Assert-True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Assert-False {
            param([bool] $Condition, [string] $Message)
            if ($Condition) { throw $Message }
        }

        function Assert-Equal {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Assert-Match {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -notmatch $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Assert-NotMatch {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -match $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function New-TestWheel {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [Parameter(Mandatory = $true)][string] $Name,
                [Parameter(Mandatory = $true)][string] $Version
            )

            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $distName = ($Name -replace '[-.]', '_')
            $metadata = "Metadata-Version: 2.4`nName: $Name`nVersion: $Version`n"
            $wheelPath = Join-Path $Root ("$distName-$Version-py3-none-any.whl")
            $archive = [IO.Compression.ZipFile]::Open($wheelPath, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $archive.CreateEntry("$distName-$Version.dist-info/METADATA")
                $stream = $entry.Open()
                try {
                    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($metadata)
                    $stream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $stream.Dispose()
                }
            }
            finally {
                $archive.Dispose()
            }
            return $wheelPath
        }
    }

    # Scenario: An installed wheel places executable startup code in a .pth file next to valid dist-info metadata.
    # Purpose: Verify installed identity and entry-point metadata without starting that interpreter or processing .pth code.
    It 'UnitT10_reads_installed_dist_info_without_processing_pth_startup_code' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $venv = Join-Path $TestDrive 'metadata-only-venv'
        $sitePackages = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            Join-Path $venv 'Lib\site-packages'
        }
        else {
            Join-Path $venv 'lib/python3.12/site-packages'
        }
        [void](New-Item -ItemType Directory -Path $sitePackages -Force)

        $distInfo = Join-Path $sitePackages 'skillspector-2.11.0.dist-info'
        [void](New-Item -ItemType Directory -Path $distInfo -Force)
        [IO.File]::WriteAllText(
            (Join-Path $distInfo 'METADATA'),
            "Metadata-Version: 2.4`nName: SkillSpector`nVersion: 2.11.0`n",
            (New-Object Text.UTF8Encoding($false))
        )
        [IO.File]::WriteAllText(
            (Join-Path $distInfo 'entry_points.txt'),
            "[console_scripts]`nskillspector = skillspector.cli:main`n",
            (New-Object Text.UTF8Encoding($false))
        )

        $marker = Join-Path $TestDrive 'pth-startup-code-ran.txt'
        [IO.File]::WriteAllText(
            (Join-Path $sitePackages 'untrusted-startup.pth'),
            "import pathlib; pathlib.Path(r'$marker').write_text('executed')`n",
            (New-Object Text.UTF8Encoding($false))
        )

        $metadata = Get-InstalledPythonDistributionMetadata -VirtualEnvironmentPath $venv -DistributionName 'skillspector'
        Assert-Equal $metadata.normalizedName 'skillspector' 'Installed metadata must bind the normalized distribution name.'
        Assert-Equal $metadata.version '2.11.0' 'Installed metadata must bind the expected version.'
        Assert-Equal $metadata.consoleEntryPoint 'skillspector.cli:main' 'Installed metadata must bind the exact console entry-point target.'
        Assert-False (Test-Path -LiteralPath $marker) 'Static metadata verification must not process executable .pth startup lines.'

        $resolverLines = Get-Content -Encoding UTF8 -LiteralPath $script:ResolverPath
        $codeOnly = (($resolverLines | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        Assert-NotMatch $codeOnly 'importlib\.metadata' 'Resolver code must not start installed Python for post-install version verification.'
        Assert-Match $codeOnly 'Get-InstalledPythonDistributionMetadata' 'Resolver must use static dist-info metadata verification.'
    }

    # Scenario: The release API needs a GitHub token before resolver-managed Python and offline pip execute.
    # Purpose: Ensure credentials are removed before the first Python subprocess and are not restored by the resolver.
    It 'UnitT20_clears_GitHub_credentials_before_any_Python_or_pip_subprocess' {
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $resolveStart = $resolver.IndexOf('function Resolve-SkillSpector')
        $resolveEnd = $resolver.IndexOf('$policy = Get-Policy', $resolveStart)
        Assert-True ($resolveStart -ge 0 -and $resolveEnd -gt $resolveStart) 'Resolve-SkillSpector body was not found.'
        $body = $resolver.Substring($resolveStart, $resolveEnd - $resolveStart)

        $clearIndex = $body.IndexOf("Remove-Item -LiteralPath 'Env:GITHUB_TOKEN'")
        $venvIndex = $body.IndexOf("'-S', '-m', 'venv'")
        $helperIndex = $body.IndexOf('Resolve-PythonWheelClosureFromApprovedIndex')
        $restoreIndex = $body.IndexOf("SetEnvironmentVariable('GITHUB_TOKEN'")
        Assert-True ($clearIndex -ge 0) 'GitHub token clearing was not found.'
        Assert-True ($venvIndex -gt $clearIndex) 'System Python must not start before GitHub token clearing.'
        Assert-True ($helperIndex -gt $clearIndex) 'Approved-index candidate resolution must not start before GitHub token clearing.'
        Assert-True ($restoreIndex -lt 0) 'The resolver must not restore GitHub credentials after third-party code becomes reachable.'
        Assert-Match $body 'credentialIsolation=github-token-cleared-before-python' 'Resolved identity must record credential isolation.'
        Assert-Match $body 'resolutionRounds=\$\(\$backtrackingEvidence\.resolutionRounds\)' 'Resolved identity must bind offline resolution rounds.'
        Assert-Match $body 'consoleEntryPoint=\$consoleEntryPoint' 'Resolved identity must bind the statically verified console entry point.'
        Assert-Match $body "credentialIsolation = 'github-token-cleared-before-python'" 'Machine-readable receipt must expose credential isolation.'
        Assert-Match $body "installedMetadataVerification = 'static-dist-info-metadata'" 'Machine-readable receipt must identify static metadata verification.'
    }

    # Scenario: Compatibility-only Pester lanes are changed so they can become the canonical release gate.
    # Purpose: Keep older pinned lanes explicitly non-canonical under the strict typed policy contract.
    It 'UnitT30_rejects_a_compatibility_lane_that_can_become_the_canonical_gate' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.compatibilityLane.mayBeCanonicalReleaseGate = $true
        $tamperedPath = Join-Path $TestDrive 'tampered-compatibility-lane.json'
        [IO.File]::WriteAllText(
            $tamperedPath,
            ($toolchain | ConvertTo-Json -Depth 20),
            (New-Object Text.UTF8Encoding($false))
        )

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $tamperedPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'mayBeCanonicalReleaseGate.*False' 'Compatibility lanes must never become the canonical release gate.'
    }

    # Scenario: Dependency names arrive in mixed case and non-ordinal discovery order.
    # Purpose: Keep closure identity deterministic across hosts and cultures.
    It 'UnitT40_orders_dependency_closure_identity_with_ordinal_normalized_names' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $wheelhouse = Join-Path $TestDrive 'ordinal-wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse -Force)
        [void](New-TestWheel -Root $wheelhouse -Name 'zeta-package' -Version '1.0.0')
        [void](New-TestWheel -Root $wheelhouse -Name 'Alpha-package' -Version '1.0.0')
        [void](New-TestWheel -Root $wheelhouse -Name 'beta-package' -Version '1.0.0')
        $lockPath = Join-Path $TestDrive 'ordinal-lock.txt'

        $manifest = New-PythonWheelhouseLock -WheelhousePath $wheelhouse -LockPath $lockPath
        $actualOrder = (@($manifest.entries | ForEach-Object { $_.normalizedName }) -join ',')
        Assert-Equal $actualOrder 'alpha-package,beta-package,zeta-package' 'Dependency closure order must be deterministic ordinal order.'
        Assert-Match $manifest.closureSha256 '^[0-9a-f]{64}$' 'Dependency closure must retain a deterministic SHA-256 identity.'
    }

    # Scenario: Wheel metadata contains unsafe identity text, duplicate headers or body text that resembles headers.
    # Purpose: Reject unsafe or ambiguous header identity without parsing description-body content as metadata.
    It 'UnitT50_rejects_unsafe_or_ambiguous_metadata_identity_text_before_lock_generation' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $cases = @(
            @{ Text = "Name: unsafe/package`nVersion: 1.0.0`n"; Pattern = 'unsafe Python distribution Name' },
            @{ Text = "Name: safe-package`nVersion: 1.0.0;--hash=sha256:00`n"; Pattern = 'unsafe Python distribution Version' },
            @{ Text = "Name: safe-package`nName: other-package`nVersion: 1.0.0`n"; Pattern = 'exactly one Name field and one Version field' },
            @{ Text = "Name: safe-package`nVersion: 1.0.0`nVersion: 2.0.0`n"; Pattern = 'exactly one Name field and one Version field' },
            @{ Text = "Name: safe-package`n"; Pattern = 'exactly one Name field and one Version field' }
        )
        foreach ($case in $cases) {
            $errorMessage = $null
            try {
                ConvertFrom-PythonMetadataText -Text $case.Text -Context 'Test METADATA' | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            Assert-Match $errorMessage $case.Pattern 'Unsafe or ambiguous metadata identity text must fail closed.'
        }

        $bodyText = @"
Metadata-Version: 2.4
Name: safe-package
Version: 1.0.0

Name: this line belongs to the description body
Version: this line also belongs to the description body
"@
        $bodyMetadata = ConvertFrom-PythonMetadataText -Text $bodyText -Context 'Body-text METADATA'
        Assert-Equal $bodyMetadata.normalizedName 'safe-package' 'Description-body Name text must not be treated as a second metadata header.'
        Assert-Equal $bodyMetadata.version '1.0.0' 'Description-body Version text must not be treated as a second metadata header.'
    }

    # Scenario: A function or alias shadows a native prerequisite name in PowerShell command resolution.
    # Purpose: Resolve and execute only an absolute native application path.
    It 'UnitT60_resolves_only_native_applications_and_ignores_command_shadowing' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        Set-Item -Path Function:shadowed-standard-tool -Value { 'function-shadow' }
        Set-Alias -Name shadowed-standard-alias -Value Get-Date
        try {
            foreach ($name in @('shadowed-standard-tool', 'shadowed-standard-alias')) {
                $errorMessage = $null
                try {
                    Assert-Command -Name $name | Out-Null
                }
                catch {
                    $errorMessage = $_.Exception.Message
                }
                Assert-Match $errorMessage 'Required native command.*is unavailable' "PowerShell command shadow '$name' must not satisfy a native prerequisite."
            }
        }
        finally {
            Remove-Item Function:shadowed-standard-tool -ErrorAction SilentlyContinue
            Remove-Item Alias:shadowed-standard-alias -ErrorAction SilentlyContinue
        }

        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        Assert-Match $resolver 'Get-Command -Name \$Name -CommandType Application' 'Native prerequisite lookup must exclude functions, aliases, cmdlets and external scripts.'
        Assert-Match $resolver '\$output = & \$commandPath' 'Native execution must use the resolved absolute application path.'
        Assert-NotMatch $resolver '\$output\s*=\s*&\s*\$Command(?![A-Za-z0-9_])' 'Native execution must not re-resolve the caller-supplied command name.'
        Assert-Match $resolver '(?s)\$global:LASTEXITCODE\s*=\s*\$null\s*\r?\n\s*\$output\s*=\s*&\s*\$commandPath.*?\$exitCode\s*=\s*\$global:LASTEXITCODE.*?\$null -eq \$exitCode' 'Native launch failure must not inherit a stale successful exit code.'

        $invalidNativePath = Join-Path $TestDrive $(if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'invalid-native.exe' } else { 'invalid-native' })
        [IO.File]::WriteAllBytes($invalidNativePath, [byte[]]@(0, 1, 2, 3))
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            $chmodCommand = Assert-Command -Name 'chmod'
            $global:LASTEXITCODE = $null
            & $chmodCommand '+x' $invalidNativePath
            if ($global:LASTEXITCODE -ne 0) { throw 'Unable to prepare invalid native launch fixture.' }
        }
        $global:LASTEXITCODE = 0
        $launchError = $null
        try { Invoke-CheckedCommand -Command $invalidNativePath -Arguments @('--probe') | Out-Null }
        catch { $launchError = $_.Exception.Message }
        Assert-True (-not [string]::IsNullOrWhiteSpace($launchError)) 'A native launch failure must not inherit a stale successful exit code.'

        $pythonCommand = Assert-Command -Name 'python'
        $commandOutput = @(Invoke-CheckedCommand -Command $pythonCommand -Arguments @(
            '-c', "import sys; print('resolver-stderr', file=sys.stderr); print('resolver-stdout')"
        ))
        Assert-Equal $commandOutput.Count 1 'A single stderr line must remain an array and must not corrupt stdout capture.'
        Assert-Equal $commandOutput[0] 'resolver-stdout' 'Native stdout must remain available when one diagnostic line is written to stderr.'
    }

    # Scenario: Release metadata points the expected wheel name at another host, port, tag or URL variant.
    # Purpose: Bind asset acquisition to the exact approved GitHub release path before digest verification.
    It 'UnitT70_binds_the_SkillSpector_asset_to_the_exact_GitHub_release_path' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $tag = 'v2.11.0'
        $file = 'skillspector-2.11.0-py3-none-any.whl'
        $expected = "https://github.com/NVIDIA/SkillSpector/releases/download/$tag/$file"
        Assert-Equal (Get-ApprovedSkillSpectorAssetUri -Value $expected -Tag $tag -FileName $file) $expected 'The exact GitHub release asset URI must be accepted.'

        $cases = @(
            "http://github.com/NVIDIA/SkillSpector/releases/download/$tag/$file",
            "https://example.invalid/NVIDIA/SkillSpector/releases/download/$tag/$file",
            "https://github.com/NVIDIA/SkillSpector/releases/download/$tag/${file}?download=1",
            "https://github.com/NVIDIA/SkillSpector/releases/download/v2.10.0/$file",
            "https://user@github.com/NVIDIA/SkillSpector/releases/download/$tag/$file",
            "https://github.com:444/NVIDIA/SkillSpector/releases/download/$tag/$file"
        )
        foreach ($value in $cases) {
            $errorMessage = $null
            try {
                Get-ApprovedSkillSpectorAssetUri -Value $value -Tag $tag -FileName $file | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            Assert-Match $errorMessage 'Untrusted SkillSpector release asset URI' "Untrusted release asset URI '$value' must fail closed."
        }
    }

    # Scenario: A resolver change introduces a second lifecycle policy or detaches lifecycle evidence from Standard v1.
    # Purpose: Ensure resolver hardening keeps lifecycle semantics in the central standards authority and does not replace them.
    It 'UnitT80_keeps_managed_lifecycle_policy_outside_the_validation_tool_resolver' {
        Assert-True (Test-Path -LiteralPath $script:LifecyclePath -PathType Leaf) 'Managed lifecycle policy must remain in the central standards directory.'
        Assert-True (Test-Path -LiteralPath $script:LifecycleSchemaPath -PathType Leaf) 'Managed lifecycle evidence schema must remain in the central standards directory.'
        $lifecycle = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:LifecyclePath
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:LifecycleSchemaPath | ConvertFrom-Json
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath

        Assert-Match $lifecycle 'destructiveChangeAllowed' 'Lifecycle policy must define explicit destructive-change evidence.'
        Assert-Match $lifecycle 'transaction-owned staged snapshot' 'Lifecycle policy must define transaction-owned candidate staging.'
        Assert-Equal $schema.title 'Managed Skill lifecycle evidence v1' 'Lifecycle evidence schema must remain the v1 central contract.'
        Assert-NotMatch $resolver 'function (Resolve|Invoke)-ManagedSkillLifecycle' 'Validation tool resolver must not grow a repository-local lifecycle policy entry point.'
    }

    # Scenario: Plugin or marketplace support is added to the validation-tool resolver as an implicit policy path.
    # Purpose: Keep upstream packaging and MCP discovery in the central adapter decision record rather than a second resolver policy.
    It 'UnitT90_keeps_upstream_packaging_and_discovery_outside_the_validation_tool_resolver' {
        $upstreamPath = Join-Path $script:RepositoryRoot 'docs/standards/upstream-interoperability.md'
        Assert-True (Test-Path -LiteralPath $upstreamPath -PathType Leaf) 'Upstream interoperability policy must remain in the central standards directory.'
        $upstream = Get-Content -Raw -Encoding UTF8 -LiteralPath $upstreamPath
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath

        Assert-Match $upstream 'adapter' 'Upstream packaging must be described as an explicit adapter boundary.'
        Assert-Match $upstream 'dynamic.*discovery' 'Dynamic MCP discovery must be explicitly bounded.'
        Assert-NotMatch $resolver '\.codex-plugin/plugin\.json|\.mcp\.json|marketplace\.json' 'Validation-tool resolution must not become an upstream packaging or marketplace policy engine.'
    }

    # Scenario: Canonical validation/security ordering is implemented as a second resolver policy.
    # Purpose: Keep the stage/severity authority in the central gate policy and prevent provider resolution from inventing pass/block semantics.
    It 'UnitT100_keeps_canonical_validation_security_policy_in_the_central_authority_gate' {
        Assert-True (Test-Path -LiteralPath $script:ValidationSecurityGatePath -PathType Leaf) 'Canonical validation/security policy must remain in the central standards directory.'
        Assert-True (Test-Path -LiteralPath $script:AuthorityGatePath -PathType Leaf) 'Canonical authority gate must remain available.'
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath

        Assert-Equal $policy.policy 'canonical-validation-security-gate-v1' 'Canonical validation/security policy identity must remain central.'
        Assert-Match $gate 'Assert-AuthorityValidationSecurityGate' 'Authority gate must enforce the canonical validation/security policy.'
        Assert-Match $gate 'validation-security-gate\.json' 'Authority gate must load the canonical validation/security policy.'
        Assert-Match $gate 'Package Validation' 'Authority gate must identify the Package Validation stage.'
        Assert-Match $gate 'SkillSpector Static' 'Authority gate must identify the SkillSpector Static stage.'
        Assert-NotMatch $resolver 'canonical-validation-security-gate-v1|Assert-AuthorityValidationSecurityGate' 'Validation-tool resolver must not become a stage/severity policy engine.'
    }
}
