Describe 'Standard validation resolver hardening' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ResolverPath = Join-Path $script:RepositoryRoot 'scripts\Resolve-StandardValidationTool.ps1'
        $script:ToolchainPath = Join-Path $script:RepositoryRoot 'docs\standards\validation-toolchain.json'

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

        $marker = Join-Path $TestDrive 'pth-startup-code-ran.txt'
        [IO.File]::WriteAllText(
            (Join-Path $sitePackages 'untrusted-startup.pth'),
            "import pathlib; pathlib.Path(r'$marker').write_text('executed')`n",
            (New-Object Text.UTF8Encoding($false))
        )

        $metadata = Get-InstalledPythonDistributionMetadata -VirtualEnvironmentPath $venv -DistributionName 'skillspector'
        Assert-Equal $metadata.normalizedName 'skillspector' 'Installed metadata must bind the normalized distribution name.'
        Assert-Equal $metadata.version '2.11.0' 'Installed metadata must bind the expected version.'
        Assert-False (Test-Path -LiteralPath $marker) 'Static metadata verification must not process executable .pth startup lines.'

        $resolverLines = Get-Content -Encoding UTF8 -LiteralPath $script:ResolverPath
        $codeOnly = (($resolverLines | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        Assert-NotMatch $codeOnly 'importlib\.metadata' 'Resolver code must not start installed Python for post-install version verification.'
        Assert-Match $codeOnly 'Get-InstalledPythonDistributionMetadata' 'Resolver must use static dist-info metadata verification.'
    }

    It 'UnitT20_clears_GitHub_credentials_before_any_Python_or_pip_subprocess' {
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $resolveStart = $resolver.IndexOf('function Resolve-SkillSpector')
        $resolveEnd = $resolver.IndexOf('$policy = Get-Policy', $resolveStart)
        Assert-True ($resolveStart -ge 0 -and $resolveEnd -gt $resolveStart) 'Resolve-SkillSpector body was not found.'
        $body = $resolver.Substring($resolveStart, $resolveEnd - $resolveStart)

        $clearIndex = $body.IndexOf('[Environment]::SetEnvironmentVariable(''GITHUB_TOKEN'', $null')
        $venvIndex = $body.IndexOf("'-m', 'venv'")
        $pipIndex = $body.IndexOf("'pip', 'download'")
        $restoreIndex = $body.IndexOf('[Environment]::SetEnvironmentVariable(''GITHUB_TOKEN'', $previousGitHubToken')
        Assert-True ($clearIndex -ge 0) 'GitHub token clearing was not found.'
        Assert-True ($venvIndex -gt $clearIndex) 'System Python must not start before GitHub token clearing.'
        Assert-True ($pipIndex -gt $clearIndex) 'pip must not start before GitHub token clearing.'
        Assert-True ($restoreIndex -gt $pipIndex) 'GitHub token restoration must occur only during final cleanup.'
        Assert-Match $body 'credentialIsolation=github-token-cleared-before-python' 'Resolved identity must record credential isolation.'
        Assert-Match $body "credentialIsolation = 'github-token-cleared-before-python'" 'Machine-readable receipt must expose credential isolation.'
        Assert-Match $body "installDisposition = 'ephemeral-verification'" 'Machine-readable receipt must identify the temporary install as verification-only.'
        Assert-Match $body "installedMetadataVerification = 'static-dist-info-metadata'" 'Machine-readable receipt must identify static metadata verification.'
    }

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
        Assert-Match $errorMessage 'compatibility-lane policy is incomplete or untrusted' 'Compatibility lanes must never become the canonical release gate.'
    }

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
    }

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
        Assert-NotMatch $resolver '\$output = & \$Command' 'Native execution must not re-resolve the caller-supplied command name.'
    }

    It 'UnitT70_binds_the_SkillSpector_asset_to_the_exact_GitHub_release_path' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $tag = 'v2.11.0'
        $file = 'skillspector-2.11.0-py3-none-any.whl'
        $expected = "https://github.com/NVIDIA/SkillSpector/releases/download/$tag/$file"
        Assert-Equal (Get-ApprovedSkillSpectorAssetUri -Value $expected -Tag $tag -FileName $file) $expected 'The exact GitHub release asset URI must be accepted.'

        $cases = @(
            "http://github.com/NVIDIA/SkillSpector/releases/download/$tag/$file",
            "https://example.invalid/NVIDIA/SkillSpector/releases/download/$tag/$file",
            "https://github.com/NVIDIA/SkillSpector/releases/download/$tag/$file?download=1",
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
}
