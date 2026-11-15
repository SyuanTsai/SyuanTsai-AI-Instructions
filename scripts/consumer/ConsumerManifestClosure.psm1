# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ClosureDocumentExtensions = @('.md', '.markdown', '.txt', '.rst', '.adoc')
$script:ClosureDocumentNames = @('LICENSE', 'NOTICE', 'CHANGELOG')
$script:ClosureTemplatePaths = @(
    'scripts/Invoke-PinnedAuthority.ps1',
    '.github/workflows/consumer-gate.yml',
    '.github/workflows/consumer-gate-transition.yml'
)
$script:ClosureAliases = @{
    'gc'   = 'Get-Content'
    'cat'  = 'Get-Content'
    'type' = 'Get-Content'
    'gi'   = 'Get-Item'
    'ls'   = 'Get-ChildItem'
    'dir'  = 'Get-ChildItem'
    'gci'  = 'Get-ChildItem'
    'cp'   = 'Copy-Item'
    'copy' = 'Copy-Item'
    'mv'   = 'Move-Item'
    'move' = 'Move-Item'
    'ipmo' = 'Import-Module'
}
$script:ClosurePathConsumers = @{
    'Get-Content'               = @('Path', 'LiteralPath', 'FilePath')
    'Test-Path'                 = @('Path', 'LiteralPath', 'FilePath')
    'Get-Item'                  = @('Path', 'LiteralPath', 'FilePath')
    'Get-ChildItem'             = @('Path', 'LiteralPath', 'FilePath')
    'Resolve-Path'              = @('Path', 'LiteralPath', 'FilePath')
    'Set-Content'               = @('Path', 'LiteralPath', 'FilePath')
    'Out-File'                  = @('Path', 'LiteralPath', 'FilePath')
    'Import-PowerShellDataFile' = @('Path', 'LiteralPath', 'FilePath')
    'Copy-Item'                 = @('Path', 'LiteralPath', 'Destination')
    'Move-Item'                 = @('Path', 'LiteralPath', 'Destination')
    'Import-Module'             = @('Name')
}

function Get-ClosureSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Invoke-ClosureGitBytes {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int[]] $AllowedExitCodes = @(0)
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    [void] $start.ArgumentList.Add('-c')
    [void] $start.ArgumentList.Add('protocol.file.allow=never')
    [void] $start.ArgumentList.Add('-c')
    [void] $start.ArgumentList.Add('credential.helper=')
    [void] $start.ArgumentList.Add('-C')
    [void] $start.ArgumentList.Add($RepositoryRoot)
    foreach ($argument in $Arguments) {
        [void] $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void] $process.Start()
    $memory = [IO.MemoryStream]::new()
    $copy = $process.StandardOutput.BaseStream.CopyToAsync($memory)
    $errorRead = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $null = $copy.GetAwaiter().GetResult()
    $errorText = $errorRead.GetAwaiter().GetResult()
    $bytes = $memory.ToArray()
    $exitCode = $process.ExitCode
    $memory.Dispose()
    $process.Dispose()

    if ($exitCode -notin $AllowedExitCodes) {
        throw "git failed ($exitCode): $errorText"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Bytes    = $bytes
        Error    = $errorText
    }
}

function Invoke-ClosureGitText {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int[]] $AllowedExitCodes = @(0)
    )

    $result = Invoke-ClosureGitBytes -RepositoryRoot $RepositoryRoot -Arguments $Arguments `
        -AllowedExitCodes $AllowedExitCodes
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($result.Bytes)
    [pscustomobject]@{
        ExitCode = $result.ExitCode
        Text     = $text
        Error    = $result.Error
    }
}

function Get-ClosureTree {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $Commit
    )

    $tree = (Invoke-ClosureGitText -RepositoryRoot $RepositoryRoot `
            -Arguments @('rev-parse', "$Commit^{tree}")).Text.Trim()
    if ($tree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Git did not return a canonical tree identity.'
    }

    $listing = (Invoke-ClosureGitText -RepositoryRoot $RepositoryRoot `
            -Arguments @('ls-tree', '-r', '--full-tree', $Commit)).Text
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($line in @($listing -split "`n")) {
        if ([string]::IsNullOrEmpty($line)) {
            continue
        }
        if ($line -cnotmatch '^(?<mode>[0-9]{6}) (?<type>[a-z]+) (?<oid>[0-9a-f]{40})\t(?<path>.+)$') {
            throw "Git returned a malformed tree entry: $line"
        }
        $entries.Add([pscustomobject]@{
                Mode = $Matches.mode
                Type = $Matches.type
                Oid  = $Matches.oid
                Path = $Matches.path
            })
    }

    [pscustomobject]@{ Tree = $tree
     Entries = @($entries) }
}

