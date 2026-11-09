[CmdletBinding()]
param(
    [switch] $Check,
    [string] $RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:KnownHosts = @('codex', 'copilot', 'claude')

function Get-NormalizedInstructionText {
    param([Parameter(Mandatory = $true)][string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = $script:Utf8Strict.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return $text.TrimEnd([char[]]@("`n")) + "`n"
}

function Get-ExactPropertyNames {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actual = @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    $expectedSorted = @($Expected | Sort-Object -CaseSensitive)
    if (-not [string]::Equals(($actual -join "`n"), ($expectedSorted -join "`n"), [System.StringComparison]::Ordinal)) {
        throw "$Context has an unsupported property set. Expected [$($expectedSorted -join ', ')], actual [$($actual -join ', ')]."
    }
}

function Resolve-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.StartsWith('/') -or $RelativePath.StartsWith('\') -or
        $RelativePath -match '^[A-Za-z]:' -or $RelativePath.Contains('\')) {
        throw "Unsafe AI Instructions path '$RelativePath'."
    }
    $segments = @($RelativePath.Split('/'))
    if (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "Unsafe AI Instructions path '$RelativePath'."
    }
    $native = $RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $native))
    $prefix = $Root.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "AI Instructions path escapes the repository: '$RelativePath'."
    }
    return $full
}

function Expand-InstructionHostBlocks {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $TargetHost,
        [Parameter(Mandatory = $true)][string] $SourcePath
    )

    if ($script:KnownHosts -cnotcontains $TargetHost) {
        throw "Unknown target host '$TargetHost'."
    }

    $activeHost = $null
    $output = New-Object System.Text.StringBuilder
    $lines = [regex]::Matches($Text, '(?m)^.*(?:\n|$)')
    foreach ($lineMatch in $lines) {
        $lineWithEnding = $lineMatch.Value
        if ($lineWithEnding.Length -eq 0) { continue }
        $line = $lineWithEnding.TrimEnd("`n")
        $hasNewline = $lineWithEnding.EndsWith("`n", [System.StringComparison]::Ordinal)

        $open = [regex]::Match($line, '^\s*<!-- host:(?<host>[a-z0-9-]+) -->\s*$')
        $close = [regex]::Match($line, '^\s*<!-- /host -->\s*$')
        $inline = [regex]::Match($line, '^\s*<!-- host:(?<host>[a-z0-9-]+) -->(?<body>.*?)<!-- /host -->\s*$')
        $hostOpenPrefixCount = [regex]::Matches($line, '<!--\s*host:').Count
        $hostClosePrefixCount = [regex]::Matches($line, '<!--\s*/host').Count
        $hostPrefixCount = $hostOpenPrefixCount + $hostClosePrefixCount

        if ($inline.Success) {
            if ($hostOpenPrefixCount -ne 1 -or $hostClosePrefixCount -ne 1) {
                throw "An inline host block must contain exactly one opener and one terminator in '$SourcePath': $line"
            }
            if ($null -ne $activeHost) { throw "Nested host block in '$SourcePath'." }
            $inlineHost = $inline.Groups['host'].Value
            if ($script:KnownHosts -cnotcontains $inlineHost) { throw "Unknown host '$inlineHost' in '$SourcePath'." }
            if ($inlineHost -ceq $TargetHost) {
                [void]$output.Append($inline.Groups['body'].Value)
                if ($hasNewline) { [void]$output.Append("`n") }
            }
            continue
        }
        if ($open.Success) {
            if ($null -ne $activeHost) { throw "Nested host block in '$SourcePath'." }
            $candidate = $open.Groups['host'].Value
            if ($script:KnownHosts -cnotcontains $candidate) { throw "Unknown host '$candidate' in '$SourcePath'." }
            $activeHost = $candidate
            continue
        }
        if ($close.Success) {
            if ($null -eq $activeHost) { throw "Unmatched host block terminator in '$SourcePath'." }
            $activeHost = $null
            continue
        }
        if ($hostPrefixCount -gt 0) {
            throw "Malformed host block syntax in '$SourcePath': $line"
        }
        if ($null -ne $activeHost -and $line -match '<!--\s*ai-(?:route|invariant):') {
            throw "Host block crosses an AI marker line in '$SourcePath'. Keep a marker-bearing host block on one physical line."
        }
        if ($null -eq $activeHost -or $activeHost -ceq $TargetHost) {
            [void]$output.Append($line)
            if ($hasNewline) { [void]$output.Append("`n") }
        }
    }
    if ($null -ne $activeHost) {
        throw "Unclosed host block for '$activeHost' in '$SourcePath'."
    }
    return $output.ToString().TrimEnd([char[]]@("`n")) + "`n"
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$root = [System.IO.Path]::GetFullPath($RepositoryRoot)
$contractPath = Resolve-RepositoryPath -Root $root -RelativePath 'ai-instructions-contract.json'
$contract = (Get-NormalizedInstructionText -Path $contractPath) | ConvertFrom-Json
Get-ExactPropertyNames -Value $contract -Expected @('schemaVersion','primaryLocale','fanOutLocale','locales','source','platforms','modules','baseInvariants') -Context 'AI Instructions contract'
if ([int64]$contract.schemaVersion -ne 2) { throw "Build-AiInstructions requires contract schemaVersion 2." }
Get-ExactPropertyNames -Value $contract.source -Expected @('root','hostBlockSyntaxVersion','generatedHeader') -Context 'AI Instructions source'
if ([int64]$contract.source.hostBlockSyntaxVersion -ne 1) { throw "Unsupported host block syntax version '$($contract.source.hostBlockSyntaxVersion)'." }
if ($null -ne $contract.source.generatedHeader) { throw 'Only a null generatedHeader is supported in contract v2.' }
foreach ($locale in @($contract.locales)) {
    Get-ExactPropertyNames -Value $locale -Expected @('id','ruleSuffix') -Context "locale '$($locale.id)'"
}
$platformIds = @($contract.platforms | ForEach-Object { [string]$_.id } | Sort-Object -CaseSensitive)
if (-not [string]::Equals(($platformIds -join "`n"), ((@('codex','github-copilot','claude') | Sort-Object -CaseSensitive) -join "`n"), [System.StringComparison]::Ordinal)) {
    throw "Contract v2 must declare exactly Codex, GitHub Copilot, and Claude."
}
foreach ($platform in @($contract.platforms)) {
    Get-ExactPropertyNames -Value $platform -Expected @('id','base','rulesRoot','userSkillsRoot','fanOut') -Context "platform '$($platform.id)'"
    Get-ExactPropertyNames -Value $platform.base -Expected @('zh-TW','en') -Context "platform '$($platform.id)' base"
    if ($null -ne $platform.fanOut) {
        Get-ExactPropertyNames -Value $platform.fanOut -Expected @('baseTarget','rulesTarget','preserveRuleFileName') -Context "platform '$($platform.id)' fanOut"
    }
}
foreach ($module in @($contract.modules)) {
    Get-ExactPropertyNames -Value $module -Expected @('id','fileStem','platforms','triggers','invariants') -Context "module '$($module.id)'"
}
foreach ($baseInvariant in @($contract.baseInvariants)) {
    Get-ExactPropertyNames -Value $baseInvariant -Expected @('id','platforms') -Context "base invariant '$($baseInvariant.id)'"
}

