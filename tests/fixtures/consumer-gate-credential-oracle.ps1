# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4

function Get-OracleBaseVariableName($Ast) {
    if ($null -eq $Ast) { return $null }
    if ($Ast -is [Management.Automation.Language.VariableExpressionAst]) {
        return [string]$Ast.VariablePath.UserPath
    }
    $variables = @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true))
    if ($variables.Count -eq 0) { return $null }
    [string]$variables[0].VariablePath.UserPath
}

function Get-OracleOwningFunction($Ast) {
    $cursor = $Ast
    while ($null -ne $cursor) {
        if ($cursor -is [Management.Automation.Language.FunctionDefinitionAst]) { return $cursor }
        $cursor = $cursor.Parent
    }
    $null
}

function Test-OracleNodeInScope($Node, $Function) {
    $owner = Get-OracleOwningFunction $Node
    if ($null -eq $Function) { return $null -eq $owner }
    [object]::ReferenceEquals($owner, $Function)
}

function Get-OracleStatement($Ast) {
    $cursor = $Ast
    $statement = $null
    while ($null -ne $cursor) {
        if ($cursor -is [Management.Automation.Language.StatementAst]) {
            $statement = $cursor
            if ($cursor.Parent -is [Management.Automation.Language.StatementBlockAst] -or
                $cursor.Parent -is [Management.Automation.Language.NamedBlockAst]) {
                return $cursor
            }
        }
        $cursor = $cursor.Parent
    }
    $statement
}