function Get-ClosureBlobBytes {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $Oid
    )

    (Invoke-ClosureGitBytes -RepositoryRoot $RepositoryRoot -Arguments @('cat-file', 'blob', $Oid)).Bytes
}

function ConvertFrom-ClosureBlob {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    try {
        if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xfe) {
            return [pscustomobject]@{ IsText = $true
             Text = [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2) }
        }
        if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xfe -and $Bytes[1] -eq 0xff) {
            return [pscustomobject]@{ IsText = $true
             Text = [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2) }
        }
        $offset = if (
            $Bytes.Length -ge 3 -and
            $Bytes[0] -eq 0xef -and
            $Bytes[1] -eq 0xbb -and
            $Bytes[2] -eq 0xbf
        ) { 3 } else { 0 }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $offset, $Bytes.Length - $offset)
        [pscustomobject]@{ IsText = $true
         Text = $text }
    }
    catch {
        [pscustomobject]@{ IsText = $false
         Text = $null }
    }
}

function Test-ClosureDocumentPath {
    param([Parameter(Mandatory)][string] $Path)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in $script:ClosureDocumentExtensions) {
        return $true
    }
    [IO.Path]::GetFileName($Path) -cin $script:ClosureDocumentNames
}

function Get-ClosureLineColumn {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][int] $Offset
    )

    $line = 1
    $lineStart = 0
    for ($index = 0; $index -lt $Offset; $index++) {
        if ($Text[$index] -eq "`n") {
            $line++
            $lineStart = $index + 1
        }
    }
    [pscustomobject]@{ Line = $line
     Column = $Offset - $lineStart + 1 }
}

function Get-ClosureTokenMatches {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Target
    )

    $normalizedText = $Text.Replace('\', '/')
    $normalizedTarget = ConvertTo-ClosureNormalizedPath -Path $Target
    $escaped = [regex]::Escape($normalizedTarget)
    $pattern = "(?i)(?<![A-Za-z0-9._-])$escaped(?![A-Za-z0-9._-])"
    $results = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($match in @([regex]::Matches($normalizedText, $pattern))) {
        if ($seen.Add("$($match.Index):$($match.Length)")) {
            $results.Add([pscustomobject]@{ Index = $match.Index; Length = $match.Length; Value = $match.Value })
        }
    }

    if ([regex]::IsMatch($normalizedText, '(?:^|/)\.{1,2}(?:/|$)')) {
        foreach ($candidate in @([regex]::Matches($normalizedText, '(?i)[A-Za-z0-9._/-]+'))) {
            if (-not [regex]::IsMatch([string]$candidate.Value, '(?:^|/)\.{1,2}(?:/|$)')) {
                continue
            }
            $segments = [string]$candidate.Value -split '/'
            $segmentOffset = 0
            for ($index = 0; $index -lt $segments.Count; $index++) {
                $suffix = ([string[]]$segments[$index..($segments.Count - 1)]) -join '/'
                $normalizedSuffix = ConvertTo-ClosureNormalizedPath -Path $suffix
                if ($null -ne $normalizedSuffix -and $normalizedSuffix.Equals($normalizedTarget, [StringComparison]::OrdinalIgnoreCase)) {
                    $matchIndex = $candidate.Index + $segmentOffset
                    $matchLength = $candidate.Length - $segmentOffset
                    if ($seen.Add("${matchIndex}:${matchLength}")) {
                        $results.Add([pscustomobject]@{
                                Index  = $matchIndex
                                Length = $matchLength
                                Value  = $normalizedText.Substring($matchIndex, $matchLength)
                            })
                    }
                    break
                }
                $segmentOffset += $segments[$index].Length + 1
            }
        }
    }
    @($results | Sort-Object Index, Length)
}

function ConvertTo-ClosureNormalizedPath {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Path)

    $segments = [Collections.Generic.List[string]]::new()
    foreach ($segment in @($Path.Replace('\', '/') -split '/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.') {
            continue
        }
        if ($segment -eq '..') {
            if ($segments.Count -eq 0) {
                return $null
            }
            $segments.RemoveAt($segments.Count - 1)
            continue
        }
        $segments.Add($segment)
    }
    $segments -join '/'
}