$sourceRoot = [string]$contract.source.root
$hostByPlatform = @{
    'codex' = 'codex'
    'github-copilot' = 'copilot'
    'claude' = 'claude'
}
$outputs = New-Object System.Collections.Generic.List[object]
foreach ($platform in @($contract.platforms)) {
    $platformId = [string]$platform.id
    if (-not $hostByPlatform.ContainsKey($platformId)) { throw "Unsupported platform '$platformId'." }
    $targetHost = [string]$hostByPlatform[$platformId]
    foreach ($locale in @($contract.locales)) {
        $localeId = [string]$locale.id
        $baseSourceName = if ($localeId -ceq [string]$contract.primaryLocale) { 'base.md' } else { "base.$localeId.md" }
        $sourceRelative = "$sourceRoot/$baseSourceName"
        $sourcePath = Resolve-RepositoryPath -Root $root -RelativePath $sourceRelative
        $rendered = Expand-InstructionHostBlocks -Text (Get-NormalizedInstructionText -Path $sourcePath) -TargetHost $targetHost -SourcePath $sourceRelative
        $ruleRoot = ([string]$platform.rulesRoot).TrimEnd('/')
        $userSkillsRoot = ([string]$platform.userSkillsRoot).TrimEnd('/')
        $rendered = $rendered.Replace('{RULE_ROOT}/', ($ruleRoot + '/'))
        $rendered = $rendered.Replace('{USER_SKILLS_ROOT}/', ($userSkillsRoot + '/'))
        if ($rendered.Contains('{RULE_ROOT}') -or $rendered.Contains('{USER_SKILLS_ROOT}')) { throw "Unresolved instruction placeholder in '$sourceRelative'." }
        $targetProperty = $platform.base.PSObject.Properties[$localeId]
        if ($null -eq $targetProperty) { throw "Platform '$platformId' has no Base target for locale '$localeId'." }
        $outputs.Add([pscustomobject]@{ RelativePath = [string]$targetProperty.Value; Text = $rendered })

        foreach ($module in @($contract.modules | Where-Object { @($_.platforms) -ccontains $platformId })) {
            $ruleName = [string]$module.fileStem + [string]$locale.ruleSuffix
            $ruleSourceRelative = "$sourceRoot/AI-Rules/$ruleName"
            $ruleSourcePath = Resolve-RepositoryPath -Root $root -RelativePath $ruleSourceRelative
            $ruleText = Get-NormalizedInstructionText -Path $ruleSourcePath
            if ([regex]::IsMatch($ruleText, '<!--\s*(?:host:[^>]*|/host)\s*-->')) {
                throw [System.InvalidOperationException]::new("RuleHostBlockNotAllowed: '$ruleSourceRelative'. Host blocks are only allowed in Base source.")
            }
            $ruleText = $ruleText.Replace('{RULE_ROOT}/', ($ruleRoot + '/'))
            $ruleText = $ruleText.Replace('{USER_SKILLS_ROOT}/', ($userSkillsRoot + '/'))
            if ($ruleText.Contains('{RULE_ROOT}') -or $ruleText.Contains('{USER_SKILLS_ROOT}')) { throw "Unresolved instruction placeholder in '$ruleSourceRelative'." }
            $outputs.Add([pscustomobject]@{ RelativePath = "$ruleRoot/$ruleName"; Text = $ruleText })
        }
    }
}