function Get-ConsumerCredentialOracle([hashtable]$Sources) {
    $states = [Collections.Generic.List[object]]::new()
    foreach ($sourceEntry in $Sources.GetEnumerator()) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput([string]$sourceEntry.Value, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) { throw "Credential oracle could not parse $($sourceEntry.Key)." }
        $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($function in $functions) {
            $states.Add([pscustomobject]@{
                    Source = [string]$sourceEntry.Key
                    Ast = $ast
                    Function = $function
                    Name = [string]$function.Name
                    Root = $function.Body
                    Tainted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                })
        }
        if ([string]$sourceEntry.Key -in @('consumer/bootstrap/Invoke-PinnedAuthority.ps1','scripts/consumer/Invoke-ConsumerSourceGate.ps1')) {
            $states.Add([pscustomobject]@{
                    Source = [string]$sourceEntry.Key
                    Ast = $ast
                    Function = $null
                    Name = '<script>'
                    Root = $ast
                    Tainted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                })
        }
    }

    foreach ($state in $states) {
        if ($null -ne $state.Function) {
            foreach ($parameter in @($state.Function.Parameters)) {
                if ([string]$parameter.Name.VariablePath.UserPath -ieq 'Token') { [void]$state.Tainted.Add('Token') }
            }
        }
        $assignments = @($state.Root.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true) |
                Where-Object { Test-OracleNodeInScope $_ $state.Function })
        foreach ($assignment in $assignments) {
            $left = Get-OracleBaseVariableName $assignment.Left
            if ([string]::IsNullOrWhiteSpace($left)) { continue }
            $rightText = [string]$assignment.Right.Extent.Text
            $credentialRead = $rightText -match '(?i)\$env:(STANDARD_VALIDATION_GITHUB_API_TOKEN|GITHUB_TOKEN|GH_TOKEN)' -or
                $rightText -match '(?i)GetEnvironmentVariable\s*\(\s*[''"](STANDARD_VALIDATION_GITHUB_API_TOKEN|GITHUB_TOKEN|GH_TOKEN)[''"]' -or
                $rightText -match 'GetEnvironmentVariables\s*\(\s*[''"]Process[''"]\s*\)'
            $authorizationWrite = [string]$assignment.Left.Extent.Text -match '(?i)\.Authorization$'
            $bootstrapEnvironmentCopy = $state.Name -ceq 'Invoke-ConsumerGateProcess' -and
                $rightText -match 'GetEnvironmentVariable\s*\(\s*\$name'
            $credentialContent = $state.Name -ceq 'Assert-GateCredentialAbsent' -and $left -ceq 'content' -and
                $rightText -match 'ReadAllBytes'
            $tokenVariable = $rightText -match '(?i)Get-Variable\s+token(?:\s|$)'
            if ($credentialRead -or $authorizationWrite -or $bootstrapEnvironmentCopy -or $credentialContent -or $tokenVariable) {
                [void]$state.Tainted.Add($left)
            }
        }
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($state in $states) {
            $assignments = @($state.Root.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true) |
                    Where-Object { Test-OracleNodeInScope $_ $state.Function })
            foreach ($assignment in $assignments) {
                $left = Get-OracleBaseVariableName $assignment.Left
                if ([string]::IsNullOrWhiteSpace($left) -or $state.Tainted.Contains($left)) { continue }
                $rightVariables = @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
                        ForEach-Object { [string]$_.VariablePath.UserPath })
                $hasTaintedInput = @($rightVariables | Where-Object { $state.Tainted.Contains($_) }).Count -gt 0
                $rightText = [string]$assignment.Right.Extent.Text
                $preservesWholeValue = $rightText -match '^\s*(?:\[[^\]]+\]\s*)?\$[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]+\])?\s*$' -or
                    $rightText -match '(?i)\.(?:ReadAsStreamAsync|ToArray|ReadToEndAsync|GetResult|GetString|GetBytes|Replace|SendAsync)\s*\('
                if ($rightText -match '(?i)\.ReadAsync\s*\(') { $preservesWholeValue = $false }
                $flows = $hasTaintedInput -and $preservesWholeValue
                $commands = @($assignment.Right.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
                if ($commands.Count -gt 0 -and [string]$assignment.Right.Extent.Text -notmatch '(?i)Get-Variable\s+token') {
                    $flows = $false
                }
                if ($flows) {
                    [void]$state.Tainted.Add($left)
                    $changed = $true
                }
            }
            $memberCalls = @($state.Root.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
                    Where-Object { Test-OracleNodeInScope $_ $state.Function })
            foreach ($memberCall in $memberCalls) {
                $receiver = Get-OracleBaseVariableName $memberCall.Expression
                if ([string]::IsNullOrWhiteSpace($receiver)) { continue }
                $argumentVariables = @($memberCall.Arguments | Where-Object { $null -ne $_ } | ForEach-Object {
                        $_.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true)
                    } | ForEach-Object { [string]$_.VariablePath.UserPath })
                if (@($argumentVariables | Where-Object { $state.Tainted.Contains($_) }).Count -gt 0 -and
                    [string]$memberCall.Member.Value -in @('TryAddWithoutValidation','Write','Add')) {
                    if ($state.Tainted.Add($receiver)) { $changed = $true }
                }
                if ($state.Tainted.Contains($receiver) -and [string]$memberCall.Member.Value -ceq 'ReadAsync' -and
                    @($memberCall.Arguments).Count -gt 0) {
                    $buffer = Get-OracleBaseVariableName $memberCall.Arguments[0]
                    if (-not [string]::IsNullOrWhiteSpace($buffer) -and $state.Tainted.Add($buffer)) { $changed = $true }
                }
            }
        }

        foreach ($caller in $states) {
            $commands = @($caller.Root.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
                    Where-Object { Test-OracleNodeInScope $_ $caller.Function })
            foreach ($command in $commands) {
                $callee = @($states | Where-Object { $_.Name -ceq [string]$command.GetCommandName() })
                if ($callee.Count -ne 1) { continue }
                $parameters = @($callee[0].Function.Parameters)
                $position = 0
                for ($index = 1; $index -lt $command.CommandElements.Count; $index++) {
                    $element = $command.CommandElements[$index]
                    if ($element -is [Management.Automation.Language.CommandParameterAst]) { continue }
                    if ($position -ge $parameters.Count) { break }
                    $variables = @($element.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
                            ForEach-Object { [string]$_.VariablePath.UserPath })
                    $parameterName = [string]$parameters[$position].Name.VariablePath.UserPath
                    if ($parameterName -in @('Token','Headers') -and
                        @($variables | Where-Object { $caller.Tainted.Contains($_) }).Count -gt 0) {
                        if ($callee[0].Tainted.Add($parameterName)) { $changed = $true }
                    }
                    $position++
                }
            }
        }
    }

    $holders = [Collections.Generic.List[object]]::new()
    foreach ($state in $states) {
        foreach ($variable in @($state.Tainted | Sort-Object)) {
            $holders.Add([pscustomobject]@{ Source=$state.Source; Function=$state.Name; Variable=[string]$variable })
        }
    }

    $holderScopes = @($states | Where-Object { $_.Tainted.Count -gt 0 })
    $cleanups = [Collections.Generic.List[object]]::new()
    foreach ($state in $holderScopes) {
        $candidates = @($state.Root.FindAll({ param($node)
                    if ($node -is [Management.Automation.Language.AssignmentStatementAst]) {
                        return [string]$node.Right.Extent.Text -ceq '$null'
                    }
                    if ($node -isnot [Management.Automation.Language.PipelineAst]) { return $false }
                    $text = [string]$node.Extent.Text
                    $text -match '(?i)^\s*Remove-Variable(?:\s|$)' -or $text -match '\.Dispose\s*\(' -or
                        $text -match '\.Remove\s*\(' -or $text -match '\.Clear\s*\(' -or
                        $text -match 'SetEnvironmentVariable\s*\([^\r\n]*\$null'
                }, $true) | Where-Object { Test-OracleNodeInScope $_ $state.Function })
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($candidate in $candidates) {
            $statement = Get-OracleStatement $candidate
            if ($null -eq $statement) { continue }
            $identity = "$($statement.Extent.StartOffset):$($statement.Extent.EndOffset)"
            if (-not $seen.Add($identity)) { continue }
            $text = ([string]$statement.Extent.Text).Trim() -replace '\s+', ' '
            $shape = if ($statement -is [Management.Automation.Language.AssignmentStatementAst]) { 'null' }
                elseif ($text -match '(?i)^Remove-Variable(?:\s|$)') { 'remove-variable' }
                elseif ($text -match '\.Dispose\s*\(') { 'dispose' }
                elseif ($text -match 'SetEnvironmentVariable\s*\(') { 'environment-null' }
                elseif ($text -match '\.Clear\s*\(') { 'clear' }
                else { 'remove' }
            $targets = @()
            if ($shape -ceq 'remove-variable') {
                $targetText = $text -replace '(?i)^Remove-Variable\s+', '' -replace '(?i)\s+-ErrorAction\s+.*$', ''
                $targets = @($targetText -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            elseif ($shape -cne 'environment-null' -and $text -match '\$([A-Za-z_][A-Za-z0-9_]*)') {
                $targets = @($Matches[1])
            }
            if ($shape -cne 'environment-null' -and @($targets | Where-Object { $state.Tainted.Contains($_) }).Count -eq 0) {
                continue
            }
            $finally = $false
            $cursor = $statement.Parent
            while ($null -ne $cursor) {
                if ($cursor -is [Management.Automation.Language.StatementBlockAst] -and
                    $cursor.Parent -is [Management.Automation.Language.TryStatementAst] -and
                    [object]::ReferenceEquals($cursor.Parent.Finally, $cursor)) { $finally = $true; break }
                if ($cursor -is [Management.Automation.Language.FunctionDefinitionAst]) { break }
                $cursor = $cursor.Parent
            }
            if ($shape -ceq 'null' -and -not $finally -and $targets.Count -eq 1) {
                $targetName = [string]$targets[0]
                $priorReferences = @($state.Root.FindAll({ param($node)
                            $node -is [Management.Automation.Language.VariableExpressionAst] -and
                            [string]$node.VariablePath.UserPath -ieq $targetName
                        }, $true) | Where-Object {
                        (Test-OracleNodeInScope $_ $state.Function) -and
                        $_.Extent.StartOffset -lt $statement.Extent.StartOffset -and
                        -not ($_.Extent.StartOffset -ge $statement.Extent.StartOffset -and $_.Extent.EndOffset -le $statement.Extent.EndOffset)
                    })
                if ($priorReferences.Count -eq 0) { continue }
            }
            $cleanups.Add([pscustomobject]@{
                    Source=$state.Source;Function=$state.Name;Shape=$shape;Text=$text
                    Line=[int]$statement.Extent.StartLineNumber;Column=[int]$statement.Extent.StartColumnNumber
                    StartOffset=[int]$statement.Extent.StartOffset;EndOffset=[int]$statement.Extent.EndOffset
                    InFinally=$finally;Targets=@($targets)
                })
        }
    }
    [pscustomobject]@{ States=@($states); Holders=@($holders | Sort-Object Source,Function,Variable); Cleanups=@($cleanups | Sort-Object Source,Function,StartOffset) }
}

function Get-ConsumerGateSeamOracle([hashtable]$Sources) {
    $formal = @('CONSUMER_GATE_ARTIFACT_PATHS','CONSUMER_GATE_EVENT_REPOSITORY','CONSUMER_GATE_TEST_TEMP_ROOT')
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($sourceEntry in $Sources.GetEnumerator()) {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput([string]$sourceEntry.Value,[ref]$tokens,[ref]$errors)
        if(@($errors).Count-ne0){throw "Seam oracle could not parse $($sourceEntry.Key)."}
        foreach($variable in @($ast.FindAll({param($node)
                        $node-is[Management.Automation.Language.VariableExpressionAst]-and
                        ([string]$node.VariablePath.UserPath).StartsWith('env:CONSUMER_GATE_',[StringComparison]::OrdinalIgnoreCase)
                    },$true))){
            $name=([string]$variable.VariablePath.UserPath).Substring(4).ToUpperInvariant()
            if($formal-ccontains$name){continue}
            $statement=Get-OracleStatement $variable
            $function=Get-OracleOwningFunction $variable
            $entries.Add([pscustomobject]@{Source=[string]$sourceEntry.Key;Function=if($null-eq$function){'<script>'}else{$function.Name}
                    Name=$name;Kind='env';Line=$variable.Extent.StartLineNumber;StartOffset=$statement.Extent.StartOffset;EndOffset=$statement.Extent.EndOffset})
        }
        foreach($call in @($ast.FindAll({param($node)
                        $node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and
                        [string]$node.Member.Value-ceq'GetEnvironmentVariable'
                    },$true))){
            if(@($call.Arguments).Count-lt1-or$call.Arguments[0]-isnot[Management.Automation.Language.StringConstantExpressionAst]){continue}
            $name=([string]$call.Arguments[0].Value).ToUpperInvariant()
            if(-not$name.StartsWith('CONSUMER_GATE_',[StringComparison]::Ordinal)-or$formal-ccontains$name){continue}
            $statement=Get-OracleStatement $call
            $function=Get-OracleOwningFunction $call
            $entries.Add([pscustomobject]@{Source=[string]$sourceEntry.Key;Function=if($null-eq$function){'<script>'}else{$function.Name}
                    Name=$name;Kind='environment-api';Line=$call.Extent.StartLineNumber;StartOffset=$statement.Extent.StartOffset;EndOffset=$statement.Extent.EndOffset})
        }
    }
    @($entries|Sort-Object Source,StartOffset,Kind)
}