function ConvertTo-ClosureFoldedValue {
    param([Parameter(Mandatory)] $Ast)

    if ($Ast -is [Management.Automation.Language.StringConstantExpressionAst]) {
        return [pscustomobject]@{ Values = @([string]$Ast.Value) }
    }
    if ($Ast -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
        $value = ([string]$Ast.Extent.Text).Trim('"')
        $value = [regex]::Replace($value, '\$(?:\{[^}]+\}|[A-Za-z_][A-Za-z0-9_:]*)', '<var>')
        return [pscustomobject]@{ Values = @($value) }
    }
    if ($Ast -is [Management.Automation.Language.VariableExpressionAst]) {
        return [pscustomobject]@{ Values = @('<var>') }
    }
    if ($Ast -is [Management.Automation.Language.ParenExpressionAst]) {
        return ConvertTo-ClosureFoldedValue $Ast.Pipeline
    }
    if ($Ast -is [Management.Automation.Language.PipelineAst]) {
        if ($Ast.PipelineElements.Count -ne 1) {
            return $null
        }
        return ConvertTo-ClosureFoldedValue $Ast.PipelineElements[0]
    }
    if ($Ast -is [Management.Automation.Language.CommandExpressionAst]) {
        return ConvertTo-ClosureFoldedValue $Ast.Expression
    }
    if ($Ast -is [Management.Automation.Language.StatementBlockAst]) {
        if ($Ast.Statements.Count -ne 1) {
            return $null
        }
        return ConvertTo-ClosureFoldedValue $Ast.Statements[0]
    }
    if ($Ast -is [Management.Automation.Language.ArrayExpressionAst]) {
        return ConvertTo-ClosureFoldedValue $Ast.SubExpression
    }
    if ($Ast -is [Management.Automation.Language.ArrayLiteralAst]) {
        $values = [Collections.Generic.List[string]]::new()
        foreach ($element in $Ast.Elements) {
            $folded = ConvertTo-ClosureFoldedValue $element
            if ($null -eq $folded) {
                return $null
            }
            foreach ($value in @($folded.Values)) {
                $values.Add([string]$value)
            }
        }
        return [pscustomobject]@{ Values = @($values) }
    }
    if ($Ast -is [Management.Automation.Language.UnaryExpressionAst] -and
        $Ast.TokenKind -eq [Management.Automation.Language.TokenKind]::Join) {
        $child = ConvertTo-ClosureFoldedValue $Ast.Child
        if ($null -eq $child) {
            return $null
        }
        return [pscustomobject]@{ Values = @( (@($child.Values) -join '') ) }
    }
    if ($Ast -is [Management.Automation.Language.BinaryExpressionAst]) {
        $left = ConvertTo-ClosureFoldedValue $Ast.Left
        $right = ConvertTo-ClosureFoldedValue $Ast.Right
        if ($null -eq $left -or $null -eq $right) {
            return $null
        }
        if ($Ast.Operator -eq [Management.Automation.Language.TokenKind]::Plus) {
            return [pscustomobject]@{ Values = @( (@($left.Values) -join '') + (@($right.Values) -join '') ) }
        }
        if ($Ast.Operator -eq [Management.Automation.Language.TokenKind]::Join) {
            if (@($right.Values).Count -ne 1) {
                return $null
            }
            return [pscustomobject]@{ Values = @( (@($left.Values) -join [string]$right.Values[0]) ) }
        }
        if ($Ast.Operator -eq [Management.Automation.Language.TokenKind]::Format) {
            if (@($left.Values).Count -ne 1) {
                return $null
            }
            try {
                return [pscustomobject]@{ Values = @( [string]::Format([string]$left.Values[0], [object[]]@($right.Values)) ) }
            }
            catch {
                return $null
            }
        }
        return $null
    }
    $null
}

function ConvertTo-ClosureFoldedText {
    param([Parameter(Mandatory)] $Ast)

    $foldedValue = ConvertTo-ClosureFoldedValue $Ast
    if ($null -ne $foldedValue) {
        return @($foldedValue.Values) -join ''
    }
    if ($Ast -is [Management.Automation.Language.CommandAst]) {
        $commandName = $Ast.GetCommandName()
        if ($commandName -ine 'Join-Path') {
            return $null
        }
        $parts = [Collections.Generic.List[string]]::new()
        foreach ($element in @($Ast.CommandElements | Select-Object -Skip 1)) {
            if ($element -is [Management.Automation.Language.CommandParameterAst]) {
                continue
            }
            $part = ConvertTo-ClosureFoldedText $element
            if ($null -eq $part) {
                return $null
            }
            $parts.Add($part.Trim('/', '\'))
        }
        return $parts -join '/'
    }
    if ($Ast -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
        if ([string] $Ast.Member.Value -ine 'Combine') {
            return $null
        }
        $typeName = [string] $Ast.Expression.TypeName.FullName
        if ($typeName -notin @('IO.Path', 'System.IO.Path')) {
            return $null
        }
        $parts = [Collections.Generic.List[string]]::new()
        foreach ($argument in @($Ast.Arguments)) {
            $part = ConvertTo-ClosureFoldedText $argument
            if ($null -eq $part) {
                return $null
            }
            $parts.Add($part.Trim('/', '\'))
        }
        return $parts -join '/'
    }
    $null
}

function Get-ClosureFoldCandidates {
    param([Parameter(Mandatory)] $RootAst)

    @($RootAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.BinaryExpressionAst] -or
                ($node -is [Management.Automation.Language.UnaryExpressionAst] -and
                $node.TokenKind -eq [Management.Automation.Language.TokenKind]::Join) -or
                $node -is [Management.Automation.Language.ExpandableStringExpressionAst] -or
                ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ieq 'Join-Path') -or
                ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                [string] $node.Member.Value -ieq 'Combine')
            }, $true))
}