$unexpectedArtifacts = New-Object System.Collections.Generic.List[string]
$inventoryDeclarations = @(
    [pscustomobject]@{
        RelativeRoot = "$sourceRoot/AI-Rules"
        ExpectedNames = @(
            foreach ($module in @($contract.modules)) {
                foreach ($locale in @($contract.locales)) {
                    [string]$module.fileStem + [string]$locale.ruleSuffix
                }
            }
        )
    }
)
foreach ($platform in @($contract.platforms)) {
    $platformId = [string]$platform.id
    $inventoryDeclarations += [pscustomobject]@{
        RelativeRoot = ([string]$platform.rulesRoot).TrimEnd('/')
        ExpectedNames = @(
            foreach ($module in @($contract.modules | Where-Object { @($_.platforms) -ccontains $platformId })) {
                foreach ($locale in @($contract.locales)) {
                    [string]$module.fileStem + [string]$locale.ruleSuffix
                }
            }
        )
    }
}
foreach ($inventory in $inventoryDeclarations) {
    $inventoryRoot = Resolve-RepositoryPath -Root $root -RelativePath ([string]$inventory.RelativeRoot)
    if (-not (Test-Path -LiteralPath $inventoryRoot -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $inventoryRoot -File -Filter '*.md')) {
        if (@($inventory.ExpectedNames) -cnotcontains [string]$file.Name) {
            $unexpectedArtifacts.Add(([string]$inventory.RelativeRoot + '/' + [string]$file.Name))
        }
    }
}
if ($unexpectedArtifacts.Count -gt 0) {
    foreach ($path in @($unexpectedArtifacts | Sort-Object -CaseSensitive)) {
        Write-Output "UnexpectedInstructionArtifact: $path"
    }
    throw 'UnexpectedInstructionArtifact: AI Instructions rule inventory contains files not declared by the contract.'
}

$drift = New-Object System.Collections.Generic.List[string]
foreach ($output in $outputs) {
    $targetPath = Resolve-RepositoryPath -Root $root -RelativePath ([string]$output.RelativePath)
    $expectedText = ([string]$output.Text).TrimEnd([char[]]@("`r", "`n")) + "`n"
    $expectedBytes = $script:Utf8NoBom.GetBytes($expectedText)
    $matches = $false
    if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        $actualBytes = [System.IO.File]::ReadAllBytes($targetPath)
        $matches = $actualBytes.Length -eq $expectedBytes.Length
        if ($matches) {
            for ($index = 0; $index -lt $expectedBytes.Length; $index++) {
                if ($actualBytes[$index] -ne $expectedBytes[$index]) { $matches = $false; break }
            }
        }
    }
    if (-not $matches) {
        $drift.Add([string]$output.RelativePath)
        if (-not $Check) {
            $directory = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $directory -Force)
            }
            [System.IO.File]::WriteAllBytes($targetPath, $expectedBytes)
        }
    }
}

if ($Check -and $drift.Count -gt 0) {
    foreach ($path in $drift) { Write-Output "AI Instructions drift: $path" }
    throw "AI Instructions are not generated from the declared common source."
}
if ($Check) {
    Write-Output "AI Instructions are current ($($outputs.Count) files)."
}
else {
    Write-Output "Generated $($outputs.Count) AI Instructions files; changed $($drift.Count)."
}
