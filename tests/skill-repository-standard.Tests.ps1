Describe 'Agent Skill Repository Standard v1 contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:StandardsRoot = Join-Path $script:RepositoryRoot 'docs\standards'
        $script:IndexPath = Join-Path $script:StandardsRoot 'README.md'
        $script:StandardPath = Join-Path $script:StandardsRoot 'skill-repository-standard.md'
        $script:MatrixPath = Join-Path $script:StandardsRoot 'skill-repository-review-matrix.md'
        $script:ToolchainPath = Join-Path $script:StandardsRoot 'validation-toolchain.json'
        $script:ResolverPath = Join-Path $script:RepositoryRoot 'scripts\Resolve-StandardValidationTool.ps1'
        $script:WorkflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $script:RequiredPowerShellWorkflowPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'

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
                [Parameter(Mandatory = $true)][string] $Version,
                [string[]] $RequiresDist = @()
            )

            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $distName = ($Name -replace '-', '_')
            $metadata = "Metadata-Version: 2.4`nName: $Name`nVersion: $Version`n"
            foreach ($requirement in $RequiresDist) {
                $metadata += "Requires-Dist: $requirement`n"
            }
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

    It 'UnitT10_keeps_the_normative_standard_evidence_toolchain_and_resolver_together' {
        Assert-True (Test-Path -LiteralPath $script:IndexPath -PathType Leaf) 'Missing standards index.'
        Assert-True (Test-Path -LiteralPath $script:StandardPath -PathType Leaf) 'Missing normative Standard.'
        Assert-True (Test-Path -LiteralPath $script:MatrixPath -PathType Leaf) 'Missing cross-repository review matrix.'
        Assert-True (Test-Path -LiteralPath $script:ToolchainPath -PathType Leaf) 'Missing validation toolchain policy.'
        Assert-True (Test-Path -LiteralPath $script:ResolverPath -PathType Leaf) 'Missing central validation tool resolver.'
        Assert-True (Test-Path -LiteralPath $script:WorkflowPath -PathType Leaf) 'Missing Standards Conformance workflow.'
        Assert-True (Test-Path -LiteralPath $script:RequiredPowerShellWorkflowPath -PathType Leaf) 'Missing required PowerShell workflow authority bridge.'

        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        Assert-Match $index 'skill-repository-standard\.md' 'Standards index must link the normative Standard.'
        Assert-Match $index 'skill-repository-review-matrix\.md' 'Standards index must link the review matrix.'
        Assert-Match $index 'validation-toolchain\.json' 'Standards index must link the toolchain policy.'
        Assert-Match $index 'Resolve-StandardValidationTool\.ps1' 'Standards index must name the central validation tool resolver.'
    }

    # Scenario: The authority policy is loaded with every supported validation provider and distribution control.
    # Purpose: Protect the complete latest-stable source, endpoint, and cache-isolation trust contract.
    It 'UnitT20_requires_latest_stable_tools_trusted_sources_and_resolved_identity_evidence' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json

        Assert-Equal $toolchain.schemaVersion 1 'Unexpected toolchain schemaVersion.'
        Assert-Equal $toolchain.policy 'latest-stable-per-validation-run' 'Canonical validation must default to latest stable.'
        Assert-Equal $toolchain.sourceTrust.enforcement 'exact-approved-source' 'Tool sources must use exact approved-source enforcement.'
        Assert-Equal $toolchain.sourceTrust.resolver 'scripts/Resolve-StandardValidationTool.ps1' 'Tool policy must name the central resolver.'
        Assert-True ([bool]$toolchain.sourceTrust.failClosedOnMismatch) 'Tool source mismatch must fail closed.'
        Assert-True ([bool]$toolchain.resolution.resolveAtRunStart) 'Toolchain must resolve at run start.'
        Assert-True ([bool]$toolchain.resolution.freezeForRun) 'Resolved toolchain must freeze for one run.'
        Assert-True ([bool]$toolchain.resolution.recordResolvedVersion) 'Resolved version must be recorded.'
        Assert-True ([bool]$toolchain.resolution.recordResolvedIdentityWhenAvailable) 'Resolved immutable/package identity must be recorded when available.'
        Assert-True (-not [bool]$toolchain.resolution.allowPrerelease) 'Prerelease tools must not be the default.'

        $expectedSources = [ordered]@{
            'skillspector' = 'NVIDIA/SkillSpector'
            'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
            'skill-tools' = 'npm:skill-tools'
            'pester' = 'PowerShellGallery:Pester'
        }

        foreach ($entry in $expectedSources.GetEnumerator()) {
            Assert-Equal $toolchain.tools.($entry.Key).source $entry.Value "$($entry.Key) must use its approved source."
            Assert-Equal $toolchain.tools.($entry.Key).channel 'latest-stable' "$($entry.Key) must use latest-stable."
        }

        Assert-Equal $toolchain.tools.skillspector.releaseVersionRule 'v-semver-release-only' 'SkillSpector release tags must use stable v-semver.'
        Assert-Equal $toolchain.tools.skillspector.pythonPackageIndex 'https://pypi.org/simple' 'SkillSpector dependencies must use the approved PyPI index.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.configIsolation 'os.devnull' 'pip configuration must be isolated.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.environmentOverridePolicy 'deny-by-default' 'Inherited pip environment must be denied by default.'
        $allowedPipEnvironment = @($toolchain.tools.skillspector.pythonDistribution.allowedInheritedEnvironment)
        Assert-Equal $allowedPipEnvironment.Count 1 'Exactly one inherited pip variable may be conditionally accepted.'
        Assert-Equal $allowedPipEnvironment[0] 'PIP_INDEX_URL' 'Only the approved PIP_INDEX_URL may be inherited.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.onlyBinary) 'SkillSpector dependencies must resolve to wheels only.'
        Assert-True ($null -ne $toolchain.tools.skillspector.pythonDistribution.PSObject.Properties['allowDirectReferences']) 'SkillSpector direct-reference policy must be explicit.'
        Assert-False ([bool]$toolchain.tools.skillspector.pythonDistribution.allowDirectReferences) 'SkillSpector dependencies must not bypass PyPI with direct references.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.disableCache) 'SkillSpector dependency acquisition must disable pip cache.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.dependencyAcquisition 'verified-wheelhouse' 'SkillSpector dependencies must use a verified wheelhouse.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.installEnvironment 'isolated-venv' 'SkillSpector must install in an isolated virtual environment.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.interpreterIsolation 'python-isolated-mode' 'Every SkillSpector Python subprocess must ignore inherited interpreter controls.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.installNoIndex) 'SkillSpector install must be no-index.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.requireHashes) 'SkillSpector install must require hashes.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.recordDependencyClosureHashes) 'SkillSpector dependency closure hashes must be recorded.'

        Assert-Equal $toolchain.tools.'skill-tools'.registry 'https://registry.npmjs.org/' 'skill-tools must use the approved npm registry.'
        Assert-Equal $toolchain.tools.'skill-validator'.stableVersionRule 'release-semver-only' 'skill-validator must require release SemVer.'
        Assert-Equal $toolchain.tools.'skill-validator'.proxy 'https://proxy.golang.org' 'skill-validator must use the approved Go module proxy.'
        Assert-Equal $toolchain.tools.'skill-validator'.checksumDatabase 'sum.golang.org' 'skill-validator must use the approved Go checksum database.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOENV 'off' 'Go persisted environment configuration must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOPROXY 'https://proxy.golang.org' 'Go proxy environment must be fixed.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOSUMDB 'sum.golang.org' 'Go checksum database environment must be fixed.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOPRIVATE '' 'GOPRIVATE must not bypass canonical distribution.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GONOPROXY 'none' 'GONOPROXY must not bypass the approved proxy.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GONOSUMDB 'none' 'GONOSUMDB must not bypass checksum verification.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOINSECURE '' 'GOINSECURE must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOFLAGS '' 'GOFLAGS must not inject caller-controlled build behavior.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.moduleCacheIsolation 'temporary-empty' 'Go module resolution must use a fresh temporary module cache.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectInheritedModuleCache) 'An inherited Go module cache override must fail closed.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.buildCacheIsolation 'temporary-empty' 'Go installation must use a fresh temporary build cache.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectInheritedBuildCache) 'An inherited Go build cache override must fail closed.'
        Assert-True ([bool]$toolchain.compatibilityLane.mayPinOlderVersion) 'Compatibility lanes may pin an older version.'
        Assert-True ([bool]$toolchain.compatibilityLane.requiresExplicitPurpose) 'Compatibility pins require an explicit purpose.'
        Assert-True (-not [bool]$toolchain.compatibilityLane.mayBeCanonicalReleaseGate) 'Compatibility lane must not be the canonical release gate.'
    }

    It 'UnitT25_rejects_an_unapproved_validation_tool_source_before_resolution' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.tools.skillspector.source = 'example.invalid/SkillSpector'
        $unapprovedPath = Join-Path $TestDrive 'unapproved-validation-toolchain.json'
        $json = $toolchain | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($unapprovedPath, $json, (New-Object Text.UTF8Encoding($false)))

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $unapprovedPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        Assert-Match $errorMessage 'Untrusted validation tool source.*skillspector' 'Unapproved tool source must fail closed.'
    }

    It 'UnitT26_rejects_an_unapproved_npm_registry_before_skill_tools_resolution' {
        $previousRegistry = $env:NPM_CONFIG_REGISTRY
        $errorMessage = $null
        try {
            $env:NPM_CONFIG_REGISTRY = 'https://registry.example.invalid/'
            & $script:ResolverPath -ToolName skill-tools | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        finally {
            $env:NPM_CONFIG_REGISTRY = $previousRegistry
        }

        Assert-Match $errorMessage 'Untrusted npm registry' 'An npm registry override must fail closed before package resolution.'
    }

    It 'UnitT26a_rejects_untrusted_pip_distribution_overrides_before_dependency_resolution' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $cases = @(
            @{ Name = 'PIP_INDEX_URL'; Value = 'https://pypi.example.invalid/simple' },
            @{ Name = 'PIP_EXTRA_INDEX_URL'; Value = 'https://extra.example.invalid/simple' },
            @{ Name = 'PIP_CONFIG_FILE'; Value = 'custom-pip.conf' },
            @{ Name = 'PIP_FIND_LINKS'; Value = 'https://files.example.invalid/' },
            @{ Name = 'PIP_TRUSTED_HOST'; Value = 'example.invalid' },
            @{ Name = 'PIP_NO_INDEX'; Value = '1' },
            @{ Name = 'PIP_CERT'; Value = 'custom-ca.pem' },
            @{ Name = 'PIP_CLIENT_CERT'; Value = 'client.pem' },
            @{ Name = 'PIP_REQUIREMENT'; Value = 'https://files.example.invalid/requirements.txt' },
            @{ Name = 'PIP_CONSTRAINT'; Value = 'https://files.example.invalid/constraints.txt' },
            @{ Name = 'PIP_FUTURE_UNTRUSTED_OPTION'; Value = '1' }
        )

        foreach ($case in $cases) {
            $previous = [Environment]::GetEnvironmentVariable($case.Name, [EnvironmentVariableTarget]::Process)
            $errorMessage = $null
            try {
                [Environment]::SetEnvironmentVariable($case.Name, $case.Value, [EnvironmentVariableTarget]::Process)
                Assert-NoConflictingPipEnvironment -ApprovedIndex 'https://pypi.org/simple'
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            finally {
                [Environment]::SetEnvironmentVariable($case.Name, $previous, [EnvironmentVariableTarget]::Process)
            }

            Assert-Match $errorMessage ("Untrusted pip environment override.*{0}" -f $case.Name) ("pip override {0} must fail before dependency resolution." -f $case.Name)
        }
    }

    It 'UnitT26b_accepts_the_approved_pip_environment_and_executes_the_action' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $names = @((Get-ProcessPipEnvironmentNames) + @('PIP_INDEX_URL', 'PIP_CONFIG_FILE') | Sort-Object -Unique)
        $previous = [ordered]@{}
        try {
            foreach ($name in $names) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }

            $result = Invoke-WithApprovedPipEnvironment -ApprovedIndex 'https://pypi.org/simple' -Action {
                $index = [Environment]::GetEnvironmentVariable('PIP_INDEX_URL', [EnvironmentVariableTarget]::Process)
                $configFile = [Environment]::GetEnvironmentVariable('PIP_CONFIG_FILE', [EnvironmentVariableTarget]::Process)
                if ($index -notmatch '^https://pypi\.org/simple/?$') { throw 'Approved pip index was not applied.' }
                if ([string]::IsNullOrWhiteSpace($configFile)) { throw 'pip config isolation was not applied.' }
                $unexpected = @(Get-ProcessPipEnvironmentNames | Where-Object {
                    $_ -notin @('PIP_INDEX_URL', 'PIP_CONFIG_FILE') -and
                    -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_, [EnvironmentVariableTarget]::Process))
                })
                if ($unexpected.Count -gt 0) { throw "Unexpected effective pip environment override: $($unexpected -join ', ')" }
                'approved-pip-action-ran'
            }
            Assert-Equal $result 'approved-pip-action-ran' 'Approved pip environment must reach the action.'
        }
        finally {
            foreach ($entry in $previous.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    # Scenario: Cross-platform test wheels expose standards-compliant METADATA entries using ZIP forward slashes.
    # Purpose: Verify dependency closure hashing without allowing host-specific archive separators to invalidate the fixture.
    It 'UnitT26c_builds_a_hash_locked_dependency_closure_from_wheels_only' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $wheelhouse = Join-Path $TestDrive 'wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse -Force)
        [void](New-TestWheel -Root $wheelhouse -Name 'skillspector' -Version '2.12.0')
        [void](New-TestWheel -Root $wheelhouse -Name 'dependency-a' -Version '1.0.0')
        $lockPath = Join-Path $TestDrive 'dependency-lock.txt'

        $manifest = New-PythonWheelhouseLock -WheelhousePath $wheelhouse -LockPath $lockPath
        Assert-Equal @($manifest.entries).Count 2 'Dependency closure must include every wheel.'
        Assert-Match $manifest.closureSha256 '^[0-9a-f]{64}$' 'Dependency closure must have a SHA-256 identity.'
        $lock = Get-Content -Raw -Encoding UTF8 -LiteralPath $lockPath
        Assert-Match $lock 'skillspector==2\.12\.0 --hash=sha256:[0-9a-f]{64}' 'Root wheel must be hash locked.'
        Assert-Match $lock 'dependency-a==1\.0\.0 --hash=sha256:[0-9a-f]{64}' 'Dependency wheel must be hash locked.'
    }

    It 'UnitT26d_requires_offline_hash_locked_SkillSpector_installation' {
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $resolver 'function Invoke-IsolatedPythonCommand' 'Python isolation must be centralized in one command wrapper.'
        Assert-Match $resolver 'return Invoke-CheckedCommand.*@\(''-I''\) \+ \$Arguments' 'Every wrapped Python subprocess must prepend isolated mode.'
        Assert-NotMatch $resolver "Invoke-CheckedCommand -Command 'python'" 'System Python must not bypass isolated mode.'
        Assert-NotMatch $resolver 'Invoke-CheckedCommand -Command \$venvPython' 'Virtual-environment Python must not bypass isolated mode.'
        Assert-Match $resolver "'-m', 'venv'" 'SkillSpector must use an isolated Python virtual environment.'
        Assert-Match $resolver '\$venvPython' 'SkillSpector dependency acquisition and install must use the virtual-environment Python.'
        Assert-NotMatch $resolver '--break-system-packages' 'Canonical install must not bypass PEP 668 protections.'
        Assert-Match $resolver "'pip', 'download'" 'SkillSpector dependencies must be acquired before installation.'
        Assert-Match $resolver '--only-binary=:all:' 'Dependency acquisition must reject source distributions.'
        Assert-Match $resolver '--no-cache-dir' 'Dependency acquisition must not reuse pip cache.'
        Assert-Match $resolver 'New-PythonWheelhouseLock' 'Dependency closure must be hash inventoried.'
        Assert-Match $resolver '--no-index' 'Final SkillSpector installation must not use an index.'
        Assert-Match $resolver '--require-hashes' 'Final SkillSpector installation must enforce hashes.'
        Assert-Match $resolver '--no-deps' 'Final installation must not resolve new dependencies outside the locked closure.'
        Assert-Match $resolver 'interpreterIsolation=\$interpreterIsolation' 'Resolved SkillSpector identity must record Python interpreter isolation.'
        Assert-Match $resolver '\$result\.interpreterIsolation = ' 'The machine-readable receipt must expose Python interpreter isolation.'
        Assert-Match $resolver 'directReferences=blocked' 'Resolved SkillSpector identity must record direct-reference blocking.'
        Assert-Match $resolver '\$result\.directReferencesAllowed = ' 'The machine-readable receipt must expose direct-reference policy.'
        Assert-Match $standard '`SkillSpector`.*resolver \*\*MUST\*\*' 'Normative authority must define SkillSpector resolver controls.'
        Assert-Match $standard 'Python `-I` isolated mode' 'Normative authority must require inherited Python interpreter isolation.'
        Assert-Match $standard '--no-index --require-hashes --no-deps' 'Normative authority must require offline hash-locked installation.'
    }

    It 'UnitT26e_ignores_inherited_PYTHONPATH_for_every_Python_subprocess' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        [void](Assert-Command -Name 'python')
        $probeRoot = Join-Path $TestDrive 'untrusted-python-path'
        [void](New-Item -ItemType Directory -Path $probeRoot -Force)
        $siteCustomizePath = Join-Path $probeRoot 'sitecustomize.py'
        [IO.File]::WriteAllText($siteCustomizePath, "raise SystemExit('untrusted PYTHONPATH executed')`n", (New-Object Text.UTF8Encoding($false)))

        $previousPythonPath = [Environment]::GetEnvironmentVariable('PYTHONPATH', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('PYTHONPATH', $probeRoot, [EnvironmentVariableTarget]::Process)
            $output = Invoke-IsolatedPythonCommand -PythonCommand 'python' -Arguments @('-c', "print('isolated-python-ran')")
            Assert-Equal (($output -join '').Trim()) 'isolated-python-ran' 'Isolated Python must ignore caller-controlled PYTHONPATH imports.'
        }
        finally {
            [Environment]::SetEnvironmentVariable('PYTHONPATH', $previousPythonPath, [EnvironmentVariableTarget]::Process)
        }
    }

    It 'UnitT26f_distinguishes_root_pre_network_and_transitive_post_materialization_direct_reference_checks' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $wheelhouse = Join-Path $TestDrive 'direct-reference-wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse -Force)
        $safeWheel = New-TestWheel -Root $wheelhouse -Name 'safe-package' -Version '1.0.0' -RequiresDist @('dependency-a>=1.0')
        $unsafeWheel = New-TestWheel -Root $wheelhouse -Name 'unsafe-package' -Version '1.0.0' -RequiresDist @("dependency-b @`n https://packages.example.invalid/dependency-b.whl")

        $safeMetadata = Get-PythonWheelMetadata -WheelPath $safeWheel
        Assert-NoPythonDirectReferences -Metadata $safeMetadata -WheelFileName ([IO.Path]::GetFileName($safeWheel))

        $errorMessage = $null
        try {
            $unsafeMetadata = Get-PythonWheelMetadata -WheelPath $unsafeWheel
            Assert-NoPythonDirectReferences -Metadata $unsafeMetadata -WheelFileName ([IO.Path]::GetFileName($unsafeWheel))
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'Python direct dependency reference is not allowed' 'Direct URL dependency metadata must fail closed.'

        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $resolveStart = $resolver.IndexOf('function Resolve-SkillSpector')
        $resolveBody = $resolver.Substring($resolveStart)
        $directReferenceCheck = $resolveBody.IndexOf('Assert-NoPythonDirectReferences')
        $dependencyDownload = $resolveBody.IndexOf("'pip', 'download'")
        Assert-True ($directReferenceCheck -ge 0 -and $directReferenceCheck -lt $dependencyDownload) 'Root direct references must be rejected before pip dependency download.'

        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        Assert-Match $standard 'root wheel.*direct URL.*dependency network resolution' 'Standard must preserve root direct-reference pre-network rejection.'
        Assert-Match $standard 'post-materialization check.*不得被描述成' 'Standard must state the transitive direct-reference check is post-materialization, not a pre-network proof.'
        Assert-Match $standard 'transport/sandbox egress control' 'Stronger transitive network-egress claims must require an actual transport or sandbox control.'
    }

    It 'UnitT27_requires_authority_CI_to_use_the_central_tool_resolver' {
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:WorkflowPath
        $requiredWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RequiredPowerShellWorkflowPath

        Assert-Match $workflow 'Resolve-StandardValidationTool\.ps1.*-ValidatePolicyOnly' 'Workflow must validate central tool trust policy.'
        Assert-Match $workflow 'Resolve-StandardValidationTool\.ps1.*-ToolName pester.*-Install' 'Workflow must resolve Pester through the central resolver.'
        Assert-Match $workflow 'interpreterIsolation=python-isolated-mode' 'Workflow must verify Python isolation in resolved SkillSpector identity.'
        Assert-Match $workflow 'directReferences=blocked' 'Workflow must verify SkillSpector direct-reference blocking.'
        Assert-Match $workflow 'persist-credentials:\s*false' 'Authority checkout must not persist repository credentials.'
        Assert-NotMatch $workflow 'Install-Module\s+Pester' 'Workflow must not bypass the central resolver with direct Pester installation.'

        Assert-Match $requiredWorkflow 'Composition \(PowerShell 7 on Linux\)' 'Ruleset-required Composition context must remain present.'
        Assert-Match $requiredWorkflow '(?ms)^permissions:\r?\n  contents: read\r?\n\r?\njobs:' 'Required workflow token permissions must be explicitly read-only.'
        Assert-Match $requiredWorkflow 'Run required Standard v1 authority gate' 'Required Composition context must execute the authority gate.'
        Assert-Match $requiredWorkflow 'Resolve-StandardValidationTool\.ps1.*-ValidatePolicyOnly' 'Required context must validate central tool policy through the resolver.'
        Assert-Match $requiredWorkflow 'Resolve-StandardValidationTool\.ps1.*-ToolName skillspector.*-Install' 'Required context must live-install SkillSpector through the resolver.'
        Assert-Match $requiredWorkflow 'interpreterIsolation=python-isolated-mode' 'Required context must verify Python isolation in resolved SkillSpector identity.'
        Assert-Match $requiredWorkflow 'directReferences=blocked' 'Required context must verify SkillSpector direct-reference blocking.'
        Assert-Match $requiredWorkflow 'Resolve-StandardValidationTool\.ps1.*-ToolName pester.*-Install' 'Required context must obtain latest Pester through the resolver.'
        Assert-Match $requiredWorkflow 'skill-repository-standard\.Tests\.ps1' 'Required context must run the authority regression.'
        Assert-Equal ([regex]::Matches($requiredWorkflow, 'persist-credentials:\s*false')).Count 3 'Every checkout lane must avoid persisted repository credentials.'
        Assert-Match $requiredWorkflow 'Remove-Item Env:GITHUB_TOKEN' 'Required authority gate must drop the API token before third-party module import/tests.'
    }

    It 'UnitT28_rejects_prerelease_and_pseudo_versions_for_skill_validator' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        Assert-True (Test-StableGoModuleVersion -Version 'v1.6.1') 'A normal release version must be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v1.7.0-rc1') 'A prerelease version must not be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v0.0.0-20260902000000-0123456789ab') 'A pseudo-version must not be stable.'
    }

    It 'UnitT28a_binds_SkillSpector_release_wheel_metadata_and_installed_version' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        Assert-SkillSpectorWheelIdentity -ReleaseVersion '2.12.0' -WheelFileName 'skillspector-2.12.0-py3-none-any.whl' -MetadataName 'skillspector' -MetadataVersion '2.12.0'

        $cases = @(
            @{ File = 'skillspector-2.11.0-py3-none-any.whl'; Name = 'skillspector'; Version = '2.12.0'; Pattern = 'release/wheel version mismatch' },
            @{ File = 'skillspector-2.12.0-py3-none-any.whl'; Name = 'other-package'; Version = '2.12.0'; Pattern = 'METADATA Name mismatch' },
            @{ File = 'skillspector-2.12.0-py3-none-any.whl'; Name = 'skillspector'; Version = '2.11.0'; Pattern = 'METADATA Version mismatch' }
        )

        foreach ($case in $cases) {
            $errorMessage = $null
            try {
                Assert-SkillSpectorWheelIdentity -ReleaseVersion '2.12.0' -WheelFileName $case.File -MetadataName $case.Name -MetadataVersion $case.Version
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            Assert-Match $errorMessage $case.Pattern 'SkillSpector release identity mismatch must fail closed.'
        }

        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        Assert-Match $resolver "importlib\.metadata.*version\('skillspector'\)" 'Installed SkillSpector version must be verified after installation.'
    }

    # Scenario: A caller supplies one conflicting Go distribution variable before skill-validator resolution.
    # Purpose: Ensure proxy, checksum, bypass, and module-cache overrides all fail before network or cache use.
    It 'UnitT29_rejects_untrusted_Go_distribution_overrides_before_module_resolution' {
        $cases = @(
            @{ Name = 'GOENV'; Value = 'custom-go-env' },
            @{ Name = 'GOPROXY'; Value = 'https://proxy.example.invalid' },
            @{ Name = 'GOSUMDB'; Value = 'off' },
            @{ Name = 'GOPRIVATE'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GONOPROXY'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GONOSUMDB'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GOINSECURE'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GOFLAGS'; Value = '-toolexec=untrusted-wrapper' },
            @{ Name = 'GOMODCACHE'; Value = (Join-Path $TestDrive 'untrusted-go-module-cache') },
            @{ Name = 'GOCACHE'; Value = (Join-Path $TestDrive 'untrusted-go-build-cache') }
        )

        foreach ($case in $cases) {
            $previous = [Environment]::GetEnvironmentVariable($case.Name, [EnvironmentVariableTarget]::Process)
            $errorMessage = $null
            try {
                [Environment]::SetEnvironmentVariable($case.Name, $case.Value, [EnvironmentVariableTarget]::Process)
                & $script:ResolverPath -ToolName skill-validator | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            finally {
                [Environment]::SetEnvironmentVariable($case.Name, $previous, [EnvironmentVariableTarget]::Process)
            }

            Assert-Match $errorMessage ("Untrusted Go environment override.*{0}" -f $case.Name) ("Go override {0} must fail closed before module resolution." -f $case.Name)
        }
    }

    # Scenario: No conflicting Go variables exist and the approved environment is applied to a resolver action.
    # Purpose: Protect the valid GOENV=off path plus fresh temporary module-cache setup and cleanup.
    It 'UnitT29a_accepts_the_approved_Go_environment_and_executes_the_action' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $expectedEnvironment = [ordered]@{
            'GOENV' = 'off'
            'GOPROXY' = 'https://proxy.golang.org'
            'GOSUMDB' = 'sum.golang.org'
            'GOPRIVATE' = ''
            'GONOPROXY' = 'none'
            'GONOSUMDB' = 'none'
            'GOINSECURE' = ''
            'GOFLAGS' = ''
        }

        $previous = [ordered]@{}
        try {
            foreach ($entry in $expectedEnvironment.GetEnumerator()) {
                $previous[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $null, [EnvironmentVariableTarget]::Process)
            }
            $previous.GOMODCACHE = [Environment]::GetEnvironmentVariable('GOMODCACHE', [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('GOMODCACHE', $null, [EnvironmentVariableTarget]::Process)
            $previous.GOCACHE = [Environment]::GetEnvironmentVariable('GOCACHE', [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('GOCACHE', $null, [EnvironmentVariableTarget]::Process)

            $distributionPolicy = [ordered]@{
                moduleCacheIsolation = 'temporary-empty'
                rejectInheritedModuleCache = $true
                buildCacheIsolation = 'temporary-empty'
                rejectInheritedBuildCache = $true
            }
            $result = Invoke-WithApprovedGoEnvironment -ExpectedEnvironment $expectedEnvironment -DistributionPolicy $distributionPolicy -Action {
                $moduleCache = [Environment]::GetEnvironmentVariable('GOMODCACHE', [EnvironmentVariableTarget]::Process)
                $buildCache = [Environment]::GetEnvironmentVariable('GOCACHE', [EnvironmentVariableTarget]::Process)
                [ordered]@{
                    action = 'approved-action-ran'
                    moduleCache = $moduleCache
                    moduleCacheExists = Test-Path -LiteralPath $moduleCache -PathType Container
                    moduleCacheEntryCount = @(Get-ChildItem -LiteralPath $moduleCache -Force).Count
                    buildCache = $buildCache
                    buildCacheExists = Test-Path -LiteralPath $buildCache -PathType Container
                    buildCacheEntryCount = @(Get-ChildItem -LiteralPath $buildCache -Force).Count
                }
            }
            Assert-Equal $result.action 'approved-action-ran' 'Approved Go environment must reach the action.'
            Assert-True ([bool]$result.moduleCacheExists) 'Approved Go resolution must provide an isolated module cache.'
            Assert-Equal $result.moduleCacheEntryCount 0 'The isolated Go module cache must be empty before resolution.'
            Assert-False (Test-Path -LiteralPath $result.moduleCache) 'The isolated Go module cache must be removed after resolution.'
            Assert-True ([bool]$result.buildCacheExists) 'Approved Go installation must provide an isolated build cache.'
            Assert-Equal $result.buildCacheEntryCount 0 'The isolated Go build cache must be empty before installation.'
            Assert-False (Test-Path -LiteralPath $result.buildCache) 'The isolated Go build cache must be removed after resolution.'

            $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
            Assert-Match $resolver 'resolvedIdentity = "go:.*#moduleCache=\$\(' 'Resolved skill-validator identity must record module-cache isolation.'
            Assert-Match $resolver '#buildCache=\$\(' 'Resolved skill-validator identity must record build-cache isolation.'
            Assert-Match $resolver '#goflags=empty' 'Resolved skill-validator identity must record clean build flags.'
            Assert-Match $resolver '\$result\.moduleCacheIsolation = ' 'The machine-readable receipt must expose module-cache isolation.'
            Assert-Match $resolver '\$result\.buildCacheIsolation = ' 'The machine-readable receipt must expose build-cache isolation.'
        }
        finally {
            foreach ($entry in $previous.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT30_validates_openai_agent_metadata_against_the_OpenAI_minimum_contract' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $standard 'agents/openai\.yaml.*contract' 'Standard must define an openai.yaml content contract.'
        Assert-Match $standard 'syntactically valid YAML' 'Standard must require valid YAML.'
        Assert-Match $standard 'YAML keys.*MUST.*unquoted' 'Standard must require unquoted YAML keys.'
        Assert-Match $standard 'all string scalar values.*MUST.*quoted' 'Standard must require quoted YAML string values.'
        Assert-Match $standard 'interface\.display_name' 'Standard must require display_name.'
        Assert-Match $standard 'interface\.short_description.*25.*64' 'Standard must require the OpenAI 25-64 character short_description bound.'
        Assert-Match $standard 'interface\.default_prompt' 'Standard must require default_prompt.'
        Assert-Match $standard '\$<skill-id>' 'Standard must bind default_prompt to the Skill ID.'
    }

    It 'UnitT40_distinguishes_release_approval_from_installing_an_already_approved_release' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $standard 'Release Approval' 'Standard must define release approval.'
        Assert-Match $standard 'Approved Release Installation' 'Standard must define approved release installation.'
        Assert-Match $standard 'Human Approved.*MUST NOT.*human approval' 'Installing an approved immutable release must not require repeated release approval.'
    }

    It 'UnitT50_makes_standard_conformance_tests_effective_in_the_same_policy_change' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath

        Assert-Match $standard 'normative authority.*conformance regression.*MUST.*PR' 'Standard changes must update authority regression in the same PR.'
        Assert-Match $index 'tests/skill-repository-standard\.Tests\.ps1' 'Standards index must name the authority regression test.'
    }

    It 'UnitT60_keeps_the_review_matrix_current_with_the_SYP167_authority_deliverables' {
        $matrix = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:MatrixPath

        Assert-Match $matrix 'Validation tool policy' 'Review matrix must record the validation tool policy decision.'
        Assert-Match $matrix 'latest stable' 'Review matrix must record latest-stable validation tooling.'
        Assert-Match $matrix 'authority-level regression' 'Review matrix must record SYP-167 authority regression/CI deliverables.'
        Assert-Match $matrix 'proxy.golang.org' 'Review matrix must record the approved Go module proxy.'
        Assert-Match $matrix 'sum.golang.org' 'Review matrix must record the approved Go checksum database.'
        Assert-Match $matrix 'GOCACHE' 'Review matrix must record isolated Go build-cache enforcement.'
        Assert-Match $matrix 'GOFLAGS' 'Review matrix must record clean Go build flags.'
        Assert-Match $matrix 'pypi.org/simple' 'Review matrix must record the approved Python package index.'
        Assert-Match $matrix 'Python `-I` isolated mode' 'Review matrix must record inherited Python interpreter isolation.'
        Assert-Match $matrix 'direct references' 'Review matrix must record direct-reference blocking.'
        Assert-Match $matrix 'post-materialization' 'Review matrix must distinguish transitive post-materialization checking from root pre-network rejection.'
        Assert-Match $matrix 'persist-credentials' 'Review matrix must record CI checkout credential isolation.'
        Assert-Match $matrix 'wheelhouse' 'Review matrix must record hash-locked SkillSpector dependency acquisition.'
        Assert-NotMatch $matrix 'SYP-167 establishes normative Standard v1 only\.' 'Review matrix must not describe the pre-regression SYP-167 scope.'
    }
}
