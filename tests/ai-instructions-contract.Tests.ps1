Describe 'AI instructions machine-readable contract' {
    BeforeAll {
        $script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:ContractPath = Join-Path $script:RepositoryRoot 'ai-instructions-contract.json'
        $script:BootstrapPath = Join-Path $script:RepositoryRoot 'scripts\bootstrap-ai-instructions.ps1'
        $script:BuilderPath = Join-Path $script:RepositoryRoot 'scripts\Build-AiInstructions.ps1'

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
        $targets = [regex]::Matches($line, '`(?<path>\.(?:codex|github|claude)/AI-Rules/[^`]+\.md)`')
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

    $references = [regex]::Matches($Text, '`(?<path>\.(?:codex|github|claude)/AI-Rules/[^`]+\.md)`')
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

function Assert-AiInstructionContractV2Envelope {
    param([Parameter(Mandatory = $true)] $Contract)

    Assert-ExactPropertySet -Value $Contract -Expected @('schemaVersion','primaryLocale','fanOutLocale','locales','source','platforms','modules','baseInvariants') -Context 'contract'
    if (($Contract.schemaVersion -isnot [int] -and $Contract.schemaVersion -isnot [long]) -or [int64]$Contract.schemaVersion -ne 2) {
        throw "Unexpected schemaVersion '$($Contract.schemaVersion)'."
    }
    Assert-ExactPropertySet -Value $Contract.source -Expected @('root','hostBlockSyntaxVersion','generatedHeader') -Context 'contract source'
    if ([string]$Contract.source.root -cne 'instructions/common' -or [int64]$Contract.source.hostBlockSyntaxVersion -ne 1 -or $null -ne $Contract.source.generatedHeader) {
        throw 'Unexpected contract source declaration.'
    }
    foreach ($locale in @($Contract.locales)) {
        Assert-ExactPropertySet -Value $locale -Expected @('id','ruleSuffix') -Context "locale '$($locale.id)'"
    }
    Assert-OrdinalStringSet -Actual @($Contract.platforms | ForEach-Object id) -Expected @('codex','github-copilot','claude') -Context 'platform inventory'
    foreach ($platform in @($Contract.platforms)) {
        Assert-ExactPropertySet -Value $platform -Expected @('id','base','rulesRoot','userSkillsRoot','fanOut') -Context "platform '$($platform.id)'"
        Assert-ExactPropertySet -Value $platform.base -Expected @('zh-TW','en') -Context "platform '$($platform.id)' base"
        if ($null -ne $platform.fanOut) {
            Assert-ExactPropertySet -Value $platform.fanOut -Expected @('baseTarget','rulesTarget','preserveRuleFileName') -Context "platform '$($platform.id)' fanOut"
        }
    }
    foreach ($module in @($Contract.modules)) {
        Assert-ExactPropertySet -Value $module -Expected @('id','fileStem','platforms','triggers','invariants') -Context "module '$($module.id)'"
    }
    foreach ($baseInvariant in @($Contract.baseInvariants)) {
        Assert-ExactPropertySet -Value $baseInvariant -Expected @('id','platforms') -Context "base invariant '$($baseInvariant.id)'"
    }
}

function Invoke-AiInstructionBuilderProcess {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [switch] $Check
    )

    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BuilderPath,'-RepositoryRoot',$Root)
    if ($Check) { $arguments += '-Check' }
    $output = & powershell.exe @arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function New-AiInstructionFixture {
    param([Parameter(Mandatory = $true)][string] $Name, [switch] $IncludeOutputs)

    $root = Join-Path $TestDrive $Name
    [void](New-Item -ItemType Directory -Path $root -Force)
    Copy-Item -LiteralPath $script:ContractPath -Destination $root
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'instructions') -Destination $root -Recurse
    if ($IncludeOutputs) {
        foreach ($directory in @('.codex','.github','.claude')) {
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $directory) -Destination $root -Recurse
        }
    }
    return $root
}

    }

    # Scenario: The maintenance contract is parsed under every supported PowerShell lane.
    # Purpose: Reject silent contract expansion, unsafe paths, duplicate identities, and vacuous all-missing parity.
    It 'InterT10_validates_the_closed_v2_contract_shape_and_rejects_v1_or_unknown_fields' {
        $contract = Get-AiInstructionContract
        Assert-AiInstructionContractV2Envelope -Contract $contract
        $v1 = ($contract | ConvertTo-Json -Depth 20) | ConvertFrom-Json
        $v1.schemaVersion = 1
        Assert-Throws -Action { Assert-AiInstructionContractV2Envelope -Contract $v1 } -Context 'v1 contract'
        $unknownTopLevel = ($contract | ConvertTo-Json -Depth 20) | ConvertFrom-Json
        $unknownTopLevel | Add-Member -NotePropertyName unsupported -NotePropertyValue $true
        Assert-Throws -Action { Assert-AiInstructionContractV2Envelope -Contract $unknownTopLevel } -Context 'unknown top-level field'
        $unknownSource = ($contract | ConvertTo-Json -Depth 20) | ConvertFrom-Json
        $unknownSource.source | Add-Member -NotePropertyName unsupported -NotePropertyValue $true
        Assert-Throws -Action { Assert-AiInstructionContractV2Envelope -Contract $unknownSource } -Context 'unknown source field'
        $unknownPlatform = ($contract | ConvertTo-Json -Depth 20) | ConvertFrom-Json
        $unknownPlatform.platforms[0] | Add-Member -NotePropertyName unsupported -NotePropertyValue $true
        Assert-Throws -Action { Assert-AiInstructionContractV2Envelope -Contract $unknownPlatform } -Context 'unknown platform field'
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

        Assert-OrdinalStringSet -Actual @($contract.platforms | ForEach-Object { $_.id }) -Expected @('codex','github-copilot','claude') -Context 'platform inventory'
        $bootstrap = Get-AiInstructionText -Path $script:BootstrapPath
        foreach ($platform in @($contract.platforms)) {
            Assert-ExactPropertySet -Value $platform -Expected @('id','base','rulesRoot','userSkillsRoot','fanOut') -Context "platform '$($platform.id)'"
            Assert-ExactPropertySet -Value $platform.base -Expected @('zh-TW','en') -Context "platform '$($platform.id)' base"
            Assert-AiJsonString -Value $platform.id -Context 'platform id'
            foreach ($pathValue in @($platform.base.'zh-TW',$platform.base.en,$platform.rulesRoot)) {
                Assert-AiJsonString -Value $pathValue -Context "platform '$($platform.id)' path"
                $path = [string]$pathValue
                [void](Get-ContractFullPath -RelativePath $path)
            }
            Assert-AiJsonString -Value $platform.userSkillsRoot -Context "platform '$($platform.id)' USER Skills root"
            $expectedUserSkillsRoot = if ([string]$platform.id -ceq 'claude') { '~/.claude/skills' } else { '~/.agents/skills' }
            if ([string]$platform.userSkillsRoot -cne $expectedUserSkillsRoot) { throw "Platform '$($platform.id)' has an unexpected USER Skills root." }
            if ($null -eq $platform.fanOut) { throw "Platform '$($platform.id)' must declare fan-out in contract v2." }
            Assert-ExactPropertySet -Value $platform.fanOut -Expected @('baseTarget','rulesTarget','preserveRuleFileName') -Context "platform '$($platform.id)' fanOut"
            foreach ($pathValue in @($platform.fanOut.baseTarget,$platform.fanOut.rulesTarget)) {
                Assert-AiJsonString -Value $pathValue -Context "platform '$($platform.id)' fan-out path"
                [void](Get-ContractFullPath -RelativePath ([string]$pathValue))
            }
            if ($platform.fanOut.preserveRuleFileName -isnot [bool] -or -not [bool]$platform.fanOut.preserveRuleFileName) {
                throw "Platform '$($platform.id)' must preserve rule filenames during fan-out."
            }

            $familyName = if ([string]$platform.id -ceq 'codex') { 'Codex' } elseif ([string]$platform.id -ceq 'claude') { 'Claude' } else { 'GitHub Copilot' }
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

        Assert-OrdinalStringSet -Actual @($contract.modules | ForEach-Object { $_.id }) -Expected @('code-review','database','external-research','git-commit','testing') -Context 'v2 module inventory'
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

    # Scenario: An authority platform exists before its consumer fan-out is enabled.
    # Purpose: Keep bootstrap families exactly aligned with non-null fanOut declarations and prevent premature Claude fan-out.
    It 'InterT12_matches_bootstrap_families_to_non_null_contract_fan_out' {
        $contract = Get-AiInstructionContract
        $bootstrap = Get-AiInstructionText -Path $script:BootstrapPath
        $familySection = [regex]::Match($bootstrap, '(?s)\$families\s*=\s*@\((?<body>.*?)\)\s*.*?\r?\n\$sharedSkillsFamilyName')
        if (-not $familySection.Success) { throw 'Could not parse bootstrap $families.' }
        $actualNames = @([regex]::Matches($familySection.Value, "Name\s*=\s*'(?<name>[^']+)'") | ForEach-Object { $_.Groups['name'].Value })
        $nameByPlatform = @{ codex = 'Codex'; 'github-copilot' = 'GitHub Copilot'; claude = 'Claude' }
        $expectedNames = @($contract.platforms | Where-Object { $null -ne $_.fanOut } | ForEach-Object { $nameByPlatform[[string]$_.id] })
        Assert-OrdinalStringSet -Actual $actualNames -Expected $expectedNames -Context 'bootstrap fan-out family inventory'
        if ($actualNames -cnotcontains 'Claude') { throw 'Claude fan-out must be enabled for the v4 writer.' }
    }

    # Scenario: A common source or generated authority artifact drifts after generation.
    # Purpose: Require -Check to pass for the repository and identify the affected artifact for either source-side or output-side drift.
    It 'InterT15_checks_generated_outputs_and_reports_source_or_artifact_drift' {
        $current = Invoke-AiInstructionBuilderProcess -Root $script:RepositoryRoot -Check
        if ($current.ExitCode -ne 0) { throw "Repository generation check failed: $($current.Output)" }

        $sourceRoot = New-AiInstructionFixture -Name 'source-drift' -IncludeOutputs
        [System.IO.File]::AppendAllText((Join-Path $sourceRoot 'instructions\common\base.md'), "source drift`n", (New-Object System.Text.UTF8Encoding($false)))
        $sourceResult = Invoke-AiInstructionBuilderProcess -Root $sourceRoot -Check
        if ($sourceResult.ExitCode -eq 0 -or $sourceResult.Output -cnotmatch [regex]::Escape('.codex/AGENTS.md')) {
            throw "Common-source drift was not reported with an affected artifact: $($sourceResult.Output)"
        }

        $artifactRoot = New-AiInstructionFixture -Name 'artifact-drift' -IncludeOutputs
        [System.IO.File]::AppendAllText((Join-Path $artifactRoot '.claude\CLAUDE.md'), "artifact drift`n", (New-Object System.Text.UTF8Encoding($false)))
        $artifactResult = Invoke-AiInstructionBuilderProcess -Root $artifactRoot -Check
        if ($artifactResult.ExitCode -eq 0 -or $artifactResult.Output -cnotmatch [regex]::Escape('.claude/CLAUDE.md')) {
            throw "Artifact drift was not reported: $($artifactResult.Output)"
        }
    }

    # Scenario: Generation runs on a host with different native encoding or newline defaults.
    # Purpose: Keep every authority artifact byte-deterministic as UTF-8 without BOM, LF-only, and exactly one final newline.
    It 'InterT16_emits_deterministic_utf8_lf_bytes' {
        $root = New-AiInstructionFixture -Name 'deterministic-bytes'
        $generation = Invoke-AiInstructionBuilderProcess -Root $root
        if ($generation.ExitCode -ne 0) { throw "Fixture generation failed: $($generation.Output)" }
        $contract = Get-AiInstructionContract
        foreach ($platform in @($contract.platforms)) {
            $paths = @($platform.base.'zh-TW', $platform.base.en)
            foreach ($module in @($contract.modules | Where-Object { @($_.platforms) -ccontains [string]$platform.id })) {
                foreach ($locale in @($contract.locales)) {
                    $paths += ([string]$platform.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                }
            }
            foreach ($relativePath in $paths) {
                $bytes = [System.IO.File]::ReadAllBytes((Join-Path $root ([string]$relativePath)))
                if ($bytes.Length -eq 0 -or $bytes[$bytes.Length - 1] -ne 0x0A -or ($bytes.Length -gt 1 -and $bytes[$bytes.Length - 2] -eq 0x0A)) {
                    throw "Generated artifact '$relativePath' does not have exactly one final LF."
                }
                if (($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or $bytes -contains 0x0D) {
                    throw "Generated artifact '$relativePath' is not UTF-8 without BOM and LF-only."
                }
            }
        }
    }

    # Scenario: Git checks out common sources or generated authority artifacts on a Windows runner.
    # Purpose: Require every contract-declared source and output path to retain LF bytes across all platforms.
    It 'InterT17_declares_lf_checkout_for_all_contract_sources_and_outputs' {
        $contract = Get-AiInstructionContract
        $paths = @()
        foreach ($locale in @($contract.locales)) {
            $paths += ([string]$contract.source.root + '/' + $(if ([string]$locale.id -ceq [string]$contract.primaryLocale) { 'base.md' } else { "base.$($locale.id).md" }))
            foreach ($module in @($contract.modules)) {
                $paths += ([string]$contract.source.root + '/AI-Rules/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
            }
        }
        foreach ($platform in @($contract.platforms)) {
            foreach ($locale in @($contract.locales)) {
                $paths += Get-PlatformBaseRelativePath -Platform $platform -LocaleId ([string]$locale.id)
                foreach ($module in @($contract.modules | Where-Object { @($_.platforms) -ccontains [string]$platform.id })) {
                    $paths += ([string]$platform.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                }
            }
        }
        $paths = @($paths | Sort-Object -CaseSensitive -Unique)
        $attributes = @(& git -C $script:RepositoryRoot check-attr eol -- @paths)
        if ($LASTEXITCODE -ne 0) { throw "git check-attr failed for AI Instructions paths." }
        $lfPaths = @($attributes | ForEach-Object {
            $match = [regex]::Match([string]$_, '^(?<path>.*): eol: lf$')
            if ($match.Success) { $match.Groups['path'].Value }
        })
        Assert-OrdinalStringSet -Actual $lfPaths -Expected $paths -Context 'AI Instructions LF attributes'
    }

    # Scenario: A host adapter block is ambiguous, incomplete, unknown, or spans a machine-readable marker.
    # Purpose: Fail closed before generation can silently alter route or invariant membership.
    It 'InterT18_rejects_invalid_host_block_syntax' {
        $cases = @(
            [pscustomobject]@{ Name = 'nested'; RelativePath = 'instructions\common\base.md'; Text = "<!-- host:codex -->`n<!-- host:claude -->`ntext`n<!-- /host -->`n<!-- /host -->`n" },
            [pscustomobject]@{ Name = 'unclosed'; RelativePath = 'instructions\common\base.md'; Text = "<!-- host:codex -->`ntext`n" },
            [pscustomobject]@{ Name = 'unknown'; RelativePath = 'instructions\common\base.md'; Text = "<!-- host:unknown -->text<!-- /host -->`n" },
            [pscustomobject]@{ Name = 'marker crossing'; RelativePath = 'instructions\common\base.md'; Text = "<!-- host:codex -->`ntext <!-- ai-invariant:base.test -->`n<!-- /host -->`n" },
            [pscustomobject]@{ Name = 'multiple inline'; RelativePath = 'instructions\common\base.md'; Text = "<!-- host:codex -->one<!-- /host --><!-- host:claude -->two<!-- /host -->`n" },
            [pscustomobject]@{ Name = 'nested inline'; RelativePath = 'instructions\common\base.md'; Text = "<!-- host:codex -->outer <!-- host:claude -->inner<!-- /host --><!-- /host -->`n" },
            [pscustomobject]@{ Name = 'rule block'; RelativePath = 'instructions\common\AI-Rules\Testing.md'; Text = "<!-- host:codex -->rule text<!-- /host -->`n" }
        )
        foreach ($case in $cases) {
            $root = New-AiInstructionFixture -Name ("host-" + $case.Name.Replace(' ', '-'))
            [System.IO.File]::AppendAllText((Join-Path $root ([string]$case.RelativePath)), [string]$case.Text, (New-Object System.Text.UTF8Encoding($false)))
            $result = Invoke-AiInstructionBuilderProcess -Root $root -Check
            if ($result.ExitCode -eq 0) { throw "Invalid host syntax '$($case.Name)' was accepted." }
            if ($case.Name -ceq 'rule block' -and
                ($result.Output -cnotmatch 'RuleHostBlockNotAllowed' -or $result.Output -cnotmatch [regex]::Escape('instructions/common/AI-Rules/Testing.md'))) {
                throw "Rule host block failure did not identify its type and source file: $($result.Output)"
            }
        }
    }

    # Scenario: An existing generated artifact contains bytes that are not valid UTF-8.
    # Purpose: Let -Check report the drift without writing, then let normal generation repair the artifact.
    It 'InterT19_reports_and_repairs_invalid_utf8_generated_artifacts' {
        $root = New-AiInstructionFixture -Name 'invalid-output-utf8' -IncludeOutputs
        $relativePath = '.codex/AGENTS.md'
        $targetPath = Join-Path $root '.codex\AGENTS.md'
        [System.IO.File]::WriteAllBytes($targetPath, [byte[]]@(0xC3, 0x28))

        $check = Invoke-AiInstructionBuilderProcess -Root $root -Check
        if ($check.ExitCode -eq 0 -or $check.Output -cnotmatch [regex]::Escape($relativePath)) {
            throw "Invalid UTF-8 artifact was not reported as drift: $($check.Output)"
        }
        $invalidBytes = [System.IO.File]::ReadAllBytes($targetPath)
        if ($invalidBytes.Length -ne 2 -or $invalidBytes[0] -ne 0xC3 -or $invalidBytes[1] -ne 0x28) {
            throw '-Check modified the invalid UTF-8 artifact.'
        }

        $generation = Invoke-AiInstructionBuilderProcess -Root $root
        if ($generation.ExitCode -ne 0) { throw "Generation did not repair invalid UTF-8: $($generation.Output)" }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $null = $strictUtf8.GetString([System.IO.File]::ReadAllBytes($targetPath))
        $verified = Invoke-AiInstructionBuilderProcess -Root $root -Check
        if ($verified.ExitCode -ne 0) { throw "Repaired artifact did not pass -Check: $($verified.Output)" }
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

    # Scenario: A retired rule remains in a platform rules root or the common source rules directory.
    # Purpose: Make both generation modes fail closed, identify every undeclared direct Markdown file, and avoid changing generated artifacts.
    It 'InterT21_rejects_unexpected_rule_sources_and_artifacts_before_writing' {
        $cases = @(
            [pscustomobject]@{ Name = 'platform-artifact'; RelativePath = '.codex/AI-Rules/Old.en.md' },
            [pscustomobject]@{ Name = 'common-source'; RelativePath = 'instructions/common/AI-Rules/Old.md' }
        )
        foreach ($case in $cases) {
            foreach ($checkMode in @($false, $true)) {
                $modeName = if ($checkMode) { 'check' } else { 'generate' }
                $root = New-AiInstructionFixture -Name ("unexpected-$($case.Name)-$modeName") -IncludeOutputs
                $unexpectedPath = Join-Path $root ([string]$case.RelativePath).Replace('/', '\')
                [System.IO.File]::WriteAllText($unexpectedPath, "retired rule`n", (New-Object System.Text.UTF8Encoding($false)))
                $sentinelPath = Join-Path $root '.codex\AGENTS.md'
                [System.IO.File]::AppendAllText($sentinelPath, "must remain unchanged`n", (New-Object System.Text.UTF8Encoding($false)))
                $sentinelBytes = [System.IO.File]::ReadAllBytes($sentinelPath)

                $result = Invoke-AiInstructionBuilderProcess -Root $root -Check:$checkMode
                if ($result.ExitCode -eq 0 -or
                    $result.Output -cnotmatch 'UnexpectedInstructionArtifact' -or
                    $result.Output -cnotmatch [regex]::Escape([string]$case.RelativePath)) {
                    throw "Unexpected rule '$($case.RelativePath)' was not reported in $modeName mode: $($result.Output)"
                }
                $actualBytes = [System.IO.File]::ReadAllBytes($sentinelPath)
                if ([Convert]::ToBase64String($sentinelBytes) -cne [Convert]::ToBase64String($actualBytes)) {
                    throw "Builder modified an artifact before rejecting '$($case.RelativePath)' in $modeName mode."
                }
            }
        }
    }

    # Scenario: An existing generated artifact has equivalent text but CRLF bytes or a UTF-8 BOM.
    # Purpose: Require -Check to report byte drift and normal generation to restore the exact canonical LF bytes.
    It 'InterT22_checks_and_repairs_noncanonical_generated_artifact_bytes' {
        $relativePath = '.codex/AGENTS.md'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $cases = @(
            [pscustomobject]@{
                Name = 'crlf'
                Mutate = {
                    param([byte[]] $ExpectedBytes)
                    $text = $utf8NoBom.GetString($ExpectedBytes)
                    return $utf8NoBom.GetBytes($text.Replace("`n", "`r`n"))
                }
            },
            [pscustomobject]@{
                Name = 'bom'
                Mutate = {
                    param([byte[]] $ExpectedBytes)
                    return [byte[]](@(0xEF, 0xBB, 0xBF) + @($ExpectedBytes))
                }
            }
        )

        foreach ($case in $cases) {
            $root = New-AiInstructionFixture -Name ("noncanonical-output-" + $case.Name)
            $baseline = Invoke-AiInstructionBuilderProcess -Root $root
            if ($baseline.ExitCode -ne 0) { throw "Fixture generation failed for $($case.Name): $($baseline.Output)" }
            $targetPath = Join-Path $root '.codex\AGENTS.md'
            $expectedBytes = [System.IO.File]::ReadAllBytes($targetPath)
            $driftBytes = & $case.Mutate $expectedBytes
            [System.IO.File]::WriteAllBytes($targetPath, $driftBytes)

            $check = Invoke-AiInstructionBuilderProcess -Root $root -Check
            if ($check.ExitCode -eq 0 -or $check.Output -cnotmatch [regex]::Escape($relativePath)) {
                throw "Noncanonical $($case.Name) artifact bytes were not reported as drift: $($check.Output)"
            }
            if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($targetPath)) -cne [Convert]::ToBase64String($driftBytes)) {
                throw "-Check modified the noncanonical $($case.Name) artifact."
            }

            $generation = Invoke-AiInstructionBuilderProcess -Root $root
            if ($generation.ExitCode -ne 0) { throw "Generation did not repair $($case.Name) artifact bytes: $($generation.Output)" }
            if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($targetPath)) -cne [Convert]::ToBase64String($expectedBytes)) {
                throw "Generation did not restore the exact canonical bytes for the $($case.Name) artifact."
            }
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

    # Scenario: The USER-only safety rule disappears while the other declared Base invariants remain intact.
    # Purpose: Require this shared installation boundary in the contract and all six Base variants.
    It 'InterT45_declares_the_USER_only_shared_Skills_safety_invariant' {
        $contract = Get-AiInstructionContract
        $identity = 'base.shared-skills-user-only'
        $declaration = @($contract.baseInvariants | Where-Object { $_.id -ceq $identity })
        $declaration.Count | Should Be 1
        Assert-OrdinalStringSet -Actual @($declaration[0].platforms) -Expected @('codex','github-copilot','claude') -Context 'USER-only invariant platforms'
        foreach ($platform in @($contract.platforms)) {
            foreach ($locale in @($contract.locales)) {
                $path = Get-ContractFullPath -RelativePath (Get-PlatformBaseRelativePath -Platform $platform -LocaleId ([string]$locale.id))
                $text = Get-AiInstructionText -Path $path
                @((Get-AiInvariantIds -Text $text) | Where-Object { $_ -ceq $identity }).Count | Should Be 1
                $withoutRule = [regex]::Replace($text, '(?m)^.*<!-- ai-invariant:base\.shared-skills-user-only -->.*\n?', '')
                $expected = @($contract.baseInvariants | Where-Object { @($_.platforms) -ccontains [string]$platform.id } | ForEach-Object id)
                Assert-Throws -Action { Assert-OrdinalStringSet -Actual @(Get-AiInvariantIds -Text $withoutRule) -Expected $expected -Context 'removed USER-only rule' } -Context 'missing USER-only invariant'
            }
        }
    }

    # Scenario: A common rule changes on only one platform while each localized pair remains present.
    # Purpose: Enforce exact same-locale semantics after normalizing the declared rule and USER Skills roots.
    It 'InterT50_keeps_common_rules_normalized_across_platforms' {
        $contract = Get-AiInstructionContract
        foreach ($module in @($contract.modules)) {
            foreach ($locale in @($contract.locales)) {
                $normalizedByPlatform = @{}
                $applicablePlatforms = @($contract.platforms | Where-Object { @($module.platforms) -ccontains [string]$_.id })
                foreach ($platform in $applicablePlatforms) {
                    $relative = ([string]$platform.rulesRoot + '/' + [string]$module.fileStem + [string]$locale.ruleSuffix)
                    $text = Get-AiInstructionText -Path (Get-ContractFullPath -RelativePath $relative)
                    foreach ($otherPlatform in @($contract.platforms | Where-Object { [string]$_.id -cne [string]$platform.id })) {
                        if ($text.Contains(([string]$otherPlatform.rulesRoot + '/'))) {
                            throw "Module '$($module.id)' locale '$($locale.id)' contains an opposite-platform rule reference."
                        }
                    }
                    if ($text.Contains('{RULE_ROOT}') -or $text.Contains('{USER_SKILLS_ROOT}')) { throw "Module '$($module.id)' locale '$($locale.id)' contains an unresolved placeholder." }
                    $normalizedByPlatform[[string]$platform.id] = $text.Replace(([string]$platform.rulesRoot + '/'), '{RULE_ROOT}/').Replace(([string]$platform.userSkillsRoot + '/'), '{USER_SKILLS_ROOT}/')
                }
                $reference = [string]$normalizedByPlatform[[string]$applicablePlatforms[0].id]
                foreach ($platform in @($applicablePlatforms | Select-Object -Skip 1)) {
                    if (-not [string]::Equals($reference, [string]$normalizedByPlatform[[string]$platform.id], [System.StringComparison]::Ordinal)) {
                        throw "Module '$($module.id)' locale '$($locale.id)' is not normalized-equivalent across platforms."
                    }
                }
            }
        }
    }

}
