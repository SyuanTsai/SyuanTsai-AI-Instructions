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

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $token = [guid]::NewGuid().ToString('N')
            $sourceRoot = Join-Path $Root ("wheel-source-$token")
            [void](New-Item -ItemType Directory -Path $sourceRoot -Force)
            $distName = ($Name -replace '-', '_')
            $distInfo = Join-Path $sourceRoot ("$distName-$Version.dist-info")
            [void](New-Item -ItemType Directory -Path $distInfo -Force)
            $metadata = "Metadata-Version: 2.4`nName: $Name`nVersion: $Version`n"
            [IO.File]::WriteAllText((Join-Path $distInfo 'METADATA'), $metadata, (New-Object Text.UTF8Encoding($false)))
            $wheelPath = Join-Path $Root ("$distName-$Version-py3-none-any.whl")
            [IO.Compression.ZipFile]::CreateFromDirectory($sourceRoot, $wheelPath)
            Remove-Item -LiteralPath $sourceRoot -Recurse -Force
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

        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        Assert-Match $index 'skill-repository-standard\.md' 'Standards index must link the normative Standard.'
        Assert-Match $index 'skill-repository-review-matrix\.md' 'Standards index must link the review matrix.'
        Assert-Match $index 'validation-toolchain\.json' 'Standards index must link the toolchain policy.'
        Assert-Match $index 'Resolve-StandardValidationTool\.ps1' 'Standards index must name the central validation tool resolver.'
    }

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
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.onlyBinary) 'SkillSpector dependencies must resolve to wheels only.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.disableCache) 'SkillSpector dependency acquisition must disable pip cache.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.dependencyAcquisition 'verified-wheelhouse' 'SkillSpector dependencies must use a verified wheelhouse.'
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
            @{ Name = 'PIP_CLIENT_CERT'; Value = 'client.pem' }
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

        $names = @('PIP_INDEX_URL', 'PIP_EXTRA_INDEX_URL', 'PIP_CONFIG_FILE', 'PIP_FIND_LINKS', 'PIP_TRUSTED_HOST', 'PIP_NO_INDEX', 'PIP_CERT', 'PIP_CLIENT_CERT')
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

        Assert-Match $resolver "'pip', 'download'" 'SkillSpector dependencies must be acquired before installation.'
        Assert-Match $resolver '--only-binary=:all:' 'Dependency acquisition must reject source distributions.'
        Assert-Match $resolver '--no-cache-dir' 'Dependency acquisition must not reuse pip cache.'
        Assert-Match $resolver 'New-PythonWheelhouseLock' 'Dependency closure must be hash inventoried.'
        Assert-Match $resolver '--no-index' 'Final SkillSpector installation must not use an index.'
        Assert-Match $resolver '--require-hashes' 'Final SkillSpector installation must enforce hashes.'
        Assert-Match $resolver '--no-deps' 'Final installation must not resolve new dependencies outside the locked closure.'
    }

    It 'UnitT27_requires_authority_CI_to_use_the_central_tool_resolver' {
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:WorkflowPath

        Assert-Match $workflow 'Resolve-StandardValidationTool\.ps1.*-ValidatePolicyOnly' 'Workflow must validate central tool trust policy.'
        Assert-Match $workflow 'Resolve-StandardValidationTool\.ps1.*-ToolName pester.*-Install' 'Workflow must resolve Pester through the central resolver.'
        Assert-NotMatch $workflow 'Install-Module\s+Pester' 'Workflow must not bypass the central resolver with direct Pester installation.'
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

    It 'UnitT29_rejects_untrusted_Go_distribution_overrides_before_module_resolution' {
        $cases = @(
            @{ Name = 'GOENV'; Value = 'custom-go-env' },
            @{ Name = 'GOPROXY'; Value = 'https://proxy.example.invalid' },
            @{ Name = 'GOSUMDB'; Value = 'off' },
            @{ Name = 'GOPRIVATE'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GONOPROXY'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GONOSUMDB'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GOINSECURE'; Value = 'github.com/agent-ecosystem' }
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
        }

        $previous = [ordered]@{}
        try {
            foreach ($entry in $expectedEnvironment.GetEnumerator()) {
                $previous[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $null, [EnvironmentVariableTarget]::Process)
            }

            $result = Invoke-WithApprovedGoEnvironment -ExpectedEnvironment $expectedEnvironment -Action { 'approved-action-ran' }
            Assert-Equal $result 'approved-action-ran' 'Approved Go environment must reach the action.'
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
        Assert-Match $matrix 'pypi.org/simple' 'Review matrix must record the approved Python package index.'
        Assert-Match $matrix 'wheelhouse' 'Review matrix must record hash-locked SkillSpector dependency acquisition.'
        Assert-NotMatch $matrix 'SYP-167 establishes normative Standard v1 only\.' 'Review matrix must not describe the pre-regression SYP-167 scope.'
    }
}
