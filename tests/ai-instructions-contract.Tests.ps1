Describe 'AI instructions machine-readable contract' {
    BeforeAll {
        $script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:ContractPath = Join-Path $script:RepositoryRoot 'ai-instructions-contract.json'
        $script:BootstrapPath = Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions.ps1'

function Get-AiInstructionText {
    param([Parameter(Mandatory = $true)][string] $Path)

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $text = $utf8.GetString([System.IO.File]::ReadAllBytes($Path))
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }

    return $text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-AiInstructionContract {
    return (Get-AiInstructionText -Path $script:ContractPath) | ConvertFrom-Json
}

function Get-PlatformBaseRelativePath {
    param(
        [Parameter(Mandatory = $true)] $Platform,
        [Parameter(Mandatory = $true)][string] $LocaleId
    )

    $property = $Platform.base.PSObject.Properties[$LocaleId]
    if ($null -eq $property) {
        throw "Platform '$($Platform.id)' has no Base path for locale '$LocaleId'."
    }
    return [string]$property.Value
}

function Get-ContractFullPath {
    param([Parameter(Mandatory = $true)][string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.StartsWith('/') -or
        $RelativePath.StartsWith('\') -or
        $RelativePath -match '^[A-Za-z]:' -or
        $RelativePath.Contains('\')) {
        throw "Unsafe AI instruction contract path '$RelativePath'."
    }

    $segments = @($RelativePath.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "Unsafe AI instruction contract path '$RelativePath'."
    }

    $nativePath = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        $RelativePath.Replace('/', '\')
    }
    else {
        $RelativePath
    }
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot $nativePath))
    $rootPrefix = $script:RepositoryRoot.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "AI instruction contract path escapes the repository: '$RelativePath'."
    }

    return $fullPath
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-OrdinalStringSet -Actual @($Value.PSObject.Properties.Name) -Expected $Expected -Context "$Context properties"
}

function Assert-AiJsonString {
    param($Value, [Parameter(Mandatory = $true)][string] $Context)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context must be a non-empty JSON string."
    }
}

function Assert-AiJsonArray {
    param($Value, [Parameter(Mandatory = $true)][string] $Context)
    if ($Value -isnot [array]) {
        throw "$Context must be a JSON array."
    }
}

function Assert-OrdinalStringSet {
    param(
        [AllowEmptyCollection()][object[]] $Actual,
        [AllowEmptyCollection()][object[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actualStrings = @($Actual | ForEach-Object { [string] $_ } | Sort-Object -CaseSensitive)
    $expectedStrings = @($Expected | ForEach-Object { [string] $_ } | Sort-Object -CaseSensitive)
    $actualText = $actualStrings -join "`n"
    $expectedText = $expectedStrings -join "`n"
    if (-not [string]::Equals($actualText, $expectedText, [System.StringComparison]::Ordinal)) {
        throw "$Context mismatch. Expected [$($expectedStrings -join ', ')], actual [$($actualStrings -join ', ')]."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $threw = $false
    try {
        $null = & $Action
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "$Context was expected to fail."
    }
}

function Get-AiInvariantIds {
    param([Parameter(Mandatory = $true)][string] $Text)

    $matches = [regex]::Matches($Text, '<!-- ai-invariant:(?<id>[a-z0-9][a-z0-9.-]*) -->')
    $prefixCount = [regex]::Matches($Text, '<!--\s*ai-invariant:').Count
    if ($prefixCount -ne $matches.Count) {
        throw 'An AI invariant marker is malformed.'
    }

    foreach ($match in $matches) {
        $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0, $match.Index - 1))
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
        $prefix = $Text.Substring($lineStart, $match.Index - $lineStart).Trim()
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            throw "AI invariant '$($match.Groups['id'].Value)' is not attached to substantive instruction text."
        }
    }

    return @($matches | ForEach-Object { $_.Groups['id'].Value })
}

function Get-AiRoutes {
    param([Parameter(Mandatory = $true)][string] $Text)

    $matches = [regex]::Matches($Text, '(?m)^(?<line>[^\n]*<!-- ai-route:(?<payload>\{[^\n]*\}) -->[ \t]*)$')
    $prefixCount = [regex]::Matches($Text, '<!--\s*ai-route:').Count
    if ($prefixCount -ne $matches.Count) {
        throw 'An AI route marker is malformed or is not contained on one instruction line.'
    }

    $routes = @()
    foreach ($match in $matches) {
        $line = $match.Groups['line'].Value
        $json = $match.Groups['payload'].Value
        if (-not $line.TrimStart().StartsWith('-')) {
            throw 'An AI route is not attached to a list instruction.'
        }
        if ([regex]::Matches($json, '"module"\s*:').Count -ne 1 -or
            [regex]::Matches($json, '"triggers"\s*:').Count -ne 1) {
            throw 'An AI route payload must declare module and triggers exactly once.'
        }
        try {
            $payload = $json | ConvertFrom-Json
        }
        catch {
            throw "AI route payload is not valid JSON: $($_.Exception.Message)"
        }
        Assert-ExactPropertySet -Value $payload -Expected @('module','triggers') -Context 'AI route payload'
        if ($payload.module -isnot [string] -or [string]$payload.module -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw 'An AI route payload has an invalid module identity.'
        }
        if ($null -eq $payload.triggers -or $payload.triggers -is [string] -or @($payload.triggers).Count -eq 0) {
            throw "AI route '$($payload.module)' must declare a non-empty trigger array."
        }
        $triggerIds = @($payload.triggers)
        foreach ($triggerId in $triggerIds) {
            if ($triggerId -isnot [string] -or [string]$triggerId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                throw "AI route '$($payload.module)' contains an invalid trigger identity."
            }
        }
        Assert-OrdinalStringSet -Actual $triggerIds -Expected @($triggerIds | Select-Object -Unique) -Context "AI route '$($payload.module)' trigger identities"
        $targets = [regex]::Matches($line, '`(?<path>\.(?:codex|github)/AI-Rules/[^`]+\.md)`')
        if ($targets.Count -ne 1) {
            throw "AI route '$($payload.module)' must contain exactly one AI-Rules target."
        }
        $routes += [pscustomobject]@{
            id = [string]$payload.module
            target = $targets[0].Groups['path'].Value
            triggers = @($triggerIds)
        }
    }

    return $routes
}

function Assert-AiRuleReferences {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)] $Platform,
        [Parameter(Mandatory = $true)] $Locale
    )

    $references = [regex]::Matches($Text, '`(?<path>\.(?:codex|github)/AI-Rules/[^`]+\.md)`')
    foreach ($reference in $references) {
        $path = $reference.Groups['path'].Value
        if (-not $path.StartsWith(([string]$Platform.rulesRoot + '/'), [System.StringComparison]::Ordinal)) {
            throw "Instruction for platform '$($Platform.id)' references the wrong rule root: '$path'."
        }
        if ([string]$Locale.id -eq 'en') {
            if (-not $path.EndsWith('.en.md', [System.StringComparison]::Ordinal)) {
                throw "English instruction references a non-English rule: '$path'."
            }
        }
        elseif ($path.EndsWith('.en.md', [System.StringComparison]::Ordinal)) {
            throw "Primary-locale instruction references an English rule: '$path'."
        }
        if (-not (Test-Path -LiteralPath (Get-ContractFullPath -RelativePath $path) -PathType Leaf)) {
            throw "Instruction references a missing rule: '$path'."
        }
    }
}

    }

    # Scenario: The maintenance contract is parsed under every supported PowerShell lane.
    # Purpose: Reject silent contract expansion, unsafe paths, duplicate identities, and vacuous all-missing parity.
    It 'InterT10_validates_the_closed_v1_contract_shape' {
        $contract = Get-AiInstructionContract
        Assert-ExactPropertySet -Value $contract -Expected @('schemaVersion','primaryLocale','fanOutLocale','locales','platforms','modules','baseInvariants') -Context 'contract'
        if (($contract.schemaVersion -isnot [int] -and $contract.schemaVersion -isnot [long]) -or [int64]$contract.schemaVersion -ne 1) {
            throw "Unexpected schemaVersion '$($contract.schemaVersion)'."
        }
        Assert-AiJsonString -Value $contract.primaryLocale -Context 'primaryLocale'
        Assert-AiJsonString -Value $contract.fanOutLocale -Context 'fanOutLocale'
        if ([string]$contract.primaryLocale -cne 'zh-TW') { throw "Unexpected primaryLocale '$($contract.primaryLocale)'." }
        if ([string]$contract.fanOutLocale -cne 'en') { throw "Unexpected fanOutLocale '$($contract.fanOutLocale)'." }
        Assert-AiJsonArray -Value $contract.locales -Context 'locales'
        Assert-AiJsonArray -Value $contract.platforms -Context 'platforms'
        Assert-AiJsonArray -Value $contract.modules -Context 'modules'
        Assert-AiJsonArray -Value $contract.baseInvariants -Context 'baseInvariants'

        Assert-OrdinalStringSet -Actual @($contract.locales | ForEach-Object { $_.id }) -Expected @('zh-TW','en') -Context 'locale inventory'
        foreach ($locale in @($contract.locales)) {
            Assert-ExactPropertySet -Value $locale -Expected @('id','ruleSuffix') -Context "locale '$($locale.id)'"
            Assert-AiJsonString -Value $locale.id -Context 'locale id'
            Assert-AiJsonString -Value $locale.ruleSuffix -Context "locale '$($locale.id)' ruleSuffix"
            if (-not ([string]$locale.ruleSuffix).EndsWith('.md', [System.StringComparison]::Ordinal)) {
                throw "Locale '$($locale.id)' has an invalid rule suffix."
            }
        }

        Assert-OrdinalStringSet -Actual @($contract.platforms | ForEach-Object { $_.id }) -Expected @('codex','github-copilot') -Context 'platform inventory'
        $bootstrap = Get-AiInstructionText -Path $script:BootstrapPath
        foreach ($platform in @($contract.platforms)) {
            Assert-ExactPropertySet -Value $platform -Expected @('id','base','rulesRoot','fanOut') -Context "platform '$($platform.id)'"
            Assert-ExactPropertySet -Value $platform.base -Expected @('zh-TW','en') -Context "platform '$($platform.id)' base"
            Assert-ExactPropertySet -Value $platform.fanOut -Expected @('baseTarget','rulesTarget','preserveRuleFileName') -Context "platform '$($platform.id)' fanOut"
            Assert-AiJsonString -Value $platform.id -Context 'platform id'
            foreach ($pathValue in @($platform.base.'zh-TW',$platform.base.en,$platform.rulesRoot,$platform.fanOut.baseTarget,$platform.fanOut.rulesTarget)) {
                Assert-AiJsonString -Value $pathValue -Context "platform '$($platform.id)' path"
                $path = [string]$pathValue
                [void](Get-ContractFullPath -RelativePath $path)
            }
            if ($platform.fanOut.preserveRuleFileName -isnot [bool] -or -not [bool]$platform.fanOut.preserveRuleFileName) {
                throw "Platform '$($platform.id)' must preserve rule filenames during fan-out."
            }

            $familyName = if ([string]$platform.id -ceq 'codex') { 'Codex' } else { 'GitHub Copilot' }
            $familyPattern = "(?s)Name\s*=\s*'{0}'.*?SourceBase\s*=\s*'{1}'.*?TargetBase\s*=\s*'{2}'.*?SourceRules\s*=\s*'{3}'.*?TargetRules\s*=\s*'{4}'" -f @(
                [regex]::Escape($familyName),
                [regex]::Escape([string]$platform.base.en),
                [regex]::Escape([string]$platform.fanOut.baseTarget),
                [regex]::Escape([string]$platform.rulesRoot),
                [regex]::Escape([string]$platform.fanOut.rulesTarget)
            )
            if ($bootstrap -cnotmatch $familyPattern) {
                throw "Platform '$($platform.id)' fan-out mapping does not match scripts/bootstrap-ai-instructions.ps1."
            }
        }

        Assert-OrdinalStringSet -Actual @($contract.modules | ForEach-Object { $_.id }) -Expected @('code-review','database','external-research','git-commit','testing') -Context 'v1 module inventory'
        $allInvariantIds = New-Object System.Collections.Generic.List[string]
        foreach ($module in @($contract.modules)) {
            Assert-ExactPropertySet -Value $module -Expected @('id','fileStem','platforms','triggers','invariants') -Context "module '$($module.id)'"
            Assert-AiJsonString -Value $module.id -Context 'module id'
            Assert-AiJsonString -Value $module.fileStem -Context "module '$($module.id)' fileStem"
            Assert-AiJsonArray -Value $module.platforms -Context "module '$($module.id)' platforms"
            Assert-AiJsonArray -Value $module.triggers -Context "module '$($module.id)' triggers"
            Assert-AiJsonArray -Value $module.invariants -Context "module '$($module.id)' invariants"
            if ([string]$module.id -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or [string]$module.fileStem -cnotmatch '^[A-Za-z][A-Za-z0-9]*$') {
                throw "Module '$($module.id)' has an invalid identity."
            }
            if (@($module.platforms).Count -eq 0) {
                throw "Module '$($module.id)' must apply to at least one declared platform."
            }
            Assert-OrdinalStringSet -Actual @($module.platforms) -Expected @($module.platforms | Select-Object -Unique) -Context "module '$($module.id)' platforms"
            foreach ($platformId in @($module.platforms)) {
                if ($platformId -isnot [string] -or @($contract.platforms | Where-Object { [string]$_.id -ceq [string]$platformId }).Count -ne 1) {
                    throw "Module '$($module.id)' references unknown platform '$platformId'."
                }
            }
            if (@($module.triggers).Count -eq 0 -or @($module.invariants).Count -eq 0) {
                throw "Module '$($module.id)' must declare triggers and invariants."
            }
            Assert-OrdinalStringSet -Actual @($module.triggers) -Expected @($module.triggers | Select-Object -Unique) -Context "module '$($module.id)' triggers"
            Assert-OrdinalStringSet -Actual @($module.invariants) -Expected @($module.invariants | Select-Object -Unique) -Context "module '$($module.id)' invariants"
            foreach ($trigger in @($module.triggers)) {
                if ($trigger -isnot [string] -or [string]$trigger -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                    throw "Module '$($module.id)' has invalid trigger '$trigger'."
                }
            }
            foreach ($invariant in @($module.invariants)) {
                if ($invariant -isnot [string] -or
                    -not ([string]$invariant).StartsWith(([string]$module.id + '.'), [System.StringComparison]::Ordinal) -or
                    [string]$invariant -cnotmatch '^[a-z0-9]+(?:[.-][a-z0-9]+)*$') {
                    throw "Module '$($module.id)' has invalid invariant '$invariant'."
                }
                $allInvariantIds.Add([string]$invariant)
            }
        }

        foreach ($baseInvariant in @($contract.baseInvariants)) {
            Assert-ExactPropertySet -Value $baseInvariant -Expected @('id','platforms') -Context "base invariant '$($baseInvariant.id)'"
            Assert-AiJsonString -Value $baseInvariant.id -Context 'base invariant id'
            Assert-AiJsonArray -Value $baseInvariant.platforms -Context "base invariant '$($baseInvariant.id)' platforms"
            if (@($baseInvariant.platforms).Count -eq 0 -or [string]$baseInvariant.id -cnotmatch '^[a-z0-9]+(?:[.-][a-z0-9]+)*$') {
                throw "Base invariant '$($baseInvariant.id)' has an invalid identity."
            }
            Assert-OrdinalStringSet -Actual @($baseInvariant.platforms) -Expected @($baseInvariant.platforms | Select-Object -Unique) -Context "base invariant '$($baseInvariant.id)' platforms"
            foreach ($platformId in @($baseInvariant.platforms)) {
                if ($platformId -isnot [string] -or @($contract.platforms | Where-Object { [string]$_.id -ceq [string]$platformId }).Count -ne 1) {
                    throw "Base invariant '$($baseInvariant.id)' references unknown platform '$platformId'."
                }
            }
            $allInvariantIds.Add([string]$baseInvariant.id)
        }
        Assert-OrdinalStringSet -Actual @($allInvariantIds) -Expected @($allInvariantIds | Select-Object -Unique) -Context 'global invariant identities'
    }

    # Scenario: A rule is added, removed, renamed, or translated for either platform.
    # Purpose: Require an exact declared two-locale inventory rather than allowing both sides to omit the same artifact.
    It 'InterT20_has_exact_locale_pairs_for_every_declared_artifact' {
        $contract = Get-AiInstructionContract
        foreach ($platform in @($contract.platforms)) {
            foreach ($locale in @($contract.locales)) {
                $basePath = Get-ContractFullPath -RelativePath (Get-PlatformBaseRelativePath -Platform $platform -LocaleId ([string]$locale.id))
                if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
                    throw "Missing Base instruction '$basePath'."
                }
                if ([string]::IsNullOrWhiteSpace((Get-AiInstructionText -Path $basePath))) {
                    throw "Base instruction is empty: '$basePath'."
                }
            }

            $expectedFiles = @()
            foreach ($module in @($contract.modules | Where-Object { @($_.platforms) -ccontains [string]$platform.id })) {
                foreach ($locale in @($contract.locales)) {
                    $expectedFiles += ([string]$module.fileStem + [string]$locale.ruleSuffix)
                }
            }
            $ruleRoot = Get-ContractFullPath -RelativePath ([string]$platform.rulesRoot)
            $actualFiles = @(Get-ChildItem -LiteralPath $ruleRoot -File | Where-Object { $_.Name.EndsWith('.md', [System.StringComparison]::Ordinal) } | ForEach-Object { $_.Name })
            Assert-OrdinalStringSet -Actual $actualFiles -Expected $expectedFiles -Context "platform '$($platform.id)' rule inventory"
        }
    }

    # Scenario: A localized Base route or an internal rule reference drifts from its declared target.
    # Purpose: Keep every trigger identity attached to one existing same-platform, same-locale module without comparing translated prose.
    It 'InterT30_routes_every_declared_trigger_to_the_exact_locale_target' {
        $contract = Get-AiInstructionContract
        foreach ($platform in @($contract.platforms)) {
            $platformModules = @($contract.modules | Where-Object { @($_.platforms) -ccontains [string]$platform.id })
            foreach ($locale in @($contract.locales)) {
                $basePath = Get-ContractFullPath -RelativePath (Get-PlatformBaseRelativePath -Platform $platform -LocaleId ([string]$locale.id))
                $baseText = Get-AiInstructionText -Path $basePath
                $routes = @(Get-AiRoutes -Text $baseText)
                Assert-OrdinalStringSet -Actual @($routes | ForEach-Object { $_.id }) -Expected @($platformModules | ForEach-Object { $_.id }) -Context "platform '$($platform.id)' locale '$($locale.id)' routes"

                foreach ($module in $platformModules) {
                    $route = @($routes | Where-Object { [string]$_.id -ceq [string]$module.id })
                    if ($route.Count -ne 1) { throw "Module '$($module.id)' must have exactly one route." }
                    $expectedTarget = ([string]$platform.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                    if (-not [string]::Equals([string]$route[0].target, $expectedTarget, [System.StringComparison]::Ordinal)) {
                        throw "Route '$($module.id)' expected '$expectedTarget', actual '$($route[0].target)'."
                    }
                    Assert-OrdinalStringSet -Actual @($route[0].triggers) -Expected @($module.triggers) -Context "route '$($module.id)' trigger contract"
                }

                Assert-AiRuleReferences -Text $baseText -Platform $platform -Locale $locale
                foreach ($module in $platformModules) {
                    $rulePath = ([string]$platform.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                    Assert-AiRuleReferences -Text (Get-AiInstructionText -Path (Get-ContractFullPath -RelativePath $rulePath)) -Platform $platform -Locale $locale
                }
            }
        }
    }

    # Scenario: Route metadata contains malformed JSON, unknown or repeated fields, or duplicate/scalar triggers.
    # Purpose: Keep trigger parity fail-closed instead of accepting a payload that ConvertFrom-Json silently normalizes.
    It 'InterT35_rejects_malformed_or_ambiguous_route_metadata' {
        $invalidRoutes = @(
            [pscustomobject]@{ name = 'malformed JSON'; text = '- route -> `.codex/AI-Rules/Testing.md` <!-- ai-route:{not-json} -->' },
            [pscustomobject]@{ name = 'unknown field'; text = '- route -> `.codex/AI-Rules/Testing.md` <!-- ai-route:{"module":"testing","triggers":["test-change"],"extra":true} -->' },
            [pscustomobject]@{ name = 'duplicate module field'; text = '- route -> `.codex/AI-Rules/Testing.md` <!-- ai-route:{"module":"testing","module":"database","triggers":["test-change"]} -->' },
            [pscustomobject]@{ name = 'duplicate trigger'; text = '- route -> `.codex/AI-Rules/Testing.md` <!-- ai-route:{"module":"testing","triggers":["test-change","test-change"]} -->' },
            [pscustomobject]@{ name = 'scalar trigger'; text = '- route -> `.codex/AI-Rules/Testing.md` <!-- ai-route:{"module":"testing","triggers":"test-change"} -->' }
        )
        foreach ($invalidRoute in $invalidRoutes) {
            Assert-Throws -Action { Get-AiRoutes -Text ([string]$invalidRoute.text) } -Context ([string]$invalidRoute.name)
        }
    }

    # Scenario: A safety requirement is removed from one language or platform while prose still looks plausible.
    # Purpose: Compare stable invariant identities, not translated wording, and require each marker exactly once beside substantive text.
    It 'InterT40_keeps_declared_safety_invariants_in_every_applicable_variant' {
        $contract = Get-AiInstructionContract
        foreach ($platform in @($contract.platforms)) {
            $expectedBaseInvariants = @($contract.baseInvariants | Where-Object { @($_.platforms) -ccontains [string]$platform.id } | ForEach-Object { $_.id })
            foreach ($locale in @($contract.locales)) {
                $basePath = Get-ContractFullPath -RelativePath (Get-PlatformBaseRelativePath -Platform $platform -LocaleId ([string]$locale.id))
                Assert-OrdinalStringSet -Actual @(Get-AiInvariantIds -Text (Get-AiInstructionText -Path $basePath)) -Expected $expectedBaseInvariants -Context "platform '$($platform.id)' locale '$($locale.id)' base invariants"

                foreach ($module in @($contract.modules | Where-Object { @($_.platforms) -ccontains [string]$platform.id })) {
                    $rulePath = ([string]$platform.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                    $actual = @(Get-AiInvariantIds -Text (Get-AiInstructionText -Path (Get-ContractFullPath -RelativePath $rulePath)))
                    Assert-OrdinalStringSet -Actual $actual -Expected @($module.invariants) -Context "platform '$($platform.id)' locale '$($locale.id)' module '$($module.id)' invariants"
                }
            }
        }
    }

    # Scenario: A common rule changes on only Codex or Copilot while each localized pair remains present.
    # Purpose: Enforce exact same-locale semantics after normalizing only the declared platform rule root.
    It 'InterT50_keeps_common_rules_normalized_across_platforms' {
        $contract = Get-AiInstructionContract
        $codex = @($contract.platforms | Where-Object { [string]$_.id -ceq 'codex' })[0]
        $copilot = @($contract.platforms | Where-Object { [string]$_.id -ceq 'github-copilot' })[0]
        foreach ($module in @($contract.modules | Where-Object { @($_.platforms) -ccontains 'codex' -and @($_.platforms) -ccontains 'github-copilot' })) {
            foreach ($locale in @($contract.locales)) {
                $codexRelative = ([string]$codex.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                $copilotRelative = ([string]$copilot.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                $codexText = Get-AiInstructionText -Path (Get-ContractFullPath -RelativePath $codexRelative)
                $copilotText = Get-AiInstructionText -Path (Get-ContractFullPath -RelativePath $copilotRelative)
                if ($codexText.Contains(([string]$copilot.rulesRoot + '/')) -or $copilotText.Contains(([string]$codex.rulesRoot + '/'))) {
                    throw "Module '$($module.id)' locale '$($locale.id)' contains an opposite-platform rule reference."
                }
                $codexNormalized = $codexText.Replace(([string]$codex.rulesRoot + '/'), '{RULE_ROOT}/')
                $copilotNormalized = $copilotText.Replace(([string]$copilot.rulesRoot + '/'), '{RULE_ROOT}/')
                if (-not [string]::Equals($codexNormalized, $copilotNormalized, [System.StringComparison]::Ordinal)) {
                    throw "Module '$($module.id)' locale '$($locale.id)' is not normalized-equivalent across platforms."
                }
            }
        }
    }
}
