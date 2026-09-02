Describe 'Agent Skill Repository Standard v1 contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:StandardsRoot = Join-Path $script:RepositoryRoot 'docs\standards'
        $script:IndexPath = Join-Path $script:StandardsRoot 'README.md'
        $script:StandardPath = Join-Path $script:StandardsRoot 'skill-repository-standard.md'
        $script:MatrixPath = Join-Path $script:StandardsRoot 'skill-repository-review-matrix.md'
        $script:ToolchainPath = Join-Path $script:StandardsRoot 'validation-toolchain.json'
        $script:SourceInventorySchemaPath = Join-Path $script:StandardsRoot 'schemas\source-inventory-v2.schema.json'
        $script:OpenAiMetadataSchemaPath = Join-Path $script:StandardsRoot 'schemas\openai-agent-metadata.schema.json'
        $script:ResolverPath = Join-Path $script:RepositoryRoot 'scripts\Resolve-StandardValidationTool.ps1'
        $script:PythonClosureHelperPath = Join-Path $script:RepositoryRoot 'scripts\Resolve-PythonWheelClosure.py'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-StandardAuthorityGate.ps1'
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

        function Get-CaseSensitiveProperty {
            param($Object, [string] $Name)

            if ($null -eq $Object -or $null -eq $Object.PSObject) { return $null }
            foreach ($property in @($Object.PSObject.Properties)) {
                if ([string]$property.Name -ceq $Name) { return $property }
            }
            return $null
        }

        function Assert-ExactPropertySet {
            param($Object, [string[]] $Expected, [string] $Message)

            $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
            Assert-Equal $actual.Count $Expected.Count "$Message Property count differs."
            foreach ($name in $Expected) {
                Assert-True ($actual -ccontains $name) "$Message Missing property '$name'."
            }
            foreach ($name in $actual) {
                Assert-True ($Expected -ccontains $name) "$Message Unexpected property '$name'."
            }
        }

        function Assert-ExactStringSequence {
            param($Actual, [string[]] $Expected, [string] $Message)

            $values = @($Actual)
            Assert-Equal $values.Count $Expected.Count "$Message Item count differs."
            for ($index = 0; $index -lt $Expected.Count; $index++) {
                Assert-True ([string]$values[$index] -ceq $Expected[$index]) "$Message Item $index differs."
            }
        }

        function Test-AuthorityJsonSchemaValue {
            param($Value, $Schema, $RootSchema)

            $referenceProperty = Get-CaseSensitiveProperty -Object $Schema -Name '$ref'
            if ($null -ne $referenceProperty) {
                $reference = [string]$referenceProperty.Value
                if (-not $reference.StartsWith('#/', [StringComparison]::Ordinal)) { return $false }
                $resolved = $RootSchema
                foreach ($segment in @($reference.Substring(2).Split('/'))) {
                    $segmentProperty = Get-CaseSensitiveProperty -Object $resolved -Name $segment
                    if ($null -eq $segmentProperty) { return $false }
                    $resolved = $segmentProperty.Value
                }
                return Test-AuthorityJsonSchemaValue -Value $Value -Schema $resolved -RootSchema $RootSchema
            }

            $constProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'const'
            if ($null -ne $constProperty) {
                $expected = $constProperty.Value
                if ($expected -is [string]) {
                    if ($Value -isnot [string] -or [string]$Value -cne [string]$expected) { return $false }
                }
                elseif (($expected -is [int] -or $expected -is [long] -or $expected -is [double] -or $expected -is [decimal]) -and
                    ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) {
                    if ([decimal]$Value -ne [decimal]$expected) { return $false }
                }
                elseif ($null -eq $Value -or $Value.GetType() -ne $expected.GetType() -or $Value -ne $expected) {
                    return $false
                }
            }

            $typeProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'type'
            $type = if ($null -ne $typeProperty) { [string]$typeProperty.Value } else { '' }
            if ($type -ceq 'object') {
                $isObject = $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [array] -and
                    ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject])
                if (-not $isObject) { return $false }

                $actualNames = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
                $requiredProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'required'
                if ($null -ne $requiredProperty) {
                    foreach ($name in @($requiredProperty.Value)) {
                        if (-not ($actualNames -ccontains [string]$name)) { return $false }
                    }
                }

                $propertiesProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'properties'
                $propertySchemas = if ($null -ne $propertiesProperty) { $propertiesProperty.Value } else { $null }
                $allowedNames = if ($null -ne $propertySchemas) {
                    @($propertySchemas.PSObject.Properties | ForEach-Object { [string]$_.Name })
                }
                else { @() }
                $additionalProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'additionalProperties'
                if ($null -ne $additionalProperty -and $additionalProperty.Value -is [bool] -and
                    -not [bool]$additionalProperty.Value) {
                    foreach ($name in $actualNames) {
                        if (-not ($allowedNames -ccontains $name)) { return $false }
                    }
                }
                foreach ($name in $allowedNames) {
                    $instanceProperty = Get-CaseSensitiveProperty -Object $Value -Name $name
                    if ($null -eq $instanceProperty) { continue }
                    $propertySchema = (Get-CaseSensitiveProperty -Object $propertySchemas -Name $name).Value
                    if (-not (Test-AuthorityJsonSchemaValue -Value $instanceProperty.Value -Schema $propertySchema -RootSchema $RootSchema)) {
                        return $false
                    }
                }
            }
            elseif ($type -ceq 'array') {
                if ($Value -isnot [array]) { return $false }
                $items = @($Value)
                $minItemsProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'minItems'
                if ($null -ne $minItemsProperty -and $items.Count -lt [int]$minItemsProperty.Value) { return $false }
                $uniqueProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'uniqueItems'
                if ($null -ne $uniqueProperty -and [bool]$uniqueProperty.Value) {
                    for ($left = 0; $left -lt $items.Count; $left++) {
                        $leftJson = $items[$left] | ConvertTo-Json -Depth 50 -Compress
                        for ($right = $left + 1; $right -lt $items.Count; $right++) {
                            $rightJson = $items[$right] | ConvertTo-Json -Depth 50 -Compress
                            if ($leftJson -ceq $rightJson) { return $false }
                        }
                    }
                }
                $itemsProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'items'
                if ($null -ne $itemsProperty) {
                    foreach ($item in $items) {
                        if (-not (Test-AuthorityJsonSchemaValue -Value $item -Schema $itemsProperty.Value -RootSchema $RootSchema)) {
                            return $false
                        }
                    }
                }
            }
            elseif ($type -ceq 'string') {
                if ($Value -isnot [string]) { return $false }
                $text = [string]$Value
                $minLengthProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'minLength'
                if ($null -ne $minLengthProperty -and $text.Length -lt [int]$minLengthProperty.Value) { return $false }
                $maxLengthProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'maxLength'
                if ($null -ne $maxLengthProperty -and $text.Length -gt [int]$maxLengthProperty.Value) { return $false }
                $patternProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'pattern'
                if ($null -ne $patternProperty -and $text -cnotmatch [string]$patternProperty.Value) { return $false }
                $formatProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'format'
                if ($null -ne $formatProperty -and [string]$formatProperty.Value -ceq 'uri') {
                    $uri = $null
                    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) { return $false }
                }
            }

            return $true
        }

        function Assert-AuthoritySchemaInstance {
            param($Value, $Schema, [string] $SchemaPath, [bool] $Expected, [string] $Message)

            $portableResult = Test-AuthorityJsonSchemaValue -Value $Value -Schema $Schema -RootSchema $Schema
            Assert-Equal ([bool]$portableResult) $Expected "$Message Portable schema evaluation differs."

            $testJsonCommand = Get-Command Test-Json -ErrorAction SilentlyContinue
            if ($null -ne $testJsonCommand -and $testJsonCommand.Parameters.ContainsKey('SchemaFile')) {
                $json = $Value | ConvertTo-Json -Depth 50 -Compress
                try {
                    $nativeResult = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
                catch {
                    $nativeResult = $false
                }
                Assert-Equal ([bool]$nativeResult) $Expected "$Message Test-Json result differs."
            }
        }

        function Copy-TestJsonObject {
            param($Value)
            return ($Value | ConvertTo-Json -Depth 50 -Compress | ConvertFrom-Json)
        }

        function Test-SourceInventoryExecutableContract {
            param(
                $Inventory,
                [string] $ExpectedSourceId,
                [string] $ExpectedRepository,
                [string[]] $PackageDirectoryNames
            )

            if ($Inventory.sourceId -isnot [string] -or [string]$Inventory.sourceId -cne $ExpectedSourceId) { return $false }
            if ($Inventory.repository -isnot [string] -or [string]$Inventory.repository -cne $ExpectedRepository) { return $false }
            if ($Inventory.skills -isnot [array]) { return $false }
            $skills = [string[]]@($Inventory.skills)
            for ($index = 1; $index -lt $skills.Count; $index++) {
                if ([StringComparer]::Ordinal.Compare($skills[$index - 1], $skills[$index]) -ge 0) { return $false }
            }
            $directories = [string[]]@($PackageDirectoryNames)
            [Array]::Sort($directories, [StringComparer]::Ordinal)
            if ($skills.Count -ne $directories.Count) { return $false }
            for ($index = 0; $index -lt $skills.Count; $index++) {
                if ($skills[$index] -cne $directories[$index]) { return $false }
            }
            return $true
        }

        function Write-TestUtf8File {
            param([string] $Path, [string] $Text)

            $parent = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function New-TestAuthorityFixture {
            param([string] $Root)

            [void](New-Item -ItemType Directory -Path $Root -Force)
            $skillPath = Join-Path $Root 'SKILL.md'
            $metadataPath = Join-Path $Root 'agents/openai.yaml'
            $skillText = (@(
                '---',
                'name: standard-validation-fixture',
                'description: A deterministic Agent Skill package for authority validation.',
                '---',
                '',
                '# Standard Validation Fixture',
                '',
                'Validate the canonical toolchain.'
            ) -join "`n") + "`n"
            $metadataText = (@(
                'interface:',
                '  display_name: "Standard Validation Fixture"',
                '  short_description: "Validate one deterministic canonical Skill package."',
                '  default_prompt: "Use $standard-validation-fixture to verify the canonical validation toolchain."'
            ) -join "`n") + "`n"
            Write-TestUtf8File -Path $skillPath -Text $skillText
            Write-TestUtf8File -Path $metadataPath -Text $metadataText
            return [pscustomobject]@{ Root=$Root; SkillPath=$skillPath; MetadataPath=$metadataPath }
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
        Assert-True (Test-Path -LiteralPath $script:PythonClosureHelperPath -PathType Leaf) 'Missing verified Python wheel closure helper.'
        Assert-True (Test-Path -LiteralPath $script:AuthorityGatePath -PathType Leaf) 'Missing shared Standard authority gate.'
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
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.rejectInheritedPythonEnvironment) 'Python startup/import environment must fail closed.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.onlyBinary) 'SkillSpector dependencies must resolve to wheels only.'
        Assert-True ($null -ne $toolchain.tools.skillspector.pythonDistribution.PSObject.Properties['allowDirectReferences']) 'SkillSpector direct-reference policy must be explicit.'
        Assert-False ([bool]$toolchain.tools.skillspector.pythonDistribution.allowDirectReferences) 'SkillSpector dependencies must not bypass PyPI with direct references.'
        Assert-False ([bool]$toolchain.tools.skillspector.pythonDistribution.allowPipOnlineDependencyTraversal) 'pip must not traverse dependency metadata online.'
        Assert-False ([bool]$toolchain.tools.skillspector.pythonDistribution.allowYanked) 'Yanked dependency candidates must not enter the verified pool.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.disableCache) 'SkillSpector dependency acquisition must disable pip cache.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.candidateDiscovery 'approved-simple-json-lazy' 'Candidate discovery must use the approved Simple JSON API lazily.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.requiresPythonPolicy 'simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' 'Simple JSON and wheel METADATA Requires-Python normalized specifier sets must agree and allow the current interpreter.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.dependencyAcquisition 'verified-wheelhouse' 'SkillSpector dependencies must use a verified wheelhouse.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.dependencyResolver 'pip-offline-backtracking' 'pip must backtrack only against the verified local wheel pool.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.installEnvironment 'isolated-venv' 'SkillSpector must install in an isolated virtual environment.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.interpreterIsolation 'python-isolated-mode' 'Every resolver-managed SkillSpector Python subprocess must ignore inherited interpreter controls.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.credentialIsolation 'github-token-cleared-before-python' 'Resolver-managed Python must start only after GitHub credentials are removed.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.installedMetadataVerification 'static-dist-info-metadata' 'Installed identity must be verified without starting installed Python.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.verifyOfflineResolution) 'The completed wheelhouse must pass a fully offline dependency resolution.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.installNoIndex) 'SkillSpector install must be no-index.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.requireHashes) 'SkillSpector install must require hashes.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.recordDependencyClosureHashes) 'SkillSpector dependency closure hashes must be recorded.'

        Assert-Equal $toolchain.tools.'skill-tools'.registry 'https://registry.npmjs.org/' 'skill-tools must use the approved npm registry.'
        Assert-Equal $toolchain.tools.'skill-tools'.npmDistribution.configIsolation 'empty-config-and-workdir' 'npm configuration and project discovery must be isolated.'
        Assert-Equal $toolchain.tools.'skill-tools'.npmDistribution.environmentOverridePolicy 'deny-by-default' 'Inherited npm configuration must be denied by default.'
        Assert-True ([bool]$toolchain.tools.'skill-tools'.npmDistribution.ignoreScripts) 'npm lifecycle scripts must be disabled.'
        Assert-True ([bool]$toolchain.tools.'skill-tools'.npmDistribution.recordDependencyClosureIntegrity) 'npm dependency closure integrity must be recorded.'
        Assert-Equal $toolchain.tools.'skill-validator'.stableVersionRule 'release-semver-only' 'skill-validator must require release SemVer.'
        Assert-Equal $toolchain.tools.'skill-validator'.proxy 'https://proxy.golang.org' 'skill-validator must use the approved Go module proxy.'
        Assert-Equal $toolchain.tools.'skill-validator'.checksumDatabase 'sum.golang.org' 'skill-validator must use the approved Go checksum database.'
        Assert-Equal $toolchain.tools.'skill-validator'.goRuntimeVersion '1.26.8' 'skill-validator must use the approved security-patched Go runtime.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOENV 'off' 'Go persisted environment configuration must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOPROXY 'https://proxy.golang.org' 'Go proxy environment must be fixed.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOSUMDB 'sum.golang.org' 'Go checksum database environment must be fixed.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOPRIVATE '' 'GOPRIVATE must not bypass canonical distribution.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GONOPROXY 'none' 'GONOPROXY must not bypass the approved proxy.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GONOSUMDB 'none' 'GONOSUMDB must not bypass checksum verification.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOINSECURE '' 'GOINSECURE must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOFLAGS '' 'GOFLAGS must not inject caller-controlled build behavior.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOTOOLCHAIN 'local' 'Go toolchain auto-download must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOWORK 'off' 'Go workspace discovery must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.CGO_ENABLED '0' 'CGO tool execution must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.moduleCacheIsolation 'temporary-empty' 'Go module resolution must use a fresh temporary module cache.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.buildCacheIsolation 'temporary-empty' 'Go builds must use a fresh build cache.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.temporaryDirectoryIsolation 'temporary-empty' 'Go builds must use a fresh temporary directory.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.binaryInstallIsolation 'run-owned' 'Go binaries must install into a run-owned directory.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectInheritedModuleCache) 'An inherited Go module cache override must fail closed.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectInheritedBuildCache) 'An inherited Go build cache override must fail closed.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectDangerousEnvironment) 'Dangerous Go build environment must fail closed.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.recordBinaryHash) 'Installed Go binary hashes must be recorded.'
        Assert-Equal $toolchain.tools.pester.repository 'https://www.powershellgallery.com/api/v2' 'Pester must use the approved PowerShell Gallery endpoint.'
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

    It 'UnitT25a_rejects_string_values_for_boolean_policy_controls' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.sourceTrust.failClosedOnMismatch = 'true'
        $invalidPath = Join-Path $TestDrive 'string-boolean-validation-toolchain.json'
        [IO.File]::WriteAllText($invalidPath, ($toolchain | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $invalidPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        Assert-Match $errorMessage 'failClosedOnMismatch.*boolean' 'A string that looks like a boolean must not satisfy a JSON boolean control.'
    }

    It 'UnitT25b_rejects_unexpected_policy_keys' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.tools.skillspector.pythonDistribution | Add-Member -NotePropertyName futureBypass -NotePropertyValue $true
        $invalidPath = Join-Path $TestDrive 'extra-key-validation-toolchain.json'
        [IO.File]::WriteAllText($invalidPath, ($toolchain | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $invalidPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        Assert-Match $errorMessage 'pythonDistribution.*invalid property set.*futureBypass' 'Unknown policy controls must fail closed.'
    }

    It 'UnitT26_rejects_an_unapproved_npm_registry_before_skill_tools_resolution' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $previous = @((Get-ProcessNpmEnvironmentNames) + (Get-ProcessNodeEnvironmentNames) | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        $errorMessage = $null
        try {
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $null, [EnvironmentVariableTarget]::Process)
            }
            [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'https://registry.example.invalid/', [EnvironmentVariableTarget]::Process)
            Assert-NoConflictingNpmEnvironment -ExpectedRegistry 'https://registry.npmjs.org/'
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        finally {
            foreach ($name in @((Get-ProcessNpmEnvironmentNames) + (Get-ProcessNodeEnvironmentNames))) {
                [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
            }
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

        $environmentNames = @(Get-OrdinalUniqueStrings -Values @((Get-ProcessPipEnvironmentNames) + @($cases.Name)))
        $previous = @($environmentNames | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        try {
            foreach ($case in $cases) {
                foreach ($name in $environmentNames) {
                    [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
                }
                $errorMessage = $null
                try {
                [Environment]::SetEnvironmentVariable($case.Name, $case.Value, [EnvironmentVariableTarget]::Process)
                Assert-NoConflictingPipEnvironment -ApprovedIndex 'https://pypi.org/simple'
                }
                catch {
                    $errorMessage = $_.Exception.Message
                }

                Assert-Match $errorMessage ("Untrusted pip environment override.*{0}" -f $case.Name) ("pip override {0} must fail before dependency resolution." -f $case.Name)
            }
        }
        finally {
            foreach ($name in $environmentNames) {
                [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT26b_accepts_the_approved_pip_environment_and_executes_the_action' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $names = @(Get-OrdinalUniqueStrings -Values @(
            (Get-ProcessPipEnvironmentNames) + (Get-ProcessPythonEnvironmentNames) + @('PIP_INDEX_URL', 'PIP_CONFIG_FILE')
        ))
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
                $unexpectedPython = @(Get-ProcessPythonEnvironmentNames | Where-Object {
                    -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, [EnvironmentVariableTarget]::Process))
                })
                if ($unexpectedPython.Count -gt 0) { throw "Unexpected effective Python environment override: $($unexpectedPython -join ', ')" }
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

    It 'UnitT26ba_rejects_Python_import_overrides_without_rejecting_setup_python_runner_metadata' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $transportOverrides = @('REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR')
        $names = @('pythonLocation', 'Python_ROOT_DIR', 'Python3_ROOT_DIR', 'PYTHONPATH') + $transportOverrides
        $previous = @($names | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        try {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }
            [Environment]::SetEnvironmentVariable('pythonLocation', '/runner/toolcache/python', [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('Python_ROOT_DIR', '/runner/toolcache/python', [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('Python3_ROOT_DIR', '/runner/toolcache/python', [EnvironmentVariableTarget]::Process)
            Assert-NoConflictingPythonEnvironment
            $detectedPythonOverrides = @(Get-ProcessPythonEnvironmentNames | Where-Object {
                -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, [EnvironmentVariableTarget]::Process))
            })
            Assert-Equal $detectedPythonOverrides.Count 0 ("setup-python metadata must not be mistaken for interpreter startup configuration. Detected='{0}'." -f ($detectedPythonOverrides -join ','))

            foreach ($case in @(
                @{ Name = 'PYTHONPATH'; Value = '/untrusted/import-root' },
                @{ Name = 'REQUESTS_CA_BUNDLE'; Value = '/untrusted/requests-ca.pem' },
                @{ Name = 'CURL_CA_BUNDLE'; Value = '/untrusted/curl-ca.pem' },
                @{ Name = 'SSL_CERT_FILE'; Value = '/untrusted/openssl-ca.pem' },
                @{ Name = 'SSL_CERT_DIR'; Value = '/untrusted/openssl-ca-dir' }
            )) {
                [Environment]::SetEnvironmentVariable([string]$case.Name, [string]$case.Value, [EnvironmentVariableTarget]::Process)
                $errorMessage = $null
                try { Assert-NoConflictingPythonEnvironment }
                catch { $errorMessage = $_.Exception.Message }
                Assert-Match $errorMessage ("Untrusted Python environment override.*{0}" -f $case.Name) "$($case.Name) must fail closed before Python network or interpreter execution."
                [Environment]::SetEnvironmentVariable([string]$case.Name, $null, [EnvironmentVariableTarget]::Process)
            }
        }
        finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
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
        $helper = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:PythonClosureHelperPath
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $resolver 'function Invoke-IsolatedPythonCommand' 'Python isolation must be centralized in one command wrapper.'
        Assert-Match $resolver 'return Invoke-CheckedCommand.*@\(''-I''\) \+ \$Arguments' 'Every wrapped Python subprocess must prepend isolated mode.'
        Assert-NotMatch $resolver "Invoke-CheckedCommand -Command 'python'" 'System Python must not bypass isolated mode.'
        Assert-NotMatch $resolver 'Invoke-CheckedCommand -Command \$venvPython' 'Virtual-environment Python must not bypass isolated mode.'
        Assert-Match $resolver "Invoke-IsolatedPythonCommand -PythonCommand .* -Arguments @\('-S', '-m', 'venv'" 'SkillSpector must create its virtual environment with isolated Python startup and without site initialization.'
        Assert-Match $resolver '\$venvPython' 'SkillSpector dependency acquisition and install must use the virtual-environment Python.'
        Assert-Match $resolver "Invoke-IsolatedPythonCommand -PythonCommand .* -Arguments @\(\s*'-m', 'pip'" 'Every pip invocation must ignore inherited Python configuration.'
        Assert-NotMatch $resolver '--break-system-packages' 'Canonical install must not bypass PEP 668 protections.'
        Assert-Match $resolver 'Resolve-PythonWheelClosureFromApprovedIndex' 'SkillSpector must delegate candidate acquisition to the verified helper.'
        Assert-Match $helper 'application/vnd\.pypi\.simple\.v1\+json' 'Candidate acquisition must use the PyPI Simple JSON contract.'
        Assert-Match $helper 'ValidatedRedirectHandler' 'Candidate acquisition must reject redirects before following them.'
        Assert-Match $helper 'parse_wheel_filename' 'Candidate acquisition must validate wheel identity and compatibility.'
        Assert-Match $helper 'Python direct dependency reference is not allowed' 'Candidate metadata must reject direct references before pip sees it.'
        Assert-Match $helper 'Candidate hash mismatch' 'Candidate bytes must match approved Simple JSON hashes.'
        Assert-Match $helper 'Candidate Requires-Python mismatch' 'Simple JSON and wheel METADATA Requires-Python must agree before pip sees a candidate.'
        Assert-Match $helper 'METADATA Requires-Python is incompatible' 'Root and dependency wheels must allow the current interpreter.'
        Assert-Match $helper 'def verify_evidence' 'Candidate inventory, pip report, and selected closure identities must be recomputed across files.'
        Assert-Match $helper '"--no-index"' 'pip backtracking must use only the verified local pool.'
        Assert-Match $helper '"--only-binary=:all:"' 'Dependency resolution must reject source distributions.'
        Assert-Match $resolver '--no-cache-dir' 'Dependency acquisition must not reuse pip cache.'
        Assert-Match $resolver 'New-PythonWheelhouseLock' 'Dependency closure must be hash inventoried.'
        Assert-Match $resolver '--no-index' 'Final SkillSpector installation must not use an index.'
        Assert-Match $resolver '--require-hashes' 'Final SkillSpector installation must enforce hashes.'
        Assert-Match $resolver '--no-deps' 'Final installation must not resolve new dependencies outside the locked closure.'
        Assert-Match $resolver 'interpreterIsolation=\$interpreterIsolation' 'Resolved SkillSpector identity must record Python interpreter isolation.'
        Assert-Match $resolver '\$result\.interpreterIsolation = ' 'The machine-readable receipt must expose Python interpreter isolation.'
        Assert-Match $resolver 'directReferences=blocked' 'Resolved SkillSpector identity must record direct-reference blocking.'
        Assert-Match $resolver '\$result\.directReferencesAllowed = ' 'The machine-readable receipt must expose direct-reference policy.'
        Assert-Match $resolver 'pipOnlineDependencyTraversal=disabled' 'Resolved SkillSpector identity must record that pip cannot traverse dependencies online.'
        Assert-Match $resolver 'dependencyDiscovery=approved-simple-json-lazy' 'Resolved SkillSpector identity must record mediated candidate discovery.'
        Assert-Match $resolver 'requiresPython=simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' 'Resolved SkillSpector identity must record Requires-Python cross-verification.'
        Assert-Match $resolver 'offlineBacktracking=verified' 'Resolved SkillSpector identity must record offline backtracking.'
        Assert-Match $resolver '\$result\.pipOnlineDependencyTraversalAllowed = ' 'The machine-readable receipt must expose pip online traversal policy.'
        Assert-Match $resolver '\$result\.resolverHelperSha256 = ' 'The machine-readable receipt must bind the exact Python helper.'
        Assert-Match $resolver '\$result\.requiresPythonPolicy = ' 'The machine-readable receipt must expose Requires-Python verification policy.'
        Assert-Match $resolver '\$result\.offlineResolutionVerified = ' 'The machine-readable receipt must expose offline dependency-resolution verification.'
        Assert-NotMatch $resolver 'Invoke-CheckedCommand -Command \$installedExecutablePath' 'Resolver verification must not bypass isolated Python by executing the console script directly.'
        Assert-Match $helper '"--dry-run"' 'The completed candidate pool must be resolved by pip without installation.'
        Assert-Match $standard '`SkillSpector`.*resolver \*\*MUST\*\*' 'Normative authority must define SkillSpector resolver controls.'
        Assert-Match $standard 'Python `-I` isolated mode' 'Normative authority must require inherited Python interpreter isolation.'
        Assert-Match $standard '--no-index --require-hashes --no-deps' 'Normative authority must require offline hash-locked installation.'
    }

    It 'UnitT26da_ignores_inherited_PYTHONPATH_for_every_Python_subprocess' {
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

    It 'UnitT26db_rejects_direct_Python_dependency_references_before_network_resolution' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $wheelhouse = Join-Path $TestDrive 'direct-reference-wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse -Force)
        $safeWheel = New-TestWheel -Root $wheelhouse -Name 'safe-package' -Version '1.0.0' -RequiresDist @('dependency-a>=1.0')
        $unsafeWheel = New-TestWheel -Root $wheelhouse -Name 'unsafe-package' -Version '1.0.0' -RequiresDist @("dependency-b @`n https://packages.example.invalid/dependency-b.whl")

        $safeMetadata = Get-PythonWheelMetadata -WheelPath $safeWheel
        Assert-NoPythonDirectReferences -Metadata $safeMetadata -WheelFileName ([IO.Path]::GetFileName($safeWheel))
        $selfTestOutput = Invoke-IsolatedPythonCommand `
            -PythonCommand (Assert-Command -Name 'python') `
            -Arguments @($script:PythonClosureHelperPath, 'self-test')
        Assert-Match ($selfTestOutput -join "`n") 'python-wheel-closure-self-test: passed' 'Offline A/B/C backtracking and helper security regressions must pass.'

        $errorMessage = $null
        try {
            $unsafeMetadata = Get-PythonWheelMetadata -WheelPath $unsafeWheel
            Assert-NoPythonDirectReferences -Metadata $unsafeMetadata -WheelFileName ([IO.Path]::GetFileName($unsafeWheel))
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'Python direct dependency reference is not allowed' 'Direct URL dependency metadata must fail closed.'

        $lockPath = Join-Path $TestDrive 'unsafe-dependency-lock.txt'
        $errorMessage = $null
        try { New-PythonWheelhouseLock -WheelhousePath $wheelhouse -LockPath $lockPath | Out-Null }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'Python direct dependency reference is not allowed' 'Every wheel in the completed dependency closure must be checked.'

        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $resolveStart = $resolver.IndexOf('function Resolve-SkillSpector')
        $resolveBody = $resolver.Substring($resolveStart)
        $directReferenceCheck = $resolveBody.IndexOf('Assert-NoPythonDirectReferences')
        $githubCredentialRemoval = $resolveBody.IndexOf("Remove-Item -LiteralPath 'Env:GITHUB_TOKEN'")
        $dependencyAcquisition = $resolveBody.IndexOf('Resolve-PythonWheelClosureFromApprovedIndex')
        Assert-True ($directReferenceCheck -ge 0 -and $directReferenceCheck -lt $dependencyAcquisition) 'Root direct references must be rejected before approved-index dependency acquisition.'
        Assert-True ($githubCredentialRemoval -ge 0 -and $githubCredentialRemoval -lt $dependencyAcquisition) 'GitHub release credentials must be removed before approved-index dependency acquisition.'
    }

    It 'UnitT26e_rejects_npm_and_Node_process_overrides_before_invocation' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $cases = @(
            @{ Name = 'NPM_CONFIG_DRY_RUN'; Value = 'true'; Pattern = 'Untrusted npm environment override' },
            @{ Name = 'npm_config_dry_run'; Value = ' '; Pattern = 'Untrusted npm environment override' },
            @{ Name = 'NPM_CONFIG_USERCONFIG'; Value = 'untrusted.npmrc'; Pattern = 'Untrusted npm environment override' },
            @{ Name = 'NODE_OPTIONS'; Value = '--require=/tmp/untrusted-hook.js'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'NODE_PATH'; Value = '/tmp/untrusted-modules'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'NODE_TLS_REJECT_UNAUTHORIZED'; Value = '0'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'NODE_EXTRA_CA_CERTS'; Value = '/tmp/untrusted-ca.pem'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'SSL_CERT_FILE'; Value = '/tmp/untrusted-openssl-ca.pem'; Pattern = 'Untrusted Node environment override' }
        )
        $ambientNames = @(Get-OrdinalUniqueStrings -Values @(
            (Get-ProcessNpmEnvironmentNames) + (Get-ProcessNodeEnvironmentNames) + @($cases.Name)
        ))
        $previous = @($ambientNames | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        try {
            foreach ($case in $cases) {
                foreach ($name in $ambientNames) {
                    [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
                }
                [Environment]::SetEnvironmentVariable([string]$case.Name, [string]$case.Value, [EnvironmentVariableTarget]::Process)
                $errorMessage = $null
                try {
                    Assert-NoConflictingNpmEnvironment -ExpectedRegistry 'https://registry.npmjs.org/'
                }
                catch {
                    $errorMessage = $_.Exception.Message
                }
                Assert-Match $errorMessage ("{0}.*{1}" -f $case.Pattern, $case.Name) ("{0} must fail before npm invocation." -f $case.Name)
            }
        }
        finally {
            foreach ($name in @(Get-OrdinalUniqueStrings -Values @((Get-ProcessNpmEnvironmentNames) + (Get-ProcessNodeEnvironmentNames) + $ambientNames))) {
                [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT26ea_rejects_scoped_registry_configuration_even_with_an_approved_default' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $configuration = [pscustomobject][ordered]@{
            registry = 'https://registry.npmjs.org/'
            audit = $false
        }
        $configuration | Add-Member -NotePropertyName '@skill-tools:registry' -NotePropertyValue 'https://registry.example.invalid/'
        $errorMessage = $null
        try {
            Assert-ApprovedNpmConfigurationObject -Configuration $configuration -ExpectedRegistry 'https://registry.npmjs.org/'
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'Untrusted scoped npm registry.*@skill-tools:registry' 'A scoped registry must not bypass the approved default registry.'
    }

    It 'UnitT26f_validates_npm_lock_version_endpoint_integrity_and_root_bin_identity' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $integrity = 'sha512-' + ('A' * 86) + '=='
        $lock = [ordered]@{
            name = 'standard-validation-skill-tools'
            version = '1.0.0'
            lockfileVersion = 3
            requires = $true
            packages = [ordered]@{
                '' = [ordered]@{
                    name = 'standard-validation-skill-tools'
                    version = '1.0.0'
                    dependencies = [ordered]@{ 'skill-tools' = '0.4.1' }
                }
                'node_modules/skill-tools' = [ordered]@{
                    version = '0.4.1'
                    resolved = 'https://registry.npmjs.org/skill-tools/-/skill-tools-0.4.1.tgz'
                    integrity = $integrity
                    bin = [ordered]@{ 'skill-tools' = './dist/cli.js' }
                }
                'node_modules/@skill-tools/dependency' = [ordered]@{
                    version = '1.2.3'
                    resolved = 'https://registry.npmjs.org/@skill-tools/dependency/-/dependency-1.2.3.tgz'
                    integrity = $integrity
                }
            }
        }
        $lockPath = Join-Path $TestDrive 'package-lock.json'
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))

        $identity = Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1'
        Assert-Match $identity.packageLockSha256 '^[0-9a-f]{64}$' 'The raw package-lock must be hashed.'
        Assert-Match $identity.closureSha256 '^[0-9a-f]{64}$' 'The canonical dependency closure must be hashed separately.'
        Assert-Equal @($identity.entries).Count 2 'Every locked npm package must be represented in closure evidence.'
        Assert-Equal $identity.rootBinTarget 'dist/cli.js' 'The lock must bind the canonical skill-tools bin target.'
        foreach ($acceptedBin in @(
            @{ Value='dist/cli.js'; Expected='dist/cli.js' },
            @{ Value='./dist/cli.js'; Expected='dist/cli.js' },
            @{ Value='.\dist\.\cli.js'; Expected='dist/cli.js' },
            @{ Value='dist/./cli.js'; Expected='dist/cli.js' },
            @{ Value='.hidden/cli.js'; Expected='.hidden/cli.js' },
            @{ Value='dist/.../cli.js'; Expected='dist/.../cli.js' },
            @{ Value='dist/..hidden/cli.js'; Expected='dist/..hidden/cli.js' }
        )) {
            Assert-Equal `
                (Get-CanonicalNpmBinTarget -Value $acceptedBin.Value -Context 'test bin') `
                $acceptedBin.Expected `
                "Safe npm bin target '$($acceptedBin.Value)' must canonicalize deterministically."
        }
        Assert-Equal `
            (Get-CanonicalNpmBinTarget -Value './dist/cli.js' -Context 'installed test bin') `
            (Get-CanonicalNpmBinTarget -Value 'dist/cli.js' -Context 'lock test bin') `
            'Installed and lockfile spellings of the same npm bin target must compare identically.'
        Assert-False `
            ((Get-CanonicalNpmBinTarget -Value 'dist/other.js' -Context 'test bin') -ceq $identity.rootBinTarget) `
            'Canonicalization must not make different npm bin targets compare equal.'
        foreach ($unsafeBin in @(
            $null, 7, '', '   ', '/dist/cli.js', '\\server\share\cli.js', 'C:\dist\cli.js', 'C:dist\cli.js',
            'https://example.invalid/cli.js', '../dist/cli.js', 'dist/../cli.js', 'dist//cli.js', 'dist\\cli.js',
            'dist/', '.', './.', 'dist:cli.js', ("dist/{0}cli.js" -f [char]0x0000),
            ("dist/{0}cli.js" -f [char]0x007f), ("dist/{0}cli.js" -f [char]0x0085),
            ("dist/{0}cli.js" -f [char]0x009f)
        )) {
            $binError = $null
            try { Get-CanonicalNpmBinTarget -Value $unsafeBin -Context 'test bin' | Out-Null }
            catch { $binError = $_.Exception.Message }
            Assert-Match $binError 'safe relative package path' "Unsafe npm bin target '$unsafeBin' must fail closed."
        }
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        Assert-Match $resolver '\$installedBinTarget = Get-CanonicalNpmBinTarget' 'Installed and lockfile bin targets must share the same canonicalization rule.'

        $lock.packages.'node_modules/skill-tools'.bin['skill-tools'] = '../dist/cli.js'
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $unsafeLockError = $null
        try {
            Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1' | Out-Null
        }
        catch {
            $unsafeLockError = $_.Exception.Message
        }
        Assert-Match $unsafeLockError 'unsafe or missing skill-tools bin target' 'Unsafe npm bin targets must also fail closed through lockfile verification.'
        $lock.packages.'node_modules/skill-tools'.bin['skill-tools'] = './dist/cli.js'

        $lock.packages.'node_modules/@skill-tools/dependency'.resolved = 'https://registry.example.invalid/dependency.tgz'
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $errorMessage = $null
        try {
            Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1' | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'untrusted endpoint' 'A dependency resolved outside the approved registry must fail closed.'
    }

    It 'UnitT26g_keeps_run_owned_install_directories_under_the_requested_root' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $requestedRoot = Join-Path $TestDrive 'validation-tools'
        $first = New-RunOwnedInstallDirectory -Root $requestedRoot -ToolName 'skillspector'
        $second = New-RunOwnedInstallDirectory -Root $requestedRoot -ToolName 'skillspector'
        $rootPrefix = [IO.Path]::GetFullPath($requestedRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        Assert-True ($first.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) 'A run-owned install must remain under InstallRoot.'
        Assert-True (Test-Path -LiteralPath $first -PathType Container) 'The first install directory must remain available after allocation returns.'
        Assert-True (Test-Path -LiteralPath $second -PathType Container) 'The second install directory must remain available after allocation returns.'
        Assert-False ([string]::Equals($first, $second, [StringComparison]::OrdinalIgnoreCase)) 'Each resolver invocation must receive a unique install directory.'

        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        Assert-Match $resolver '\[string\] \$InstallRoot' 'The resolver must expose the persistent InstallRoot contract.'
        Assert-Match $resolver 'installRoot = \$resolved\.installRoot' 'Every tool receipt must project its run-owned install root.'
        Assert-Match $resolver 'executablePath = \$resolved\.executablePath' 'Every tool receipt must project its exact executable path.'
        Assert-Match $resolver 'executableSha256 = \$resolved\.executableSha256' 'Every tool receipt must project its exact executable hash.'
    }

    It 'UnitT27_requires_authority_CI_to_use_the_central_tool_resolver' {
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:WorkflowPath
        $requiredWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RequiredPowerShellWorkflowPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath

        . $script:AuthorityGatePath -DefineFunctionsOnly

        Assert-Match $workflow '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1 -ArtifactsRoot \$env:RUNNER_TEMP\s*$' 'Standards workflow must execute the shared authority gate.'
        Assert-Match $workflow "'scripts/Resolve-PythonWheelClosure\.py'" 'Python helper changes must trigger the standalone authority workflow.'
        Assert-NotMatch $workflow '(?m)^\s*& .*Resolve-StandardValidationTool\.ps1' 'Standards workflow must not maintain a divergent inline resolver sequence.'
        Assert-NotMatch $workflow 'Install-Module\s+Pester' 'Workflow must not bypass the central resolver with direct Pester installation.'

        Assert-Match $requiredWorkflow 'Composition \(PowerShell 7 on Linux\)' 'Ruleset-required Composition context must remain present.'
        Assert-Match $requiredWorkflow '(?ms)^permissions:\r?\n  contents: read\r?\n\r?\njobs:' 'Required workflow token permissions must be explicitly read-only.'
        Assert-Match $requiredWorkflow 'Run required Standard v1 authority gate' 'Required Composition context must execute the authority gate.'
        Assert-Match $requiredWorkflow '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1 -ArtifactsRoot \$env:RUNNER_TEMP\s*$' 'Required context must execute the same shared authority gate.'
        Assert-NotMatch $requiredWorkflow '(?m)^\s*& .*Resolve-StandardValidationTool\.ps1' 'Required context must not maintain a divergent inline resolver sequence.'
        Assert-Match $gate 'tests/skill-repository-standard\.Tests\.ps1' 'Shared gate must run the Standard authority regression.'
        Assert-Match $gate 'tests/skill-repository-workflows\.Tests\.ps1' 'Shared gate must run the workflow authority regression.'
        Assert-Match $gate 'tests/standard-validation-resolver-hardening\.Tests\.ps1' 'Shared gate must run the resolver-hardening authority regression.'

        $expectedGateSources = [ordered]@{
            'skillspector' = 'NVIDIA/SkillSpector'
            'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
            'skill-tools' = 'npm:skill-tools'
            'pester' = 'PowerShellGallery:Pester'
        }
        foreach ($entry in $expectedGateSources.GetEnumerator()) {
            Assert-Match $gate ("'{0}'\s*=\s*'{1}'" -f [regex]::Escape([string]$entry.Key), [regex]::Escape([string]$entry.Value)) ("Shared gate must freeze {0} from its approved source." -f $entry.Key)
        }
        Assert-Match $gate "(?s)trustedGoRuntimeVersion'.*?-Expected '1\.26\.8'" 'Shared gate must bind the policy receipt to the approved Go runtime.'
        Assert-Match $gate "goRuntimeVersion.*'1\.26\.8'" 'Shared gate must bind the skill-validator receipt to the verified Go runtime.'
        Assert-Match $gate 'resolvedIdentity.*goRuntime=1\.26\.8' 'Shared gate must require the Go runtime in the resolved identity.'
        Assert-Match $gate '(?m)^\s*& \$resolverPath -ValidatePolicyOnly -OutputPath \$policyReceiptPath \| Out-Host\s*$' 'Shared gate must validate policy before tool resolution.'
        Assert-Match $gate '(?m)^\s*& \$resolverPath -ToolName \$entry\.Key -Install -InstallRoot \$installRoot -OutputPath \$receiptPath \| Out-Host\s*$' 'Shared gate must install the complete frozen toolset through the resolver.'
        Assert-Match $gate '(?ms)\$receipts\[\$entry\.Key\] = \$receipt\r?\n\s+if \(\$entry\.Key -ceq ''skillspector''\) \{\r?\n\s+Remove-Item -LiteralPath ''Env:GITHUB_TOKEN'' -Force -ErrorAction SilentlyContinue\r?\n\s+Remove-Item -LiteralPath ''Env:GH_TOKEN'' -Force -ErrorAction SilentlyContinue\r?\n\s+\}' 'Shared gate must remove GitHub release-resolution credentials immediately after SkillSpector installation and before resolving another tool.'
        Assert-Match $gate 'SkillSpector static scan' 'Shared gate must execute the resolved SkillSpector static scanner.'
        Assert-Match $gate 'skill-validator package validation' 'Shared gate must execute the resolved skill-validator.'
        Assert-Match $gate '-Command \$skillToolsNode' 'Shared gate must invoke the frozen Node runtime for skill-tools.'
        Assert-Match $gate '-Arguments @\(\$skillToolsEntryPoint, ''check'', \$fixtureRoot' 'Shared gate must pass the frozen skill-tools entry point and check command without a wrapper re-resolution.'
        Assert-Match $gate 'Import-Module \$pesterModulePath -Force' 'Shared gate must import the frozen Pester module by exact path.'
        Assert-Match $gate 'credentialIsolation=github-token-cleared-before-python' 'Shared gate must verify that resolver-managed Python did not inherit GitHub credentials.'
        Assert-Match $gate 'installedMetadataVerification=static-dist-info-metadata' 'Shared gate must verify static installed metadata inspection.'
        Assert-Match $gate 'resolutionRounds=\$\(\$skillSpectorReceipt\.resolutionRounds\)' 'Shared gate must bind resolution rounds into the resolver identity.'
        Assert-Match $gate 'consoleEntryPoint=\$\(\$skillSpectorReceipt\.consoleEntryPoint\)' 'Shared gate must bind the static console entry point into the resolver identity.'
        Assert-Match $gate 'Invoke-Pester -Path \$authorityTestPaths -PassThru' 'Shared gate must execute all three authority regressions through frozen Pester.'
        Assert-Match $gate '(?ms)^\s*Assert-AuthorityPesterResult\s+`\r?\n\s+-Result \$authorityResult\s+`\r?\n\s+-MinimumTotalCount 45\s+`\r?\n\s+-PesterMajorVersion' 'Shared gate must validate the complete combined authority inventory with the resolved Pester result shape.'

        # Scenario: External validators return clean-looking reports for a different package, incomplete inventory, or downgraded findings.
        # Purpose: Bind every report to this exact fixture and interpret native report severity without PowerShell coercion.
        $reportFixture = New-TestAuthorityFixture -Root (Join-Path $TestDrive 'standard-validation-fixture')
        $fixtureInventory = @('SKILL.md', 'agents/openai.yaml')

        $skillSpectorBaseline = [pscustomobject][ordered]@{
            execution_successful=$true
            analysis_completeness=[pscustomobject][ordered]@{
                execution_successful=$true; is_complete=$true; status='complete'; coverage_percent=100
                ledger_exceptions=@(); scope_exclusions=@(); limitations=@()
            }
            skill=[pscustomobject]@{ name='standard-validation-fixture'; source=$reportFixture.Root }
            components=@(
                [pscustomobject]@{ path='SKILL.md'; type='markdown' },
                [pscustomobject]@{ path='agents/openai.yaml'; type='yaml' }
            )
            issues=@()
            risk_assessment=[pscustomobject]@{ recommendation='SAFE' }
        }
        Assert-AuthoritySkillSpectorReport -Report $skillSpectorBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedSkillId 'standard-validation-fixture' -ExpectedInventoryPaths $fixtureInventory
        $skillSpectorCases = @(
            @{ Pattern='unsuccessful or incomplete'; Mutate={ param($r) $r.analysis_completeness.coverage_percent='100' } },
            @{ Pattern='unsuccessful or incomplete'; Mutate={ param($r) $r.analysis_completeness.coverage_percent=$true } },
            @{ Pattern='unsuccessful or incomplete'; Mutate={ param($r) $r.analysis_completeness.status=1 } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.risk_assessment.recommendation=$true } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.issues=@([pscustomobject]@{ severity='CRITICAL' }) } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.issues=@([pscustomobject]@{ severity='WARNING' }) } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.issues=@([pscustomobject]@{ futureFinding=$true }) } },
            @{ Pattern='fixture identity'; Mutate={ param($r) $r.skill.name='other-fixture' } },
            @{ Pattern='fixture identity'; Mutate={ param($r) $r.skill.source=(Split-Path -Parent $reportFixture.Root) } },
            @{ Pattern='exact controlled fixture inventory'; Mutate={ param($r) $r.components=@($r.components[0]) } },
            @{ Pattern='exact controlled fixture inventory'; Mutate={ param($r) $r.components[1].path='other.yaml' } }
        )
        foreach ($case in $skillSpectorCases) {
            $report = Copy-TestJsonObject $skillSpectorBaseline
            & $case.Mutate $report
            $errorMessage = $null
            try { Assert-AuthoritySkillSpectorReport -Report $report -ExpectedFixtureRoot $reportFixture.Root -ExpectedSkillId 'standard-validation-fixture' -ExpectedInventoryPaths $fixtureInventory }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) 'SkillSpector report identity, inventory, findings, and scalar types must fail closed on drift.'
        }

        $skillValidatorBaseline = [pscustomobject][ordered]@{
            skill_dir=$reportFixture.Root; passed=$true; errors=0; warnings=0
            results=@(
                [pscustomobject]@{ level='pass'; category='structure'; message='SKILL.md structure is valid.'; file='SKILL.md'; line=1 },
                [pscustomobject]@{ level='info'; category='metadata'; message='Optional metadata was inspected.'; file='agents/openai.yaml' }
            )
        }
        Assert-AuthoritySkillValidatorReport -Report $skillValidatorBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory
        $skillValidatorCases = @(
            @{ Mutate={ param($r) $r.skill_dir=(Split-Path -Parent $reportFixture.Root) } },
            @{ Mutate={ param($r) $r.errors='0' } },
            @{ Mutate={ param($r) $r.errors=$false } },
            @{ Mutate={ param($r) $r.warnings='0' } },
            @{ Mutate={ param($r) $r.results=[pscustomobject]@{ level='pass'; category='structure'; message='scalar' } } },
            @{ Mutate={ param($r) $r.results=@($true) } },
            @{ Mutate={ param($r) $r.results[0].level='warning' } },
            @{ Mutate={ param($r) $r.results[0].level='error' } },
            @{ Mutate={ param($r) $r.results[0].level='unknown' } },
            @{ Mutate={ param($r) $r.results[0].level=1 } },
            @{ Mutate={ param($r) $r.results[0].category=$true } },
            @{ Mutate={ param($r) $r.results[0].message='' } },
            @{ Mutate={ param($r) $r.results[0].file='../outside.md' } },
            @{ Mutate={ param($r) $r.results[0].line='1' } }
        )
        foreach ($case in $skillValidatorCases) {
            $report = Copy-TestJsonObject $skillValidatorBaseline
            & $case.Mutate $report
            $errorMessage = $null
            try { Assert-AuthoritySkillValidatorReport -Report $report -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'skill-validator' 'skill-validator package binding, result shape, severity, and optional locations must fail closed on drift.'
        }

        $skillPath = Join-Path $reportFixture.Root 'SKILL.md'
        $sarifBaseline = [pscustomobject][ordered]@{
            version='2.1.0'
            runs=@([pscustomobject]@{
                tool=[pscustomobject]@{ driver=[pscustomobject]@{
                    name='skill-tools'
                    rules=@([pscustomobject]@{ id='fixture-rule'; defaultConfiguration=[pscustomobject]@{ level='warning' } })
                } }
                results=@([pscustomobject]@{
                    ruleId='fixture-rule'; level='warning'; message=[pscustomobject]@{ text='Controlled fixture advisory.' }
                    locations=@([pscustomobject]@{ physicalLocation=[pscustomobject]@{ artifactLocation=[pscustomobject]@{ uri=$skillPath } } })
                })
            })
        }
        Assert-AuthoritySkillToolsSarifReport -Report $sarifBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory
        $sarifExplicitLevelWithoutRuleDefault = Copy-TestJsonObject $sarifBaseline
        $sarifExplicitLevelWithoutRuleDefault.runs[0].tool.driver.rules[0].PSObject.Properties.Remove('defaultConfiguration')
        Assert-AuthoritySkillToolsSarifReport -Report $sarifExplicitLevelWithoutRuleDefault -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory
        $sarifDefaultLevelBaseline = Copy-TestJsonObject $sarifBaseline
        $sarifDefaultLevelBaseline.runs[0].results[0].PSObject.Properties.Remove('level')
        $sarifDefaultLevelBaseline.runs[0].tool.driver.rules[0].defaultConfiguration.level = 'note'
        Assert-AuthoritySkillToolsSarifReport -Report $sarifDefaultLevelBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory

        $sarifCases = @(
            @{ Mutate={ param($r) $r.version=2.1 } },
            @{ Mutate={ param($r) $r.runs[0].tool.driver.name=123 } },
            @{ Mutate={ param($r) $r.runs[0].tool.driver.rules=@() } },
            @{ Mutate={ param($r) $r.runs[0].results=[pscustomobject]@{ ruleId='fixture-rule' } } },
            @{ Mutate={ param($r) $r.runs[0].results=@($true) } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level=$true } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level=2 } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level='fatal' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level=@('warning') } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level='error' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].ruleId='unknown-rule' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].PSObject.Properties.Remove('defaultConfiguration') } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].defaultConfiguration.level=$true } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].defaultConfiguration.level='fatal' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].defaultConfiguration.level='error' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri=(Join-Path (Split-Path -Parent $reportFixture.Root) 'outside.md') } }
        )
        foreach ($case in $sarifCases) {
            $report = Copy-TestJsonObject $sarifBaseline
            & $case.Mutate $report
            $errorMessage = $null
            try { Assert-AuthoritySkillToolsSarifReport -Report $report -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'skill-tools' 'SARIF rule binding, effective severity, result shape, and fixture location must fail closed on drift.'
        }
    }

    # Scenario: Pester returns a normal all-passed authority result or discovers fewer tests than the reviewed inventory.
    # Purpose: Prove the shared gate accepts the controlled baseline and rejects zero/partial discovery.
    It 'UnitT27a_validates_the_complete_authority_Pester_inventory' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $clean = [pscustomobject][ordered]@{
            TotalCount=35; PassedCount=35; FailedCount=0; Result='Passed'
            FailedBlocksCount=0; FailedContainersCount=0; SkippedCount=0
            NotRunCount=0; InconclusiveCount=0; Errors=@()
        }
        Assert-AuthorityPesterResult -Result $clean -MinimumTotalCount 35 -PesterMajorVersion 6

        foreach ($total in @(0,34)) {
            $partial = $clean.PSObject.Copy()
            $partial.TotalCount = $total
            $partial.PassedCount = $total
            $errorMessage = $null
            try { Assert-AuthorityPesterResult -Result $partial -MinimumTotalCount 35 -PesterMajorVersion 6 }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'discovered only' 'Zero or partial authority-test discovery must fail closed.'
        }
    }

    # Scenario: Pester reports every test passed while discovery/container metadata still records a framework failure.
    # Purpose: Prevent a false green based only on FailedCount and PassedCount.
    It 'UnitT27b_rejects_hidden_Pester_block_container_and_discovery_errors' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $cases = @(
            @{ Name='FailedBlocksCount'; Value=1; Pattern='FailedBlocksCount=1' },
            @{ Name='FailedContainersCount'; Value=1; Pattern='FailedContainersCount=1' },
            @{ Name='SkippedCount'; Value=1; Pattern='SkippedCount=1' },
            @{ Name='NotRunCount'; Value=1; Pattern='NotRunCount=1' },
            @{ Name='InconclusiveCount'; Value=1; Pattern='InconclusiveCount=1' },
            @{ Name='Errors'; Value=@('discovery failed', 'container failed'); Pattern='discovery/container errors' }
        )
        foreach ($case in $cases) {
            $result = [pscustomobject][ordered]@{
                TotalCount=35; PassedCount=35; FailedCount=0; Result='Passed'
                FailedBlocksCount=0; FailedContainersCount=0; SkippedCount=0
                NotRunCount=0; InconclusiveCount=0; Errors=@()
            }
            $result.($case.Name) = $case.Value
            $errorMessage = $null
            try { Assert-AuthorityPesterResult -Result $result -MinimumTotalCount 35 -PesterMajorVersion 6 }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Pester $($case.Name) must fail closed."
        }
    }

    # Scenario: The controlled authority fixture loses metadata or drifts from its exact Skill identity and lexical contracts.
    # Purpose: Prevent the authority repository's no-active-Skill exception from validating a partial or malformed package.
    It 'UnitT31_rejects_incomplete_or_malformed_authority_fixtures' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $cases = @(
            @{
                Name='missing-openai-metadata'; Pattern='missing required file.*openai.yaml'
                Mutate={ param($fixture) Remove-Item -LiteralPath $fixture.MetadataPath -Force }
            },
            @{
                Name='wrong-default-prompt-token'; Pattern='must reference exact token'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.MetadataPath).Replace('$standard-validation-fixture', '$other-fixture')
                    Write-TestUtf8File -Path $fixture.MetadataPath -Text $text
                }
            },
            @{
                Name='unquoted-openai-string'; Pattern='double-quoted string values'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.MetadataPath).Replace('"Standard Validation Fixture"', 'Standard Validation Fixture')
                    Write-TestUtf8File -Path $fixture.MetadataPath -Text $text
                }
            },
            @{
                Name='quoted-openai-key'; Pattern='unquoted keys and double-quoted string values'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.MetadataPath).Replace('display_name:', '"display_name":')
                    Write-TestUtf8File -Path $fixture.MetadataPath -Text $text
                }
            },
            @{
                Name='wrong-frontmatter-identity'; Pattern='metadata or body is incomplete'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.SkillPath).Replace('name: standard-validation-fixture', 'name: other-fixture')
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            },
            @{
                Name='unknown-frontmatter-field'; Pattern='unsupported or duplicate frontmatter key'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.SkillPath).Replace("description: A deterministic Agent Skill package for authority validation.`n", "description: A deterministic Agent Skill package for authority validation.`nfuture-field: forbidden`n")
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            },
            @{
                Name='malformed-frontmatter-delimiter'; Pattern='closed YAML frontmatter'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.SkillPath).Replace("---`n`n# Standard Validation Fixture", "--`n`n# Standard Validation Fixture")
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            },
            @{
                Name='whitespace-only-body'; Pattern='metadata or body is incomplete'
                Mutate={ param($fixture)
                    $text = "---`nname: standard-validation-fixture`ndescription: A deterministic Agent Skill package for authority validation.`n---`n   `n"
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            }
        )

        $validFixture = New-TestAuthorityFixture -Root (Join-Path $TestDrive 'fixture-valid')
        Assert-AuthorityFixtureContract -FixtureRoot $validFixture.Root -ExpectedSkillId 'standard-validation-fixture'
        foreach ($case in $cases) {
            $fixture = New-TestAuthorityFixture -Root (Join-Path $TestDrive ([string]$case.Name))
            & $case.Mutate $fixture
            $errorMessage = $null
            try { Assert-AuthorityFixtureContract -FixtureRoot $fixture.Root -ExpectedSkillId 'standard-validation-fixture' }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Malformed fixture '$($case.Name)' must fail closed."
        }
    }

    # Scenario: GITHUB_SHA names a syntactically valid commit other than the checked-out candidate.
    # Purpose: Bind authority evidence to checkout HEAD rather than caller-controlled CI metadata.
    It 'UnitT32_rejects_a_GITHUB_SHA_that_does_not_match_checkout_HEAD' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $head = Get-AuthorityCandidateCommit -RepositoryRoot $script:RepositoryRoot -ExpectedCommit ''
        Assert-Match $head '^[0-9a-f]{40}$' 'Checkout HEAD must resolve to a full lowercase commit.'
        $wrongCommit = if ($head -ceq ('0' * 40)) { '1' * 40 } else { '0' * 40 }
        $previous = [Environment]::GetEnvironmentVariable('GITHUB_SHA', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('GITHUB_SHA', $wrongCommit, [EnvironmentVariableTarget]::Process)
            $errorMessage = $null
            try { Get-AuthorityCandidateCommit -RepositoryRoot $script:RepositoryRoot | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'does not match checkout HEAD' 'A different full GITHUB_SHA must not label the authority evidence.'
        }
        finally {
            [Environment]::SetEnvironmentVariable('GITHUB_SHA', $previous, [EnvironmentVariableTarget]::Process)
        }
    }

    # Scenario: Resolver receipts use text that PowerShell could coerce to trusted booleans or integers.
    # Purpose: Keep policy and installed-tool evidence type-strict after ConvertFrom-Json.
    It 'UnitT33_rejects_receipt_and_policy_scalar_coercion' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $installRoot = Join-Path $TestDrive 'receipt-install-root'
        $toolRoot = Join-Path $installRoot 'fixture-tool'
        [void](New-Item -ItemType Directory -Path $toolRoot -Force)
        $executablePath = Join-Path $toolRoot 'fixture-tool.bin'
        Write-TestUtf8File -Path $executablePath -Text 'fixture executable'
        $executableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $executablePath).Hash.ToLowerInvariant()
        $validReceipt = [pscustomobject][ordered]@{
            schemaVersion=1; toolName='fixture-tool'; source='fixture/source'; channel='latest-stable'
            frozenForRun=$true; resolvedVersion='1.0.0'; resolvedIdentity='fixture@1.0.0'
            identityKind='fixture-release'; installRoot=$toolRoot; executablePath=$executablePath
            executableSha256=$executableSha256; dependencyClosureSha256=('a' * 64)
            dependencyClosure=@([pscustomobject]@{ name='fixture-tool'; version='1.0.0' }, [pscustomobject]@{ name='dependency'; version='2.0.0' })
        }
        Assert-InstalledAuthorityToolReceipt -Receipt $validReceipt -ToolName 'fixture-tool' -ExpectedSource 'fixture/source' -InstallRoot $installRoot | Out-Null

        $receiptCases = @(
            @{ Name='schemaVersion'; Value='1'; Pattern='unsupported schemaVersion' },
            @{ Name='toolName'; Value=@('fixture-tool'); Pattern='wrong tool identity' },
            @{ Name='channel'; Value=@('latest-stable'); Pattern='must be the exact string' },
            @{ Name='frozenForRun'; Value='true'; Pattern='not frozen' },
            @{ Name='resolvedVersion'; Value=1; Pattern='missing resolvedVersion' },
            @{ Name='dependencyClosureSha256'; Value=('A' * 64); Pattern='lowercase SHA-256' },
            @{ Name='dependencyClosure'; Value=[pscustomobject]@{ name='scalar'; version='1.0.0' }; Pattern='does not contain a dependency/install closure' }
        )
        foreach ($case in $receiptCases) {
            $receipt = Copy-TestJsonObject -Value $validReceipt
            $receipt.([string]$case.Name) = $case.Value
            $errorMessage = $null
            try { Assert-InstalledAuthorityToolReceipt -Receipt $receipt -ToolName 'fixture-tool' -ExpectedSource 'fixture/source' -InstallRoot $installRoot | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Receipt coercion '$($case.Name)' must fail closed."
        }

        $validPolicy = [pscustomobject][ordered]@{
            schemaVersion=1; policy='latest-stable-per-validation-run'
            sourceTrust=[pscustomobject][ordered]@{ enforcement='exact-approved-source'; failClosedOnMismatch=$true }
            trustedGoRuntimeVersion='1.26.8'
            recordResolvedIdentityWhenAvailable=$true
        }
        Assert-AuthorityPolicyReceipt -Receipt $validPolicy
        foreach ($case in @(
            @{ Path='schemaVersion'; Value='1'; Pattern='unsupported schemaVersion' },
            @{ Path='policy'; Value=@('latest-stable-per-validation-run'); Pattern='must be the exact string' },
            @{ Path='sourceTrust.enforcement'; Value=1; Pattern='must be the exact string' },
            @{ Path='trustedGoRuntimeVersion'; Value=@('1.26.8'); Pattern='must be the exact string' },
            @{ Path='sourceTrust.failClosedOnMismatch'; Value='true'; Pattern='incomplete or untrusted' },
            @{ Path='recordResolvedIdentityWhenAvailable'; Value='true'; Pattern='incomplete or untrusted' }
        )) {
            $policy = Copy-TestJsonObject -Value $validPolicy
            if ([string]$case.Path -like 'sourceTrust.*') {
                $propertyName = ([string]$case.Path).Substring('sourceTrust.'.Length)
                $policy.sourceTrust.$propertyName = $case.Value
            }
            else {
                $policy.([string]$case.Path) = $case.Value
            }
            $errorMessage = $null
            try { Assert-AuthorityPolicyReceipt -Receipt $policy }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Policy coercion '$($case.Path)' must fail closed."
        }
    }

    # Scenario: Pester 4 and Pester 6 expose different result shapes, and required counts can arrive as coercible text.
    # Purpose: Fail closed on missing version-specific fields and scalar coercion in either supported result contract.
    It 'UnitT34_requires_type_strict_Pester4_and_Pester6_result_fields' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $newPester6Result = {
            [pscustomobject][ordered]@{
                TotalCount=35; PassedCount=35; FailedCount=0; Result='Passed'
                FailedBlocksCount=0; FailedContainersCount=0; SkippedCount=0
                NotRunCount=0; InconclusiveCount=0; Errors=@()
            }
        }
        $newPester4Result = {
            [pscustomobject][ordered]@{
                TotalCount=35; PassedCount=35; FailedCount=0
                SkippedCount=0; PendingCount=0; InconclusiveCount=0
            }
        }
        Assert-AuthorityPesterResult -Result (& $newPester6Result) -MinimumTotalCount 35 -PesterMajorVersion 6
        Assert-AuthorityPesterResult -Result (& $newPester4Result) -MinimumTotalCount 35 -PesterMajorVersion 4

        foreach ($versionCase in @(
            @{ Major=6; Factory=$newPester6Result; Required=@('Result','FailedBlocksCount','FailedContainersCount','SkippedCount','NotRunCount','InconclusiveCount') },
            @{ Major=4; Factory=$newPester4Result; Required=@('SkippedCount','PendingCount','InconclusiveCount') }
        )) {
            foreach ($name in @($versionCase.Required)) {
                $result = & $versionCase.Factory
                $result.PSObject.Properties.Remove([string]$name)
                $errorMessage = $null
                try { Assert-AuthorityPesterResult -Result $result -MinimumTotalCount 35 -PesterMajorVersion ([int]$versionCase.Major) }
                catch { $errorMessage = $_.Exception.Message }
                Assert-Match $errorMessage ("missing required property '{0}'" -f [regex]::Escape([string]$name)) "Pester $($versionCase.Major) must require $name."
            }
        }

        foreach ($case in @(
            @{ Major=6; Factory=$newPester6Result; Name='TotalCount'; Value='35'; Pattern='TotalCount.*non-negative integer' },
            @{ Major=6; Factory=$newPester6Result; Name='TotalCount'; Value=$false; Pattern='TotalCount.*non-negative integer' },
            @{ Major=6; Factory=$newPester6Result; Name='Result'; Value=@('Passed'); Pattern='status must be the exact string' },
            @{ Major=6; Factory=$newPester6Result; Name='FailedBlocksCount'; Value='0'; Pattern='FailedBlocksCount.*non-negative integer' },
            @{ Major=4; Factory=$newPester4Result; Name='PassedCount'; Value='35'; Pattern='PassedCount.*non-negative integer' },
            @{ Major=4; Factory=$newPester4Result; Name='PendingCount'; Value='0'; Pattern='PendingCount.*non-negative integer' },
            @{ Major=6; Factory=$newPester6Result; Name='Errors'; Value='one error'; Pattern='Errors must be an array' },
            @{ Major=6; Factory=$newPester6Result; Name='Errors'; Value=$null; Pattern='Errors must be an array' },
            @{ Major=6; Factory=$newPester6Result; Name='Errors'; Value=@('one error'); Pattern='discovery/container errors' }
        )) {
            $result = & $case.Factory
            $result.([string]$case.Name) = $case.Value
            $errorMessage = $null
            try { Assert-AuthorityPesterResult -Result $result -MinimumTotalCount 35 -PesterMajorVersion ([int]$case.Major) }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Pester $($case.Major) coercion '$($case.Name)' must fail closed."
        }
    }

    It 'UnitT28_rejects_prerelease_and_pseudo_versions_for_skill_validator' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        Assert-True (Test-StableGoModuleVersion -Version 'v1.6.1') 'A normal release version must be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v1.7.0-rc1') 'A prerelease version must not be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v0.0.0-20260902000000-0123456789ab') 'A pseudo-version must not be stable.'
        Assert-True (Test-StableNpmPackageVersion -Version '0.4.1') 'A normal npm release version must be stable.'
        Assert-True (Test-StableNpmPackageVersion -Version '1.2.3+build.4') 'SemVer build metadata may identify a stable npm release.'
        Assert-False (Test-StableNpmPackageVersion -Version '1.2.3-rc.1') 'An npm prerelease must not be stable.'
        Assert-False (Test-StableNpmPackageVersion -Version '^1.2.3') 'An npm range must not be accepted as one frozen version.'
        Assert-False (Test-StableNpmPackageVersion -Version '01.2.3') 'SemVer numeric identifiers must not contain leading zeroes.'
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

        $resolverLines = Get-Content -Encoding UTF8 -LiteralPath $script:ResolverPath
        $codeOnly = (($resolverLines | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        Assert-NotMatch $codeOnly 'importlib\.metadata' 'Installed metadata verification must not start Python and process site-packages startup files.'
        Assert-Match $codeOnly 'Get-InstalledPythonDistributionMetadata' 'Installed SkillSpector version and console entry point must be verified from static dist-info files.'
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
            @{ Name = 'GOTOOLCHAIN'; Value = 'auto' },
            @{ Name = 'GOWORK'; Value = (Join-Path $TestDrive 'untrusted-go.work') },
            @{ Name = 'CGO_ENABLED'; Value = '1' },
            @{ Name = 'GOROOT'; Value = (Join-Path $TestDrive 'untrusted-go-root') },
            @{ Name = 'GOOS'; Value = 'plan9' },
            @{ Name = 'GOARCH'; Value = 'wasm' },
            @{ Name = 'GOCACHEPROG'; Value = '/tmp/untrusted-cache-helper' },
            @{ Name = 'GOMODCACHE'; Value = (Join-Path $TestDrive 'untrusted-go-module-cache') },
            @{ Name = 'GOCACHE'; Value = (Join-Path $TestDrive 'untrusted-go-build-cache') },
            @{ Name = 'GOTMPDIR'; Value = (Join-Path $TestDrive 'untrusted-go-tmp') },
            @{ Name = 'GOBIN'; Value = (Join-Path $TestDrive 'untrusted-go-bin') }
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
            'GOTOOLCHAIN' = 'local'
            'GOWORK' = 'off'
            'CGO_ENABLED' = '0'
        }

        $previous = [ordered]@{}
        try {
            foreach ($entry in $expectedEnvironment.GetEnumerator()) {
                $previous[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($name in @($deniedGoEnvironmentNames + @('GOMODCACHE', 'GOCACHE', 'GOTMPDIR', 'GOBIN'))) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }

            $distributionPolicy = [ordered]@{
                moduleCacheIsolation = 'temporary-empty'
                buildCacheIsolation = 'temporary-empty'
                temporaryDirectoryIsolation = 'temporary-empty'
                binaryInstallIsolation = 'run-owned'
                rejectInheritedModuleCache = $true
                rejectInheritedBuildCache = $true
                rejectDangerousEnvironment = $true
                recordBinaryHash = $true
            }
            $result = Invoke-WithApprovedGoEnvironment -ExpectedEnvironment $expectedEnvironment -DistributionPolicy $distributionPolicy -EnvironmentProbe {
                param($names)
                $snapshot = [ordered]@{}
                foreach ($name in $names) {
                    $snapshot[[string]$name] = if ([string]$name -ceq 'GOENV') {
                        ''
                    }
                    else {
                        [Environment]::GetEnvironmentVariable([string]$name, [EnvironmentVariableTarget]::Process)
                    }
                }
                return [pscustomobject]$snapshot
            } -Action {
                $moduleCache = [Environment]::GetEnvironmentVariable('GOMODCACHE', [EnvironmentVariableTarget]::Process)
                $buildCache = [Environment]::GetEnvironmentVariable('GOCACHE', [EnvironmentVariableTarget]::Process)
                $temporaryDirectory = [Environment]::GetEnvironmentVariable('GOTMPDIR', [EnvironmentVariableTarget]::Process)
                $binaryDirectory = [Environment]::GetEnvironmentVariable('GOBIN', [EnvironmentVariableTarget]::Process)
                [ordered]@{
                    action = 'approved-action-ran'
                    moduleCache = $moduleCache
                    moduleCacheExists = Test-Path -LiteralPath $moduleCache -PathType Container
                    moduleCacheEntryCount = @(Get-ChildItem -LiteralPath $moduleCache -Force).Count
                    buildCache = $buildCache
                    buildCacheExists = Test-Path -LiteralPath $buildCache -PathType Container
                    buildCacheEntryCount = @(Get-ChildItem -LiteralPath $buildCache -Force).Count
                    temporaryDirectory = $temporaryDirectory
                    binaryDirectory = $binaryDirectory
                }
            }
            Assert-Equal $result.action 'approved-action-ran' 'Approved Go environment must reach the action.'
            Assert-True ([bool]$result.moduleCacheExists) 'Approved Go resolution must provide an isolated module cache.'
            Assert-Equal $result.moduleCacheEntryCount 0 'The isolated Go module cache must be empty before resolution.'
            Assert-False (Test-Path -LiteralPath $result.moduleCache) 'The isolated Go module cache must be removed after resolution.'
            Assert-True ([bool]$result.buildCacheExists) 'Approved Go installation must provide an isolated build cache.'
            Assert-Equal $result.buildCacheEntryCount 0 'The isolated Go build cache must be empty before installation.'
            Assert-False (Test-Path -LiteralPath $result.buildCache) 'The isolated Go build cache must be removed after resolution.'
            Assert-False (Test-Path -LiteralPath $result.temporaryDirectory) 'The isolated Go temporary directory must be removed after resolution.'
            Assert-False (Test-Path -LiteralPath $result.binaryDirectory) 'The ephemeral Go binary directory must be removed after resolution.'

            $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
            Assert-Match $resolver '\$identity = "go:.*#moduleCache=\$\(' 'Resolved skill-validator identity must record module-cache isolation.'
            Assert-Match $resolver '#buildCache=\$\(' 'Resolved skill-validator identity must record build-cache isolation.'
            Assert-Match $resolver '#goflags=empty' 'Resolved skill-validator identity must record clean build flags.'
            Assert-Match $resolver '#goRuntime=\$goRuntimeVersion' 'Resolved skill-validator identity must bind the exact Go runtime version.'
            Assert-Match $resolver ([regex]::Escape("Invoke-CheckedCommand -Command `$goCommand -Arguments @('version')")) 'The resolver must verify the native Go runtime before module resolution.'
            Assert-Match $resolver ([regex]::Escape("Invoke-CheckedCommand -Command `$goCommand -Arguments @('clean', '-cache', '-modcache')")) 'Run-owned Go caches must be cleaned through Go before their temporary root is removed.'
            Assert-Match $resolver '\$result\.goRuntimeVersion = \[string\]\$resolved\.goRuntimeVersion' 'The receipt must project the verified Go runtime version.'
            $versionProbeIndex = $resolver.IndexOf("Invoke-CheckedCommand -Command `$goCommand -Arguments @('version')")
            $moduleLookupIndex = $resolver.IndexOf("Invoke-CheckedCommand -Command `$goCommand -Arguments @('list', '-m', '-json'")
            Assert-True ($versionProbeIndex -ge 0 -and $moduleLookupIndex -gt $versionProbeIndex) 'Go runtime verification must fail closed before module resolution can start.'

            Assert-Equal (Get-ApprovedGoRuntimeVersion -VersionOutput @('go version go1.26.8 linux/amd64') -ExpectedVersion '1.26.8') '1.26.8' 'The exact approved Go runtime evidence must be accepted.'
            foreach ($case in @(
                @{ Output=@(); Pattern='ambiguous runtime-version evidence' },
                @{ Output=@('go version go1.26.8 linux/amd64', 'unexpected second line'); Pattern='ambiguous runtime-version evidence' },
                @{ Output=@('go version devel go1.26.8 linux/amd64'); Pattern='Unapproved Go runtime' },
                @{ Output=@('go version go1.26.7 linux/amd64'); Pattern='Unapproved Go runtime' }
            )) {
                $runtimeError = $null
                try { Get-ApprovedGoRuntimeVersion -VersionOutput @($case.Output) -ExpectedVersion '1.26.8' | Out-Null }
                catch { $runtimeError = $_.Exception.Message }
                Assert-Match $runtimeError ([string]$case.Pattern) 'Untrusted Go runtime evidence must fail closed.'
            }

            $singleFileClosureRoot = Join-Path $TestDrive 'single-file-go-closure'
            [void](New-Item -ItemType Directory -Path $singleFileClosureRoot -Force)
            [IO.File]::WriteAllText(
                (Join-Path $singleFileClosureRoot 'skill-validator'),
                'fixture binary',
                (New-Object Text.UTF8Encoding($false))
            )
            $singleFileClosure = Get-DirectoryClosureIdentity -Path $singleFileClosureRoot
            $closureJson = [ordered]@{
                installed = (Get-DependencyClosureEntriesArray -Closure $singleFileClosure)
                unresolved = (Get-DependencyClosureEntriesArray -Closure $null)
            } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            Assert-True ($closureJson.installed -is [array]) 'A one-file installed closure must remain a JSON array instead of scalarizing to an object.'
            Assert-Equal @($closureJson.installed).Count 1 'A one-file installed closure must contain exactly one entry.'
            Assert-True ($closureJson.unresolved -is [array]) 'An unresolved closure must remain an empty JSON array.'
            Assert-Equal @($closureJson.unresolved).Count 0 'An unresolved closure must not contain an entry.'
            Assert-Equal ([regex]::Matches($resolver, 'dependencyClosure = \(Get-DependencyClosureEntriesArray -Closure \$').Count) 4 'Every resolver receipt must use the scalarization-safe closure-array helper.'
            Assert-Match $resolver '\$result\.moduleCacheIsolation = \[string\]\$resolved\.moduleCacheIsolation' 'The receipt must project module-cache isolation from the resolved installation.'
            Assert-Match $resolver '\$result\.buildCacheIsolation = \[string\]\$resolved\.buildCacheIsolation' 'The receipt must project build-cache isolation from the resolved installation.'
            Assert-Match $resolver 'binarySha256=\$executableSha256' 'The immutable skill-validator identity must include the installed binary hash.'
            Assert-Match $resolver 'executablePath = \$resolved\.executablePath' 'The receipt must expose the exact installed skill-validator executable.'
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

    # Scenario: The two Standard schemas are edited without updating their strict semantic baselines.
    # Purpose: Protect the exact draft, fields, required sets, bounds, and extension policy consumed by source repositories.
    It 'UnitT35_keeps_the_source_inventory_and_OpenAI_metadata_schema_shapes_exact' {
        Assert-True (Test-Path -LiteralPath $script:SourceInventorySchemaPath -PathType Leaf) 'Missing source inventory v2 schema.'
        Assert-True (Test-Path -LiteralPath $script:OpenAiMetadataSchemaPath -PathType Leaf) 'Missing OpenAI agent metadata schema.'
        $sourceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:SourceInventorySchemaPath | ConvertFrom-Json
        $openAiSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:OpenAiMetadataSchemaPath | ConvertFrom-Json

        Assert-ExactPropertySet $sourceSchema @('$schema','title','description','type','additionalProperties','required','properties','$defs') 'Source inventory schema root must remain exact.'
        Assert-True ([string]$sourceSchema.'$schema' -ceq 'https://json-schema.org/draft/2020-12/schema') 'Source inventory must use the reviewed JSON Schema draft.'
        Assert-True ([string]$sourceSchema.type -ceq 'object') 'Source inventory root must be an object.'
        Assert-True ($sourceSchema.additionalProperties -is [bool] -and -not [bool]$sourceSchema.additionalProperties) 'Source inventory root must reject unknown fields.'
        Assert-ExactStringSequence $sourceSchema.required @('schemaVersion','sourceId','repository','skillsRoot','skills') 'Source inventory required fields must remain exact and ordered.'
        Assert-ExactPropertySet $sourceSchema.properties @('schemaVersion','sourceId','repository','skillsRoot','skills') 'Source inventory properties must remain exact.'
        Assert-Equal $sourceSchema.properties.schemaVersion.const 2 'Source inventory must require schemaVersion 2.'
        Assert-True ([string]$sourceSchema.properties.sourceId.'$ref' -ceq '#/$defs/stableId') 'sourceId must use the stable-ID definition.'
        Assert-True ([string]$sourceSchema.properties.repository.type -ceq 'string') 'repository must remain a string.'
        Assert-True ([string]$sourceSchema.properties.repository.pattern -ceq '^https://github\.com/[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]+\.git$') 'repository must retain the canonical GitHub HTTPS clone grammar.'
        Assert-True ([string]$sourceSchema.properties.skillsRoot.const -ceq 'skills') 'skillsRoot must remain the exact canonical directory.'
        Assert-ExactPropertySet $sourceSchema.properties.skills @('type','minItems','uniqueItems','items') 'skills array constraints must remain exact.'
        Assert-True ([string]$sourceSchema.properties.skills.type -ceq 'array') 'skills must remain an array.'
        Assert-Equal $sourceSchema.properties.skills.minItems 1 'Source inventory must contain at least one Skill.'
        Assert-True ($sourceSchema.properties.skills.uniqueItems -is [bool] -and [bool]$sourceSchema.properties.skills.uniqueItems) 'Source inventory must reject duplicate Skills.'
        Assert-True ([string]$sourceSchema.properties.skills.items.'$ref' -ceq '#/$defs/stableId') 'Every Skill inventory item must use the stable-ID definition.'
        Assert-ExactPropertySet $sourceSchema.'$defs' @('stableId') 'Source inventory definitions must remain exact.'
        Assert-ExactPropertySet $sourceSchema.'$defs'.stableId @('type','minLength','maxLength','pattern') 'Stable-ID constraints must remain exact.'
        Assert-True ([string]$sourceSchema.'$defs'.stableId.type -ceq 'string') 'Stable IDs must remain strings.'
        Assert-Equal $sourceSchema.'$defs'.stableId.minLength 1 'Stable IDs must not be empty.'
        Assert-Equal $sourceSchema.'$defs'.stableId.maxLength 64 'Stable IDs must retain the 64-character bound.'
        Assert-True ([string]$sourceSchema.'$defs'.stableId.pattern -ceq '^[a-z0-9]+(?:-[a-z0-9]+)*$') 'Stable IDs must retain their lexical grammar.'

        Assert-ExactPropertySet $openAiSchema @('$schema','title','description','type','required','properties','additionalProperties') 'OpenAI metadata schema root must remain exact.'
        Assert-True ([string]$openAiSchema.'$schema' -ceq 'https://json-schema.org/draft/2020-12/schema') 'OpenAI metadata must use the reviewed JSON Schema draft.'
        Assert-True ([string]$openAiSchema.type -ceq 'object') 'OpenAI metadata root must be an object.'
        Assert-ExactStringSequence $openAiSchema.required @('interface') 'OpenAI metadata must require interface.'
        Assert-ExactPropertySet $openAiSchema.properties @('interface','dependencies') 'OpenAI metadata root properties must remain exact.'
        Assert-True ($openAiSchema.additionalProperties -is [bool] -and [bool]$openAiSchema.additionalProperties) 'Host-specific OpenAI root metadata must remain extensible.'

        $interfaceSchema = $openAiSchema.properties.interface
        Assert-ExactPropertySet $interfaceSchema @('type','required','properties','additionalProperties') 'OpenAI interface schema must remain exact.'
        Assert-ExactStringSequence $interfaceSchema.required @('display_name','short_description','default_prompt') 'OpenAI interface required fields must remain exact.'
        Assert-ExactPropertySet $interfaceSchema.properties @('display_name','short_description','icon_small','icon_large','brand_color','default_prompt') 'OpenAI interface properties must remain exact.'
        Assert-True ($interfaceSchema.additionalProperties -is [bool] -and [bool]$interfaceSchema.additionalProperties) 'Optional host interface metadata must remain extensible.'
        Assert-Equal $interfaceSchema.properties.short_description.minLength 25 'short_description must retain its lower bound.'
        Assert-Equal $interfaceSchema.properties.short_description.maxLength 64 'short_description must retain its upper bound.'
        Assert-True ([string]$interfaceSchema.properties.icon_small.pattern -ceq '^\./assets/[^\r\n]+$') 'Small icons must remain package-relative assets.'
        Assert-True ([string]$interfaceSchema.properties.icon_large.pattern -ceq '^\./assets/[^\r\n]+$') 'Large icons must remain package-relative assets.'
        Assert-True ([string]$interfaceSchema.properties.brand_color.pattern -ceq '^#[0-9A-Fa-f]{6}$') 'Brand colors must remain six-digit hex values.'
        Assert-True ([string]$interfaceSchema.properties.default_prompt.pattern -ceq '[\s\S]*\$[a-z0-9]+(?:-[a-z0-9]+)*[\s\S]*') 'default_prompt must contain a lexical Skill token.'

        $dependenciesSchema = $openAiSchema.properties.dependencies
        Assert-ExactPropertySet $dependenciesSchema @('type','properties','additionalProperties') 'OpenAI dependency schema must remain exact.'
        Assert-ExactPropertySet $dependenciesSchema.properties @('tools') 'Only tools have a Standard semantic dependency baseline.'
        Assert-True ($dependenciesSchema.additionalProperties -is [bool] -and [bool]$dependenciesSchema.additionalProperties) 'Optional dependency metadata must remain extensible.'
        $toolsSchema = $dependenciesSchema.properties.tools
        Assert-ExactPropertySet $toolsSchema @('type','minItems','items') 'OpenAI tools array constraints must remain exact.'
        Assert-Equal $toolsSchema.minItems 1 'An explicit tools array must not be empty.'
        Assert-ExactPropertySet $toolsSchema.items @('type','additionalProperties','required','properties') 'OpenAI dependency item schema must remain exact.'
        Assert-True ($toolsSchema.items.additionalProperties -is [bool] -and -not [bool]$toolsSchema.items.additionalProperties) 'Unknown dependency tool fields must fail closed.'
        Assert-ExactStringSequence $toolsSchema.items.required @('type','value') 'OpenAI dependency tools must require type and value.'
        Assert-ExactPropertySet $toolsSchema.items.properties @('type','value','description','transport','url') 'OpenAI dependency tool properties must remain exact.'
        Assert-True ([string]$toolsSchema.items.properties.type.const -ceq 'mcp') 'Standard v1 dependency tools must remain MCP dependencies.'
        Assert-True ([string]$toolsSchema.items.properties.url.format -ceq 'uri') 'Dependency URLs must remain URI-formatted.'
        Assert-True ([string]$toolsSchema.items.properties.url.pattern -ceq '^https://[^\s/?#]+(?:[/?#][^\s]*)?$') 'Dependency URLs must remain absolute HTTPS URIs.'
    }

    # Scenario: Source inventory documents use legacy shape, unknown fields, unsafe lexical identities, or drift from package directories.
    # Purpose: Exercise schema v2 plus the executable sort and authority-binding rules that JSON Schema cannot express.
    It 'UnitT36_rejects_invalid_unsorted_or_identity_mismatched_source_inventories' {
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:SourceInventorySchemaPath | ConvertFrom-Json
        $valid = [pscustomobject][ordered]@{
            schemaVersion=2
            sourceId='example-source'
            repository='https://github.com/example/example-source.git'
            skillsRoot='skills'
            skills=[object[]]@('alpha-skill','zeta-skill')
        }
        Assert-AuthoritySchemaInstance -Value $valid -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'Canonical source inventory must be schema-valid.'
        Assert-True (Test-SourceInventoryExecutableContract -Inventory $valid -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('zeta-skill','alpha-skill')) 'Canonical inventory must bind the expected source, repository, sort order, and package directories.'

        $invalidCases = @(
            @{ Name='legacy-version'; Mutate={ param($item) $item.schemaVersion=1 } },
            @{ Name='string-version'; Mutate={ param($item) $item.schemaVersion='2' } },
            @{ Name='unknown-root-field'; Mutate={ param($item) $item | Add-Member -NotePropertyName profiles -NotePropertyValue @('default') } },
            @{ Name='uppercase-source-id'; Mutate={ param($item) $item.sourceId='Example-Source' } },
            @{ Name='leading-hyphen-source-id'; Mutate={ param($item) $item.sourceId='-example-source' } },
            @{ Name='double-hyphen-source-id'; Mutate={ param($item) $item.sourceId='example--source' } },
            @{ Name='overlong-source-id'; Mutate={ param($item) $item.sourceId=('a' * 65) } },
            @{ Name='credentialed-repository'; Mutate={ param($item) $item.repository='https://token@github.com/example/example-source.git' } },
            @{ Name='repository-query'; Mutate={ param($item) $item.repository='https://github.com/example/example-source.git?ref=main' } },
            @{ Name='missing-dot-git'; Mutate={ param($item) $item.repository='https://github.com/example/example-source' } },
            @{ Name='wrong-skills-root'; Mutate={ param($item) $item.skillsRoot='src/skills' } },
            @{ Name='empty-skills'; Mutate={ param($item) $item.skills=[object[]]@() } },
            @{ Name='duplicate-skills'; Mutate={ param($item) $item.skills=[object[]]@('alpha-skill','alpha-skill') } },
            @{ Name='legacy-object-skills'; Mutate={ param($item) $item.skills=[object[]]@([pscustomobject]@{ id='alpha-skill'; path='skills/alpha-skill' }) } }
        )
        foreach ($case in $invalidCases) {
            $inventory = Copy-TestJsonObject -Value $valid
            & $case.Mutate $inventory
            Assert-AuthoritySchemaInstance -Value $inventory -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $false -Message "Invalid source inventory '$($case.Name)' must fail schema validation."
        }

        $unsorted = Copy-TestJsonObject -Value $valid
        $unsorted.skills = [object[]]@('zeta-skill','alpha-skill')
        Assert-AuthoritySchemaInstance -Value $unsorted -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'Sort order is intentionally an executable cross-document rule.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $unsorted -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill','zeta-skill')) 'Non-ordinal inventory order must fail the executable contract.'

        $wrongSource = Copy-TestJsonObject -Value $valid
        $wrongSource.sourceId = 'other-source'
        Assert-AuthoritySchemaInstance -Value $wrongSource -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'A different lexical source ID is valid only before authority binding.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $wrongSource -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill','zeta-skill')) 'A different valid source ID must fail exact authority binding.'

        $wrongRepository = Copy-TestJsonObject -Value $valid
        $wrongRepository.repository = 'https://github.com/example/other-source.git'
        Assert-AuthoritySchemaInstance -Value $wrongRepository -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'A different canonical repository is valid only before authority binding.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $wrongRepository -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill','zeta-skill')) 'A different valid repository must fail exact authority binding.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $valid -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill')) 'Declared inventory and actual package directories must be equal.'
    }

    # Scenario: Parsed OpenAI metadata contains wrong types, bounds, dependency fields, or only a different valid Skill token.
    # Purpose: Distinguish semantic schema validation from the fixture validator's exact YAML lexical and identity checks.
    It 'UnitT37_validates_OpenAI_metadata_semantics_without_overclaiming_lexical_identity' {
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:OpenAiMetadataSchemaPath | ConvertFrom-Json
        $valid = [pscustomobject][ordered]@{
            interface=[pscustomobject][ordered]@{
                display_name='Standard Validation Fixture'
                short_description='Validate one deterministic canonical Skill package.'
                icon_small='./assets/icon-small.svg'
                icon_large='./assets/icon-large.png'
                brand_color='#0A84FF'
                default_prompt='Use $standard-validation-fixture to validate this package.'
            }
            dependencies=[pscustomobject][ordered]@{
                tools=[object[]]@(
                    [pscustomobject][ordered]@{ type='mcp'; value='github'; description='GitHub connector'; transport='streamable-http'; url='https://example.invalid/mcp' }
                )
            }
        }
        Assert-AuthoritySchemaInstance -Value $valid -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $true -Message 'Canonical parsed OpenAI metadata must be schema-valid.'

        $rootExtension = Copy-TestJsonObject -Value $valid
        $rootExtension | Add-Member -NotePropertyName host_extension -NotePropertyValue 'allowed'
        $rootExtension.interface | Add-Member -NotePropertyName host_hint -NotePropertyValue 'allowed'
        Assert-AuthoritySchemaInstance -Value $rootExtension -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $true -Message 'Reviewed host extension points must remain schema-valid.'

        $invalidCases = @(
            @{ Name='missing-interface'; Mutate={ param($item) $item.PSObject.Properties.Remove('interface') } },
            @{ Name='numeric-display-name'; Mutate={ param($item) $item.interface.display_name=7 } },
            @{ Name='short-description-underflow'; Mutate={ param($item) $item.interface.short_description=('a' * 24) } },
            @{ Name='short-description-overflow'; Mutate={ param($item) $item.interface.short_description=('a' * 65) } },
            @{ Name='prompt-without-skill-token'; Mutate={ param($item) $item.interface.default_prompt='Validate this package.' } },
            @{ Name='unsafe-small-icon'; Mutate={ param($item) $item.interface.icon_small='../icon.svg' } },
            @{ Name='invalid-brand-color'; Mutate={ param($item) $item.interface.brand_color='#12345G' } },
            @{ Name='wrong-tool-type'; Mutate={ param($item) $item.dependencies.tools[0].type='http' } },
            @{ Name='empty-tool-value'; Mutate={ param($item) $item.dependencies.tools[0].value='' } },
            @{ Name='non-HTTPS-tool-url'; Mutate={ param($item) $item.dependencies.tools[0].url='http://example.invalid/mcp' } },
            @{ Name='unknown-tool-field'; Mutate={ param($item) $item.dependencies.tools[0] | Add-Member -NotePropertyName command -NotePropertyValue 'forbidden' } }
        )
        foreach ($case in $invalidCases) {
            $metadata = Copy-TestJsonObject -Value $valid
            & $case.Mutate $metadata
            Assert-AuthoritySchemaInstance -Value $metadata -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $false -Message "Invalid OpenAI metadata '$($case.Name)' must fail semantic schema validation."
        }

        $differentToken = Copy-TestJsonObject -Value $valid
        $differentToken.interface.default_prompt = 'Use $other-fixture to validate this package.'
        Assert-AuthoritySchemaInstance -Value $differentToken -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $true -Message 'JSON Schema validates token grammar, not exact package identity.'
        $schemaDescription = [string]$schema.description
        Assert-Match $schemaDescription 'exact \$<skill-id> binding.*YAML-aware checks' 'Schema documentation must assign exact lexical identity binding to the YAML-aware validator.'
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
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

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
        Assert-Match $matrix 'every candidate before pip can inspect it' 'Review matrix must record candidate direct-reference rejection before offline pip can inspect it.'
        Assert-NotMatch $matrix 'post-materialization' 'Review matrix must not retain the obsolete online-pip post-materialization model.'
        Assert-NotMatch $standard 'post-materialization' 'Normative Standard must not retain the obsolete online-pip post-materialization model.'
        Assert-Match $standard 'MUST NOT.*installed interpreter.*\.pth' 'Normative Standard must require static installed-metadata verification before Python startup processing.'
        Assert-Match $matrix 'persist-credentials' 'Review matrix must record CI checkout credential isolation.'
        Assert-Match $matrix 'wheelhouse' 'Review matrix must record hash-locked SkillSpector dependency acquisition.'
        Assert-NotMatch $matrix 'SYP-167 establishes normative Standard v1 only\.' 'Review matrix must not describe the pre-regression SYP-167 scope.'
    }
}