function Get-ClosureStatementAst {
    param(
        [Parameter(Mandatory)] $RootAst,
        [Parameter(Mandatory)][int] $Offset
    )

    $statements = @($RootAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.StatementAst] -and
                $node.Extent.StartOffset -le $Offset -and
                $node.Extent.EndOffset -ge $Offset
            }, $true))
    @($statements | Sort-Object { $_.Extent.EndOffset - $_.Extent.StartOffset })[0]
}

function Test-ClosureAstHasTarget {
    param(
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)][string[]] $Targets
    )

    foreach ($target in $Targets) {
        if (@(Get-ClosureTokenMatches -Text $Ast.Extent.Text -Target $target).Count -gt 0) {
            return $true
        }
        $folded = ConvertTo-ClosureFoldedText $Ast
        if ($null -ne $folded -and @(Get-ClosureTokenMatches -Text $folded -Target $target).Count -gt 0) {
            return $true
        }
    }
    $false
}

function Get-ClosureCommandPathOperands {
    param([Parameter(Mandatory)][Management.Automation.Language.CommandAst] $Command)

    $commandName = $Command.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($commandName)) {
        return [pscustomobject]@{ FailClosed = $false
         Operands = @() }
    }
    if ($script:ClosureAliases.ContainsKey($commandName.ToLowerInvariant())) {
        $commandName = $script:ClosureAliases[$commandName.ToLowerInvariant()]
    }
    $consumerMatches = @($script:ClosurePathConsumers.Keys | Where-Object { $_ -ieq $commandName })
    if ($consumerMatches.Count -eq 0) {
        if ($commandName -ieq 'Invoke-Expression' -or $commandName -ieq 'iex') {
            return [pscustomobject]@{ FailClosed = $true
             Operands = @() }
        }
        return [pscustomobject]@{ FailClosed = $false
         Operands = @() }
    }
    $consumerKey = $consumerMatches[0]

    $allowedParameters = @($script:ClosurePathConsumers[$consumerKey])
    $operands = [Collections.Generic.List[object]]::new()
    $position = 0
    $positionalLimit = if ($consumerKey -in @('Copy-Item', 'Move-Item')) { 2 } else { 1 }
    $elements = @($Command.CommandElements | Select-Object -Skip 1)
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [Management.Automation.Language.CommandParameterAst]) {
            $canonical = @($allowedParameters | Where-Object { $_ -ieq $element.ParameterName })
            if ($canonical.Count -ne 1) {
                return [pscustomobject]@{ FailClosed = $true
                 Operands = @($operands) }
            }
            if ($index + 1 -ge $elements.Count -or
                $elements[$index + 1] -is [Management.Automation.Language.CommandParameterAst]) {
                return [pscustomobject]@{ FailClosed = $true
                 Operands = @($operands) }
            }
            $operands.Add($elements[$index + 1])
            $index++
            continue
        }
        if ($element.Extent.Text -match '^@[^\s]+$') {
            return [pscustomobject]@{ FailClosed = $true
             Operands = @($operands) }
        }
        if ($position -lt $positionalLimit) {
            $operands.Add($element)
        }
        $position++
    }
    [pscustomobject]@{ FailClosed = $false
     Operands = @($operands) }
}

function Test-ClosureStatementBlocksExemption {
    param(
        [Parameter(Mandatory)] $Statement,
        [Parameter(Mandatory)][string[]] $Targets
    )

    $commands = @($Statement.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($command in $commands) {
        if ($command.InvocationOperator -in @(
                [Management.Automation.Language.TokenKind]::Ampersand,
                [Management.Automation.Language.TokenKind]::Dot
            )) {
            $commandOperand = $command.CommandElements[0]
            if (-not (Test-ClosureAstHasTarget -Ast $commandOperand -Targets $Targets)) {
                $commandFolded = ConvertTo-ClosureFoldedText $commandOperand
                if ($null -eq $commandFolded -or $commandFolded.Contains('<var>', [StringComparison]::Ordinal)) {
                    return $true
                }
            }
        }
        $mapping = Get-ClosureCommandPathOperands $command
        if ($mapping.FailClosed) {
            return $true
        }
        foreach ($operand in $mapping.Operands) {
            if (Test-ClosureAstHasTarget -Ast $operand -Targets $Targets) {
                continue
            }
            $folded = ConvertTo-ClosureFoldedText $operand
            if ($null -eq $folded -or $folded.Contains('<var>', [StringComparison]::Ordinal)) {
                return $true
            }
        }
    }

    $invocations = @($Statement.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true))
    foreach ($invocation in $invocations) {
        $member = [string] $invocation.Member.Value
        $typeName = if ($invocation.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
            [string] $invocation.Expression.TypeName.FullName
        }
        else {
            ''
        }
        $isConsumer = (
            $typeName -in @('IO.File', 'System.IO.File', 'IO.Directory', 'System.IO.Directory') -or
            ($typeName -eq 'System.Management.Automation.Language.Parser' -and $member -eq 'ParseFile')
        )
        if (-not $isConsumer -or $invocation.Arguments.Count -eq 0) {
            continue
        }
        $operand = $invocation.Arguments[0]
        if (Test-ClosureAstHasTarget -Ast $operand -Targets $Targets) {
            continue
        }
        $folded = ConvertTo-ClosureFoldedText $operand
        if ($null -eq $folded -or $folded.Contains('<var>', [StringComparison]::Ordinal)) {
            return $true
        }
    }
    $false
}

