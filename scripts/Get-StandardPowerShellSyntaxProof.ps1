# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
# Parse untrusted source as data. This entry point never executes candidate code.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    $inputText = [Text.StringBuilder]::new()
    $buffer = [char[]]::new(4096)
    while (($count = [Console]::In.Read($buffer,0,$buffer.Length)) -gt 0) {
        [void]$inputText.Append($buffer,0,$count)
        if ($inputText.Length -gt 2097152) { throw 'Parser input exceeds its fixed budget.' }
    }
    $request = $inputText.ToString() | ConvertFrom-Json -ErrorAction Stop
    if (($request.PSObject.Properties.Name | Sort-Object) -join ',' -cne 'language,source' -or
        $request.source -isnot [string] -or $request.language -cnotin @('powershell','markdown')) { throw 'Invalid native parser request.' }
    $source = [string]$request.source
    if ([Text.Encoding]::UTF8.GetByteCount($source) -gt 1048576 -or $source.Contains([char]0)) { throw 'Invalid bounded source.' }
    $ranges = @()
    if ($request.language -ceq 'powershell') { $ranges += @{start=0;end=$source.Length} }
    else {
        foreach ($match in [regex]::Matches($source,'(?m)^```(?:powershell|pwsh|ps1)[ \t]*\n(?<body>[\s\S]*?)^```[ \t]*$')) {
            $ranges += @{start=$match.Groups['body'].Index;end=$match.Groups['body'].Index+$match.Groups['body'].Length}
        }
    }
    if ($ranges.Count -gt 128) { throw 'Too many host units.' }
    $units = @()
    foreach ($range in $ranges) {
        $offset = [int]$range.start
        $text = $source.Substring($offset,([int]$range.end-$offset))
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
        if (@($tokens).Count -gt 100000) { throw 'Native token budget exceeded.' }
        $strings=@($ast.FindAll({param($n)
            ($n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'BareWord') -or
            $n -is [Management.Automation.Language.ExpandableStringExpressionAst]
        },$true) | ForEach-Object { @{
            start=$_.Extent.StartOffset+$offset; end=$_.Extent.EndOffset+$offset
            stringType=if($_ -is [Management.Automation.Language.StringConstantExpressionAst]){[string]$_.StringConstantType}else{'Expandable'}
        } })
        $subs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.SubExpressionAst]},$true) | ForEach-Object { @{start=$_.Extent.StartOffset+$offset;end=$_.Extent.EndOffset+$offset} })
        $continuations=@($tokens | Where-Object {$_.Kind -eq 'LineContinuation'} | ForEach-Object { @{start=$_.Extent.StartOffset+$offset;end=$_.Extent.EndOffset+$offset} })
        $commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object { @{
            start=$_.Extent.StartOffset+$offset;end=$_.Extent.EndOffset+$offset;name=$_.GetCommandName()
            invocation=[string]$_.InvocationOperator
            parameters=@($_.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]} | ForEach-Object {[string]$_.ParameterName})
        } })
        $unsupported=@($ast.FindAll({param($n)
            if($n -isnot [Management.Automation.Language.InvokeMemberExpressionAst]){return $false}
            if($n.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]){return $true}
            $member=[string]$n.Member.Value
            $type=if($n.Expression -is [Management.Automation.Language.TypeExpressionAst]){[string]$n.Expression.TypeName.FullName}else{''}
            if($type -match '(?i)diagnostics\.process') {
                # An empty Process/ProcessStartInfo constructor is a native
                # object allocation, not a shell command-string receiver.
                $argumentCount=if($null -eq $n.Arguments){0}else{$n.Arguments.Count}
                return $member -ine 'new' -or $argumentCount -ne 0
            }
            if($member -ieq 'Start') {
                # Unknown or externally supplied receivers may launch a command
                # string. Only a unique prior allocation in an enclosing
                # statement block supports this narrow native-argv grammar.
                if($n.Expression -isnot [Management.Automation.Language.VariableExpressionAst] -or ($null -ne $n.Arguments -and $n.Arguments.Count -gt 0)){return $true}
                $receiver=$n.Expression.VariablePath.UserPath
                $allocations=@($ast.FindAll({param($a)
                    $a -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $a.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $a.Left.VariablePath.UserPath -ieq $receiver
                },$true))
                if($allocations.Count -ne 1){return $true}
                $allocation=$allocations[0]
                if($allocation.Right.Extent.Text -notmatch '^\s*\[(?:System\.)?Diagnostics\.Process\]::new\(\)\s*$' -or
                   $allocation.Extent.EndOffset -ge $n.Extent.StartOffset){return $true}
                $ancestor=$n.Parent
                while($null -ne $ancestor -and -not [object]::ReferenceEquals($ancestor,$allocation.Parent)){
                    if($ancestor -is [Management.Automation.Language.ScriptBlockAst]){$ancestor=$null;break}
                    $ancestor=$ancestor.Parent
                }
                return $null -eq $ancestor
            }
            return $type -match '(?i)(scriptblock|powershell|runspace|reflection\.assembly|system\.activator)' -or
                $member -match '^(?i)(Invoke|InvokeReturnAsIs|BeginInvoke)$'
        },$true) | ForEach-Object { @{start=$_.Extent.StartOffset+$offset;end=$_.Extent.EndOffset+$offset} })
        # Inspect process-like property operations even without a visible
        # constructor. Selector bindings must precede their use in the
        # same statement block; conditional/outer bindings remain partial.
        $safeSelectors=@{}
        foreach($assignment in @($ast.FindAll({param($n)
            $n -is [Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [Management.Automation.Language.VariableExpressionAst]
        },$true))){
            $variable=$assignment.Left.VariablePath.UserPath
            if($safeSelectors.ContainsKey($variable)){$safeSelectors[$variable]=$false;continue}
            $safeSelectors[$variable]=$false
            $selectorCommands=@($assignment.Right.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
            if($selectorCommands.Count -lt 1 -or $selectorCommands.Count -gt 2){continue}
            $selector=$selectorCommands[0]
            if($selector.GetCommandName() -ine 'Get-Command' -or $selector.CommandElements.Count -ne 6){continue}
            $parts=$selector.CommandElements
            if($parts[1] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
               $parts[2] -isnot [Management.Automation.Language.CommandParameterAst] -or $parts[2].ParameterName -ine 'CommandType' -or
               $parts[3] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $parts[3].Value -ine 'Application' -or
               $parts[4] -isnot [Management.Automation.Language.CommandParameterAst] -or $parts[4].ParameterName -ine 'ErrorAction' -or
               $parts[5] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $parts[5].Value -ine 'Stop'){continue}
            $executable=[IO.Path]::GetFileNameWithoutExtension($parts[1].Value.Replace([char]92,[char]47))
            if($executable -match '^(?i)(bash|sh|zsh|dash|ksh|fish|cmd|powershell|pwsh|python[0-9.]*|node|wsl|perl|ruby|php)$'){continue}
            if($selectorCommands.Count -eq 2){
                $tail=$selectorCommands[1].CommandElements
                if($tail.Count -ne 3 -or $selectorCommands[1].GetCommandName() -ine 'Select-Object' -or
                   $tail[1] -isnot [Management.Automation.Language.CommandParameterAst] -or $tail[1].ParameterName -ine 'First' -or
                   $tail[2].Extent.Text -cne '1'){continue}
            }
            $safeSelectors[$variable]=$assignment
        }

        $unsupported+=@($ast.FindAll({param($n)
            if($n -isnot [Management.Automation.Language.AssignmentStatementAst] -or
               $n.Left -isnot [Management.Automation.Language.MemberExpressionAst]){return $false}
            if($n.Left.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]){return $true}
            $member=[string]$n.Left.Member.Value
            if($member -ieq 'Arguments'){return $true}
            if($member -ieq 'UseShellExecute' -and $n.Right.Extent.Text -cne '$false'){return $true}
            if($member -ieq 'StartInfo'){
                $right=$n.Right.Extent.Text.Trim()
                if($right -notmatch '^\$(?<variable>[a-zA-Z_][a-zA-Z0-9_]*)$'){return $true}
                $infoVariable=$Matches.variable
                $bindings=@($ast.FindAll({param($a)
                    $a -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $a.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $a.Left.VariablePath.UserPath -ieq $infoVariable
                },$true))
                return $bindings.Count -ne 1 -or
                    $bindings[0].Right.Extent.Text -notmatch '^\s*\[(?:System\.)?Diagnostics\.ProcessStartInfo\]::new\(\)\s*$' -or
                    -not [object]::ReferenceEquals($bindings[0].Parent,$n.Parent) -or
                    $bindings[0].Extent.EndOffset -ge $n.Extent.StartOffset
            }
            if($member -ieq 'FileName'){
                $right=$n.Right
                if($right -is [Management.Automation.Language.StatementBlockAst] -and $right.Statements.Count -eq 1){$right=$right.Statements[0]}
                if($right -is [Management.Automation.Language.PipelineAst] -and $right.PipelineElements.Count -eq 1 -and
                   $right.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst]){$right=$right.PipelineElements[0].Expression}
                if($right -is [Management.Automation.Language.CommandExpressionAst]){$right=$right.Expression}
                if($right -is [Management.Automation.Language.StringConstantExpressionAst]){
                    $exe=[IO.Path]::GetFileNameWithoutExtension($right.Value.Replace([char]92,[char]47))
                    return $exe -match '^(?i)(bash|sh|zsh|dash|ksh|fish|cmd|powershell|pwsh|python[0-9.]*|node|wsl|perl|ruby|php)$'
                }
                if($right -is [Management.Automation.Language.MemberExpressionAst] -and
                   $right.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $right.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and $right.Member.Value -ieq 'Source'){
                    $selectorVariable=$right.Expression.VariablePath.UserPath
                    if(-not($safeSelectors.ContainsKey($selectorVariable) -and $safeSelectors[$selectorVariable])){return $true}
                    $binding=$safeSelectors[$selectorVariable]
                    return -not([object]::ReferenceEquals($binding.Parent,$n.Parent) -and
                        $binding.Extent.EndOffset -lt $n.Extent.StartOffset)
                }
                return $true
            }
            return $false
        },$true) | ForEach-Object {@{start=$_.Extent.StartOffset+$offset;end=$_.Extent.EndOffset+$offset}})
        if($commands.Count -gt 4096 -or $strings.Count -gt 16384 -or $subs.Count -gt 4096) { throw 'Native ownership budget exceeded.' }
        $units += @{
            start=[int]$range.start;end=[int]$range.end
            errors=@($errors | ForEach-Object {[string]$_.ErrorId});strings=$strings
            subexpressions=$subs;continuations=$continuations;commands=$commands;commandCount=$commands.Count;unsupported=$unsupported
        }
    }
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source))).ToLowerInvariant()
    $serialized=(@{schemaVersion=1;parserRuntimeVersion=[string]$PSVersionTable.PSVersion;sourceSha256=$hash;language=[string]$request.language;sourceLength=$source.Length;units=$units} | ConvertTo-Json -Depth 12 -Compress)
    if([Text.Encoding]::UTF8.GetByteCount($serialized) -gt 8388608){throw 'Native proof exceeds its fixed budget.'}
    [Console]::WriteLine($serialized)
} catch {
    [Console]::Error.WriteLine('Native PowerShell parser failed closed: '+$_.Exception.Message)
    exit 10
}