function Get-ClosureDynamicAdvisories {
    param(
        [Parameter(Mandatory)] $RootAst,
        [Parameter(Mandatory)][string] $File
    )

    $items = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $commands = @($RootAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($command in $commands) {
        if ($command.InvocationOperator -in @(
                [Management.Automation.Language.TokenKind]::Ampersand,
                [Management.Automation.Language.TokenKind]::Dot
            )) {
            $commandOperand = $command.CommandElements[0]
            $commandFolded = ConvertTo-ClosureFoldedText $commandOperand
            if ($null -eq $commandFolded -or $commandFolded.Contains('<var>', [StringComparison]::Ordinal)) {
                $key = "$($commandOperand.Extent.StartLineNumber):$($commandOperand.Extent.StartColumnNumber)"
                if ($seen.Add($key)) {
                    $items.Add([pscustomobject][ordered]@{
                            kind = 'dynamic-reference'
                            file = $File
                            line = $commandOperand.Extent.StartLineNumber
                            column = $commandOperand.Extent.StartColumnNumber
                            reference = $commandOperand.Extent.Text
                            targetPath = $null
                        })
                }
            }
        }
        $mapping = Get-ClosureCommandPathOperands $command
        foreach ($operand in $mapping.Operands) {
            $folded = ConvertTo-ClosureFoldedText $operand
            if ($null -ne $folded -and -not $folded.Contains('<var>', [StringComparison]::Ordinal)) {
                continue
            }
            $key = "$($operand.Extent.StartLineNumber):$($operand.Extent.StartColumnNumber)"
            if ($seen.Add($key)) {
                $items.Add([pscustomobject][ordered]@{
                        kind       = 'dynamic-reference'
                        file       = $File
                        line       = $operand.Extent.StartLineNumber
                        column     = $operand.Extent.StartColumnNumber
                        reference  = $operand.Extent.Text
                        targetPath = $null
                    })
            }
        }
    }
    $invocations = @($RootAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true))
    foreach ($invocation in $invocations) {
        $member = [string]$invocation.Member.Value
        $typeName = if ($invocation.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
            [string]$invocation.Expression.TypeName.FullName
        }
        else {
            ''
        }
        $isConsumer = (
            $typeName -in @('IO.File', 'System.IO.File', 'IO.Directory', 'System.IO.Directory') -or
            ($typeName -eq 'System.Management.Automation.Language.Parser' -and $member -eq 'ParseFile')
        )
        if (-not $isConsumer -or $invocation.Arguments.Count -eq 0) {
            continue
        }
        $operand = $invocation.Arguments[0]
        $folded = ConvertTo-ClosureFoldedText $operand
        if ($null -ne $folded -and -not $folded.Contains('<var>', [StringComparison]::Ordinal)) {
            continue
        }
        $key = "$($operand.Extent.StartLineNumber):$($operand.Extent.StartColumnNumber)"
        if ($seen.Add($key)) {
            $items.Add([pscustomobject][ordered]@{
                    kind = 'dynamic-reference'
                    file = $File
                    line = $operand.Extent.StartLineNumber
                    column = $operand.Extent.StartColumnNumber
                    reference = $operand.Extent.Text
                    targetPath = $null
                })
        }
    }
    @($items)
}

function New-ClosureCounts {
    [ordered]@{
        scannedFiles           = 0
        legacyReference        = 0
        parseError             = 0
        templateIntegrity      = 0
        splitSourcePresent     = 0
        updateTestsOutcome     = 0
        staleExemption         = 0
        exemptedReference      = 0
        dynamicReference       = 0
        documentationReference = 0
        binary                 = 0
    }
}

function Get-ConsumerManifestClosure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][ValidateSet('inventory', 'conversion')][string] $Stage,
        [string] $InventoryCommit,
        [Parameter(Mandatory)][string] $Manifest,
        [Parameter(Mandatory)][string] $RepositoryId,
        [Parameter(Mandatory)][string] $AuthorityRoot
    )

    if ($Commit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Commit must be a full lowercase Git object ID.'
    }
    if ($Stage -eq 'conversion' -and $InventoryCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Conversion requires InventoryCommit.'
    }
    $manifestValue = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json -Depth 100
    $entries = @($manifestValue.repositories | Where-Object { [string] $_.id -ceq $RepositoryId })
    if ($entries.Count -ne 1) {
        throw 'RepositoryId has no unique manifest entry.'
    }
    $entry = $entries[0]
    if ($Stage -eq 'conversion' -and [string] $entry.inventoryCommit -cne $InventoryCommit) {
        throw 'InventoryCommit differs from the manifest.'
    }

    $tree = Get-ClosureTree -RepositoryRoot $RepositoryRoot -Commit $Commit
    if ($Stage -eq 'inventory' -and [string] $entry.inventoryTree -cne $tree.Tree) {
        throw 'Inventory tree differs from the manifest.'
    }
    $inventoryTree = if ($Stage -eq 'conversion') {
        Get-ClosureTree -RepositoryRoot $RepositoryRoot -Commit $InventoryCommit
    }
    else {
        $tree
    }
    $entryByPath = @{}
    foreach ($item in @($entry.files)) {
        $entryByPath[[string] $item.path] = $item
    }
    $inventoryByPath = @{}
    foreach ($item in @($inventoryTree.Entries)) {
        $inventoryByPath[[string] $item.Path] = $item
    }
    $candidateByPath = @{}
    foreach ($item in @($tree.Entries)) {
        $candidateByPath[[string] $item.Path] = $item
    }

    $legacyRecords = @($entry.files | Where-Object {
            [string] $_.disposition -in @('delete', 'update-tests', 'split')
        })
    $legacyTargets = @($legacyRecords | ForEach-Object { [string] $_.path })
    $dispositionByTarget = @{}
    foreach ($record in $legacyRecords) {
        $dispositionByTarget[[string] $record.path] = [string] $record.disposition
    }

    $violations = [Collections.Generic.List[object]]::new()
    $advisories = [Collections.Generic.List[object]]::new()
    $counts = New-ClosureCounts
    if ($Stage -eq 'conversion') {
        foreach ($record in @($entry.files | Where-Object { [string] $_.disposition -eq 'split' })) {
            if ($candidateByPath.ContainsKey([string] $record.path)) {
                $violations.Add([pscustomobject][ordered]@{
                        kind = 'split-source-present'
                        file = [string] $record.path
                    })
                $counts.splitSourcePresent++
            }
        }
        foreach ($record in @($entry.files | Where-Object { [string] $_.disposition -eq 'update-tests' })) {
            $present = $candidateByPath.ContainsKey([string] $record.path)
            $actual = if (-not $present) { 'missing' } elseif (
                $inventoryByPath.ContainsKey([string] $record.path) -and
                $inventoryByPath[[string] $record.path].Oid -ceq $candidateByPath[[string] $record.path].Oid
            ) { 'unchanged' } else { 'rewritten' }
            $expected = [string] $record.expectedOutcome
            $valid = ($expected -eq 'delete' -and -not $present) -or
            ($expected -eq 'rewrite' -and $present -and $actual -eq 'rewritten')
            if (-not $valid) {
                $violations.Add([pscustomobject][ordered]@{
                        kind            = 'update-tests-outcome'
                        file            = [string] $record.path
                        expectedOutcome = $expected
                        actual          = $actual
                    })
                $counts.updateTestsOutcome++
            }
        }
    }

    $scanPaths = if ($Stage -eq 'inventory') {
        $requiredPaths = @($entry.requiredRepositoryChecks | ForEach-Object { [string] $_.path })
        @($entry.files | Where-Object { [string] $_.disposition -eq 'retain' } |
                ForEach-Object { [string] $_.path }) + $requiredPaths | Sort-Object -Unique
    }
    else {
        @($tree.Entries | Where-Object { $_.Mode -in @('100644', '100755') } |
                ForEach-Object { [string] $_.Path })
    }

    $exemptions = if ($null -ne $entry.PSObject.Properties['literalReferenceExemptions']) {
        @($entry.literalReferenceExemptions)
    }
    else {
        @()
    }
    $matchedExemptions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $scanPaths) {
        if (-not $candidateByPath.ContainsKey($path)) {
            continue
        }
        $treeEntry = $candidateByPath[$path]
        if ($treeEntry.Mode -notin @('100644', '100755')) {
            continue
        }
        if ($Stage -eq 'conversion' -and $path -in $script:ClosureTemplatePaths) {
            $authorityRelativePath = if ($path -eq 'scripts/Invoke-PinnedAuthority.ps1') {
                'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
            }
            else {
                'consumer/workflows/' + [IO.Path]::GetFileName($path)
            }
            $authorityPath = Join-Path $AuthorityRoot $authorityRelativePath
            $expected = if (Test-Path -LiteralPath $authorityPath -PathType Leaf) {
                (Get-FileHash -LiteralPath $authorityPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            else { $null }
            $bytes = Get-ClosureBlobBytes -RepositoryRoot $RepositoryRoot -Oid $treeEntry.Oid
            $actual = Get-ClosureSha256 $bytes
            if ($null -eq $expected -or $actual -cne $expected) {
                $violations.Add([pscustomobject][ordered]@{
                        kind           = 'template-integrity'
                        file           = $path
                        expectedSha256 = $expected
                        actualSha256   = $actual
                    })
                $counts.templateIntegrity++
            }
            continue
        }

        $counts.scannedFiles++
        $bytes = Get-ClosureBlobBytes -RepositoryRoot $RepositoryRoot -Oid $treeEntry.Oid
        $decoded = ConvertFrom-ClosureBlob $bytes
        if (-not $decoded.IsText) {
            $advisories.Add([pscustomobject][ordered]@{
                    kind       = 'binary'
                    file       = $path
                    line       = $null
                    column     = $null
                    reference  = $null
                    targetPath = $null
                })
            $counts.binary++
            continue
        }

        $text = [string] $decoded.Text
        $isDocument = Test-ClosureDocumentPath $path
        $isPowerShell = [IO.Path]::GetExtension($path) -in @('.ps1', '.psm1', '.psd1')
        $rootAst = $null
        if ($isPowerShell) {
            $tokens = $null
            $parseErrors = $null
            $rootAst = [Management.Automation.Language.Parser]::ParseInput(
                $text,
                $path,
                [ref] $tokens,
                [ref] $parseErrors
            )
            foreach ($parseError in @($parseErrors)) {
                $violations.Add([pscustomobject][ordered]@{
                        kind    = 'parse-error'
                        file    = $path
                        line    = $parseError.Extent.StartLineNumber
                        column  = $parseError.Extent.StartColumnNumber
                        message = $parseError.Message
                    })
                $counts.parseError++
            }
        }
        elseif ([IO.Path]::GetExtension($path) -ieq '.json') {
            try {
                $null = $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop
            }
            catch {
                $violations.Add([pscustomobject][ordered]@{
                        kind    = 'parse-error'
                        file    = $path
                        line    = 1
                        column  = 1
                        message = $_.Exception.Message
                    })
                $counts.parseError++
            }
        }

        $occurrences = [Collections.Generic.List[object]]::new()
        $identity = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($target in $legacyTargets) {
            foreach ($match in @(Get-ClosureTokenMatches -Text $text -Target $target)) {
                $position = Get-ClosureLineColumn -Text $text -Offset $match.Index
                $key = "$($position.Line):$($position.Column):1:$target"
                if ($identity.Add($key)) {
                    $occurrences.Add([pscustomobject]@{
                            Line              = $position.Line
                            Column            = $position.Column
                            OccurrenceOrdinal = 1
                            Reference         = $match.Value
                            TargetPath        = $target
                            Offset            = $match.Index
                            Ast               = $null
                        })
                }
            }
        }
        if ($null -ne $rootAst) {
            $foldCandidates = @(Get-ClosureFoldCandidates $rootAst)
            foreach ($target in $legacyTargets) {
                $foldResults = [Collections.Generic.List[object]]::new()
                $foldIdentity = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($foldAst in $foldCandidates) {
                    $folded = ConvertTo-ClosureFoldedText $foldAst
                    if ($null -eq $folded) {
                        continue
                    }
                    $foldedMatches = @(Get-ClosureTokenMatches -Text $folded -Target $target)
                    if ($foldedMatches.Count -eq 0) {
                        continue
                    }
                    $extentKey = "$($foldAst.Extent.StartOffset):$($foldAst.Extent.EndOffset)"
                    if ($foldIdentity.Add($extentKey)) {
                        $foldResults.Add([pscustomobject]@{ Ast = $foldAst; Matches = $foldedMatches })
                    }
                }

                $outermost = @($foldResults | Where-Object {
                        $candidate = $_.Ast
                        @($foldResults | Where-Object {
                                $_.Ast.Extent.StartOffset -le $candidate.Extent.StartOffset -and
                                $_.Ast.Extent.EndOffset -ge $candidate.Extent.EndOffset -and
                                ($_.Ast.Extent.StartOffset -lt $candidate.Extent.StartOffset -or
                                $_.Ast.Extent.EndOffset -gt $candidate.Extent.EndOffset)
                            }).Count -eq 0
                    })
                $rawForTarget = @($occurrences | Where-Object {
                        $null -eq $_.Ast -and $_.TargetPath -ceq $target
                    })
                foreach ($foldResult in $outermost) {
                    $foldAst = $foldResult.Ast
                    $foldedMatches = @($foldResult.Matches)
                    $rawInExtent = @($rawForTarget | Where-Object {
                            $_.Offset -ge $foldAst.Extent.StartOffset -and
                            $_.Offset -lt $foldAst.Extent.EndOffset
                        }).Count
                    for ($ordinal = $rawInExtent + 1; $ordinal -le $foldedMatches.Count; $ordinal++) {
                        $key = "$($foldAst.Extent.StartLineNumber):$($foldAst.Extent.StartColumnNumber):${ordinal}:$target"
                        if ($identity.Add($key)) {
                            $occurrences.Add([pscustomobject]@{
                                    Line              = $foldAst.Extent.StartLineNumber
                                    Column            = $foldAst.Extent.StartColumnNumber
                                    OccurrenceOrdinal = $ordinal
                                    Reference         = $foldedMatches[$ordinal - 1].Value
                                    TargetPath        = $target
                                    Offset            = $foldAst.Extent.StartOffset
                                    Ast               = $foldAst
                                })
                        }
                    }
                }
            }
        }

        foreach ($occurrence in $occurrences) {
            if ($isDocument) {
                $advisories.Add([pscustomobject][ordered]@{
                        kind       = 'documentation-reference'
                        file       = $path
                        line       = $occurrence.Line
                        column     = $occurrence.Column
                        reference  = $occurrence.Reference
                        targetPath = $occurrence.TargetPath
                    })
                $counts.documentationReference++
                continue
            }
            $matchingExemption = @($exemptions | Where-Object {
                    [string] $_.file -ceq $path -and
                    [string] $_.blobOid -ceq [string] $treeEntry.Oid -and
                    [int] $_.line -eq $occurrence.Line -and
                    [int] $_.column -eq $occurrence.Column -and
                    [int] $_.occurrenceOrdinal -eq $occurrence.OccurrenceOrdinal -and
                    [string] $_.targetPath -ceq $occurrence.TargetPath
                })
            $isExempt = $matchingExemption.Count -eq 1
            if ($isExempt -and $null -ne $rootAst) {
                $statement = Get-ClosureStatementAst -RootAst $rootAst -Offset $occurrence.Offset
                if ($null -ne $statement -and (
                        Test-ClosureStatementBlocksExemption -Statement $statement -Targets $legacyTargets
                    )) {
                    $isExempt = $false
                }
            }
            if ($isExempt) {
                $exemption = $matchingExemption[0]
                [void] $matchedExemptions.Add((
                        "$($exemption.file):$($exemption.blobOid):$($exemption.line):" +
                        "$($exemption.column):$($exemption.occurrenceOrdinal):$($exemption.targetPath)"
                    ))
                $counts.exemptedReference++
                continue
            }
            $violations.Add([pscustomobject][ordered]@{
                    kind              = 'legacy-reference'
                    file              = $path
                    line              = $occurrence.Line
                    column            = $occurrence.Column
                    occurrenceOrdinal = $occurrence.OccurrenceOrdinal
                    reference         = $occurrence.Reference
                    targetPath        = $occurrence.TargetPath
                    targetDisposition = $dispositionByTarget[$occurrence.TargetPath]
                })
            $counts.legacyReference++
        }

        if ($null -ne $rootAst) {
            foreach ($advisory in @(Get-ClosureDynamicAdvisories -RootAst $rootAst -File $path)) {
                $advisories.Add($advisory)
                $counts.dynamicReference++
            }
        }
    }

    if ($Stage -eq 'inventory') {
        foreach ($exemption in $exemptions) {
            $key = "$($exemption.file):$($exemption.blobOid):$($exemption.line):" +
            "$($exemption.column):$($exemption.occurrenceOrdinal):$($exemption.targetPath)"
            if (-not $matchedExemptions.Contains($key)) {
                $violations.Add([pscustomobject][ordered]@{
                        kind              = 'stale-exemption'
                        file              = [string] $exemption.file
                        blobOid           = [string] $exemption.blobOid
                        line              = [int] $exemption.line
                        column            = [int] $exemption.column
                        occurrenceOrdinal = [int] $exemption.occurrenceOrdinal
                        targetPath        = [string] $exemption.targetPath
                    })
                $counts.staleExemption++
            }
        }
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        repositoryId  = $RepositoryId
        stage         = $Stage
        commit        = $Commit
        tree          = $tree.Tree
        result        = if ($violations.Count -eq 0) { 'PASS' } else { 'FAILED' }
        violations    = @($violations)
        advisories    = @($advisories)
        counts        = [pscustomobject] $counts
    }
}

Export-ModuleMember -Function Get-ConsumerManifestClosure
