Describe 'SYP258 explicit source validation contract' {
    # Scenario: Native probing is introduced without changing ordinary authority or workflow platform inventory.
    # Purpose: Keep probe execution behind the shared runner boundary and preserve the six-suite ordinary gate.
    It 'UnitT05_routes_native_probes_through_the_shared_owned_process_boundary' {
        $root=Split-Path -Parent $PSScriptRoot
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-StandardValidation.ps1'),[ref]$tokens,[ref]$errors)
        @($errors).Count | Should Be 0
        foreach ($pair in @(@('Invoke-StandardValidationNativeProbe','Invoke-StandardValidationProcess'),@('Invoke-StandardValidationCommandAndRecord','Invoke-StandardValidationNativeProbe'),@('Assert-StandardCoreSourceCheckReport','New-StandardValidationNativeProbeContext'),@('New-StandardValidationSourceConformanceResult','Get-StandardValidationAdvancedProbeContext'))) {
            $function=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $pair[0]},$true))[0]
            @($function.Body.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq $pair[1]},$true)).Count | Should BeGreaterThan 0
        }
        $policy=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'docs/standards/validation-security-gate.json') | ConvertFrom-Json
        @($policy.ordinaryAuthority.testPaths).Count | Should Be 6
        $policy.ordinaryAuthority.skippedCount | Should Be 0
    }

    # Scenario: A source repository explicitly opts into package tools and Static using the ordinary v2 runner.
    # Purpose: V4/V6 keeps the additional source contract optional and ordinary Core free of implicit tools.
    It 'UnitT10_declares_an_optional_source_slot_and_explicit_runner_switch' {
        $root = Split-Path -Parent $PSScriptRoot
        $schema = Get-Content -Raw (Join-Path $root 'docs/standards/schemas/standard-core-adapter-v2.schema.json') | ConvertFrom-Json
        $property = $schema.properties.PSObject.Properties['sourceValidation']
        if ($null -eq $property) { throw 'The v2 adapter must expose its optional sourceValidation contract.' }
        if (@($schema.required) -contains 'sourceValidation') { throw 'Ordinary Core must not require sourceValidation.' }
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-StandardValidation.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { throw 'The source runner must remain parseable.' }
        if (@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'SourceValidation' }).Count -ne 1) { throw 'Source validation must require an explicit public runner switch.' }
        $core = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-StandardCoreValidationRun' }, $true))
        if ($core.Count -ne 1 -or @($core[0].Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'SourceValidation' }).Count -ne 1) { throw 'The v2 runner must receive the explicit source switch.' }
    }

    # Scenario: The source contract distinguishes executed skill-tools files from its npm launcher identity.
    # Purpose: Keep workflow setup aligned with the three-platform Core contract instead of freezing a Unix symlink as a regular file.
    It 'UnitT15_declares_skill_tools_runtime_payload_freeze_without_launcher_membership' {
        $root = Split-Path -Parent $PSScriptRoot
        $policy = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'docs/standards/standard-core-validation-v2.json') | ConvertFrom-Json
        $advanced = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'docs/standards/standard-validation-contract-v1.json') | ConvertFrom-Json
        [string]::IsNullOrWhiteSpace([string]$policy.sourceValidation.skillToolsFreeze) | Should Be $false
        $policy.sourceValidation.skillToolsFreeze | Should Match 'executed Node runtime and entry-point payload'
        $policy.sourceValidation.skillToolsFreeze | Should Match 'launcher-shim membership in frozenFiles is not required'
        $advanced.execution.unixSkillToolsTransport | Should Match 'launcher identity only.*execute the bound Node runtime and payload instead of the shim'
    }

    # Scenario: Source validation rechecks the tracked candidate before repository checks and again after check execution.
    # Purpose: V2/V6 prevents mandatory development-content input from prompting or breaking immutable candidate revalidation.
    It 'UnitT20_supplies_required_development_content_mode_to_every_candidate_inventory_call' {
        $root=Split-Path -Parent $PSScriptRoot
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-StandardValidation.ps1'), [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { throw 'The source runner must remain parseable.' }
        $core=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-StandardCoreValidationRun'}, $true))
        if ($core.Count -ne 1) { throw 'The ordinary Core runner must remain explicit.' }
        $calls=@($core[0].Body.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-StandardCoreTrackedInventory'}, $true))
        if ($calls.Count -lt 2) { throw 'The runner must retain initial inventory and execution-time candidate revalidation.' }
        foreach ($call in $calls) {
            $modeArguments=@($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'AllowDevelopmentContent' })
            if ($modeArguments.Count -ne 1) { throw "Candidate inventory at line $($call.Extent.StartLineNumber) omitted mandatory -AllowDevelopmentContent." }
        }
    }
}

Describe 'SYP353 policy and workflow authority inventory parity' {
    # Scenario: Core executes its actual non-authority workflow step against six authority files and one ordinary file.
    # Purpose: Exercise inventory acquisition and exclusion before the bounded-runner handoff; source-text resemblance cannot satisfy this regression.
    It 'InterT20_executes_core_workflow_inventory_and_excludes_exactly_the_gate_paths' {
        $root=Split-Path -Parent $PSScriptRoot
        $fixture=Join-Path $TestDrive 'core-inventory'
        foreach($directory in @('scripts','tests','docs/standards')){[void][IO.Directory]::CreateDirectory((Join-Path $fixture $directory))}
        Copy-Item -LiteralPath (Join-Path $root 'scripts/Invoke-StandardAuthorityGate.ps1') -Destination (Join-Path $fixture 'scripts/Invoke-StandardAuthorityGate.ps1')
        Copy-Item -LiteralPath (Join-Path $root 'docs/standards/validation-security-gate.json') -Destination (Join-Path $fixture 'docs/standards/validation-security-gate.json')
        Copy-Item -LiteralPath (Join-Path $root 'docs/standards/core-test-skip-inventory.json') -Destination (Join-Path $fixture 'docs/standards/core-test-skip-inventory.json')
        . (Join-Path $root 'scripts/Invoke-StandardAuthorityGate.ps1') -DefineFunctionsOnly
        $expected=@(Get-AuthorityTestPaths -Root $fixture)
        $expected.Count | Should Be 6
        foreach($path in $expected){[IO.File]::WriteAllText($path,'# discovery fixture')}
        [IO.File]::WriteAllText((Join-Path $fixture 'tests/ordinary.Tests.ps1'),'# ordinary discovery fixture')
        $skipInventory=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'docs/standards/core-test-skip-inventory.json')|ConvertFrom-Json
        $skipIdentifier=[string]@($skipInventory.platforms.windows.expectedSkippedTests)[0]
        $skipFile=($skipIdentifier -split '::',2)[0]
        [IO.File]::WriteAllText((Join-Path $fixture "tests/$skipFile"),'# reviewed skip discovery fixture')
        $stub=@'
param($PesterModulePath,$PesterVersion,$ExpectedSkippedCount,[string[]]$ExpectedSkippedTests,$ShardPartitionCount,$ShardPartitionIndex,$OuterTimeoutSeconds,$TestRoot,$EvidenceRoot,[string[]]$SelectedTestFileNames,$SummaryOutputPath,$SummarySchemaVersion,$SummaryRunId,$SummaryRunAttempt)
$value=@{selected=@($SelectedTestFileNames);skipped=$ExpectedSkippedCount;skippedTests=@($ExpectedSkippedTests);summarySchemaVersion=$SummarySchemaVersion;summaryRunId=$SummaryRunId;summaryRunAttempt=$SummaryRunAttempt;authority=@(Get-AuthorityTestPaths -Root (Get-Location).Path)}
[IO.File]::WriteAllText($SummaryOutputPath,($value|ConvertTo-Json -Depth 5))
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'scripts/Invoke-PesterShardProcess.ps1'),$stub)
        # Copy the reviewed YAML literal block verbatim to a child script. Do
        # not evaluate reconstructed source or unload Pester in this process.
        $lines=[IO.File]::ReadAllLines((Join-Path $root '.github/workflows/pr8-powershell-validation.yml'))
        $step=@(0..($lines.Length-1)|Where-Object {$lines[$_] -ceq '      - name: Run the planned non-authority Pester shard'})
        $step.Count | Should Be 1
        $index=$step[0]+1
        while($index -lt $lines.Length -and $lines[$index] -cne '        run: |'){$index++}
        ($index -lt $lines.Length) | Should Be $true
        $body=[Collections.Generic.List[string]]::new()
        for($index++;$index -lt $lines.Length;$index++){
            if($lines[$index].StartsWith('          ')){$body.Add($lines[$index].Substring(10))}
            elseif([string]::IsNullOrWhiteSpace($lines[$index])){$body.Add('')}
            else {break}
        }
        $body.Count | Should BeGreaterThan 0
        $stepPath=Join-Path $fixture 'workflow-step.ps1'
        [IO.File]::WriteAllLines($stepPath,$body,[Text.UTF8Encoding]::new($false))
        $executable=if($PSVersionTable.PSEdition -ceq 'Core'){[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName}else{(Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source}
        $previousTemp=$env:RUNNER_TEMP
        $previousRunnerOs=$env:RUNNER_OS
        $previousRunId=$env:GITHUB_RUN_ID
        $previousRunAttempt=$env:GITHUB_RUN_ATTEMPT
        Push-Location $fixture
        try {
            $env:RUNNER_TEMP=$fixture
            $env:RUNNER_OS='Windows'
            $env:GITHUB_RUN_ID='417'
            $env:GITHUB_RUN_ATTEMPT='2'
            $env:SHARD_ID='01'
            $selectedJson=ConvertTo-Json -Compress -InputObject @('ordinary.Tests.ps1',$skipFile)
            $skipJson=ConvertTo-Json -Compress -InputObject @($skipIdentifier)
            $env:SHARD_FILES_BASE64=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($selectedJson))
            $env:SHARD_SKIPS_BASE64=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($skipJson))
            & $executable -NoLogo -NoProfile -NonInteractive -File $stepPath
            $LASTEXITCODE | Should Be 0
        } finally {$env:RUNNER_TEMP=$previousTemp;$env:RUNNER_OS=$previousRunnerOs;$env:GITHUB_RUN_ID=$previousRunId;$env:GITHUB_RUN_ATTEMPT=$previousRunAttempt;Remove-Item Env:SHARD_ID,Env:SHARD_FILES_BASE64,Env:SHARD_SKIPS_BASE64 -ErrorAction SilentlyContinue;Pop-Location}
        $summary=Get-Content -Raw -Encoding UTF8 (Join-Path $fixture 'windows-core-shard-01-summary.json')|ConvertFrom-Json
        @($summary.selected).Count | Should Be 2
        @($summary.selected) | Should Contain 'ordinary.Tests.ps1'
        @($summary.selected) | Should Contain $skipFile
        $summary.skipped | Should Be 1
        @($summary.skippedTests).Count | Should Be 1
        $summary.skippedTests[0] | Should Be $skipIdentifier
        $summary.summarySchemaVersion | Should Be 2
        $summary.summaryRunId | Should Be '417'
        $summary.summaryRunAttempt | Should Be 2
        @($summary.authority).Count | Should Be 6
        (@($summary.authority) -join '|') | Should Be ($expected -join '|')
    }

    # Scenario: The gate, normative policy and Core exclusions name their retained tests.
    # Purpose: Prevent the prior five/six drift without adding a second authority execution.
    It 'UnitT10_matches_the_six_policy_paths_to_core_exclusions' {
        $root=Split-Path -Parent $PSScriptRoot
        $policy=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'docs/standards/validation-security-gate.json')|ConvertFrom-Json
        $planner=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'scripts/Get-WindowsCorePlan.ps1')
        . (Join-Path $root 'scripts/Invoke-StandardAuthorityGate.ps1') -DefineFunctionsOnly
        $actual=@(Get-AuthorityTestPaths -Root $root -Policy $policy)
        $actual.Count | Should Be 6
        foreach($path in $policy.ordinaryAuthority.testPaths){$planner.Contains("'$path'") | Should Be $true}
        $policy.ordinaryAuthority.testPaths=@($policy.ordinaryAuthority.testPaths[1],$policy.ordinaryAuthority.testPaths[0]) + @($policy.ordinaryAuthority.testPaths|Select-Object -Skip 2)
        {Get-AuthorityTestPaths -Root $root -Policy $policy} | Should Throw 'exact ordered sequence'
    }

    # Scenario: Case evidence has a missing, unexpected, or duplicate skipped test identifier.
    # Purpose: Make the bounded runner enforce the reviewed per-case inventory instead of accepting a matching count alone.
    It 'UnitT11_rejects_skip_inventory_missing_unexpected_and_duplicate_cases' {
        $tokens=$null
        $parseErrors=$null
        $executorPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-PesterShardProcess.ps1'
        $executorAst=[Management.Automation.Language.Parser]::ParseInput((Get-Content -Raw -Encoding UTF8 -LiteralPath $executorPath),[ref]$tokens,[ref]$parseErrors)
        @($parseErrors).Count | Should Be 0
        $definition=@($executorAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-PesterShardExpectedSkippedTests'},$true))
        $definition.Count | Should Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))
        $first='skills-source-acquisition.Tests.ps1::UnitT09_rejects_case_insensitive_file_collisions_before_hashing'
        $second='skills-source-acquisition.Tests.ps1::UnitT09d_rejects_Unicode_NFC_path_collisions_before_hashing'
        $valid=[pscustomobject]@{cases=@(
            [pscustomobject]@{path='C:/repo/tests/skills-source-acquisition.Tests.ps1';name=($first -split '::',2)[1];result='Skipped'},
            [pscustomobject]@{path='C:/repo/tests/skills-source-acquisition.Tests.ps1';name=($second -split '::',2)[1];result='Skipped'}
        )}
        {Assert-PesterShardExpectedSkippedTests -Expected @($first,$second) -CaseEvidence @($valid)} | Should Not Throw
        {Assert-PesterShardExpectedSkippedTests -Expected @($first,$second) -CaseEvidence @([pscustomobject]@{cases=@($valid.cases[0])})} | Should Throw ("Missing: " + $second)
        {Assert-PesterShardExpectedSkippedTests -Expected @($first) -CaseEvidence @($valid)} | Should Throw ("Unexpected: " + $second)
        $duplicate=[pscustomobject]@{cases=@($valid.cases[0],$valid.cases[0])}
        {Assert-PesterShardExpectedSkippedTests -Expected @($first) -CaseEvidence @($duplicate)} | Should Throw 'duplicate skipped test'
    }
}

Describe 'Agent Skill authority workflow contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidationSecurityGatePath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $script:CheckoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $script:SetupGoSha = 'b7ad1dad31e06c5925ef5d2fc7ad053ef454303e'
        $script:AuthorityGoVersionRule = 'latest-stable'
        $script:WorkflowExpectations = [ordered]@{
            '.github/workflows/pr8-powershell-validation.yml' = 5
            '.github/workflows/standards-conformance.yml' = 1
            '.github/workflows/syp101-production-smoke.yml' = 1
            '.github/workflows/syp86-production-lock.yml' = 1
            '.github/workflows/validator-maintenance-producer.yml' = 1
        }
        $script:AuthorityTests = @(
            'internal-source-continuation.Tests.ps1'
            'skill-repository-standard.Tests.ps1'
            'skill-repository-workflows.Tests.ps1'
            'standard-authority-entry-preflight.Tests.ps1'
            'standard-entry-point-binding.Tests.ps1'
            'standard-core-pester-adapter.Tests.ps1'
        )
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

        function Get-PesterExecutorFunction {
            param([Parameter(Mandatory = $true)][string] $Name)

            $executorPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1'
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($executorPath, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) { throw "Could not parse the Pester shard executor: $($parseErrors[0].Message)" }
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                Where-Object { $_.Name -ceq $Name })
            if ($functions.Count -ne 1) { throw "Expected exactly one executor function named '$Name'; found $($functions.Count)." }
            return [scriptblock]::Create($functions[0].Extent.Text)
        }

        function Assert-Throws {
            param([Parameter(Mandatory = $true)][scriptblock] $Action, [Parameter(Mandatory = $true)][string] $Message)

            $threw = $false
            try { & $Action | Out-Null } catch { $threw = $true }
            if (-not $threw) { throw $Message }
        }

        function Write-TestUtf8File {
            param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)

            $fullPath = [IO.Path]::GetFullPath($Path)
            $parent = [IO.Path]::GetDirectoryName($fullPath)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($fullPath, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function Get-WorkflowIndentedBlock {
            param(
                [Parameter(Mandatory = $true)][string] $Text,
                [Parameter(Mandatory = $true)][string] $StartPattern,
                [Parameter(Mandatory = $true)][int] $Indent
            )
            $lines = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Split("`n")
            $starts = [Collections.Generic.List[int]]::new()
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match $StartPattern) { $starts.Add($index) }
            }
            if ($starts.Count -ne 1) { throw "Workflow block '$StartPattern' must occur exactly once; found $($starts.Count)." }
            $start = $starts[0]
            $end = $lines.Count
            for ($index = $start + 1; $index -lt $lines.Count; $index++) {
                if ($lines[$index].Length -eq 0) { continue }
                $leading = $lines[$index].Length - $lines[$index].TrimStart().Length
                if ($leading -le $Indent) { $end = $index; break }
            }
            while ($end -gt ($start + 1) -and $lines[$end - 1].Length -eq 0) { $end-- }
            return ($lines[$start..($end - 1)] -join "`n")
        }

        function Get-WindowsCoreWorkflowJobBlock {
            param([string] $Text,[string] $JobId)
            return Get-WorkflowIndentedBlock -Text $Text -StartPattern ('^  ' + [regex]::Escape($JobId) + ':$') -Indent 2
        }

        function Get-WindowsCoreWorkflowStepBlock {
            param([string] $JobBlock,[string] $StepName)
            return Get-WorkflowIndentedBlock -Text $JobBlock -StartPattern ('^      - name: ' + [regex]::Escape($StepName) + '$') -Indent 6
        }

        function Get-WorkflowBlockSha256 {
            param([string] $Text)
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try { return [Convert]::ToHexString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))).ToLowerInvariant() }
            finally { $algorithm.Dispose() }
        }

        function ConvertTo-WorkflowLf {
            param([string] $Text)
            return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
        }

        $script:WindowsCoreJobHeaders = [ordered]@{
            plan = @'
  plan:
    name: Windows Core plan
    runs-on: windows-latest
    timeout-minutes: 15
    permissions:
      contents: read
    outputs:
      matrix: ${{ steps.plan.outputs.matrix }}
      planSha256: ${{ steps.plan.outputs.planSha256 }}
    steps:
'@.TrimEnd()
            authority = @'
  authority:
    name: Windows Core authority
    needs: plan
    runs-on: windows-latest
    timeout-minutes: 60
    permissions:
      contents: read
    steps:
'@.TrimEnd()
            pester = @'
  pester:
    name: Windows Core shard ${{ matrix.id }}
    needs: plan
    runs-on: windows-latest
    timeout-minutes: 75
    permissions:
      contents: read
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}
    steps:
'@.TrimEnd()
            fixtures = @'
  fixtures:
    name: Windows Core fixtures
    needs: plan
    runs-on: windows-latest
    timeout-minutes: 30
    permissions:
      contents: read
    steps:
'@.TrimEnd()
        }
        $script:WindowsCoreStepHashes = [ordered]@{
            plan = [ordered]@{
                'Checkout' = 'a960680c2b7a8c3ef9a73d7241b0775881118a7237cfd93c5d2fdc50922ca76b'
                'Restore verified PowerShell archive cache' = 'ea953105e06e55782c110c86621e7102ab3b370357e9df2ed4ea0bb418b754df'
                'Install verified latest stable PowerShell' = '408d3e26305b99f60a0239d6f61a022b0f3d8acec0eac230809c5f1f10291b3a'
                'Verify the selected PowerShell runtime' = 'bcb53f4ffa11f7ff96abbf80ffea7bb840cb8913ff1f0d1f36d1bedefe764bf7'
                'Ensure Pester 4.10.1' = 'dccab939c447c634681f8de194ead9d8ef65c21f2f3630e016672cc9f6469f56'
                'Calculate the Windows Core plan' = '8aefdd95f367390f4f57dbf5bd19d531ceb1b89a13032031c0d3403d06f17b0c'
                'Upload Windows Core plan' = '0a956d5b673870156727e2a64608f463fbff132d44857c2533d61797fea402c6'
            }
            authority = [ordered]@{
                'Checkout' = 'a960680c2b7a8c3ef9a73d7241b0775881118a7237cfd93c5d2fdc50922ca76b'
                'Restore verified PowerShell archive cache' = 'ea953105e06e55782c110c86621e7102ab3b370357e9df2ed4ea0bb418b754df'
                'Install verified latest stable PowerShell' = '408d3e26305b99f60a0239d6f61a022b0f3d8acec0eac230809c5f1f10291b3a'
                'Verify the selected PowerShell runtime' = 'bcb53f4ffa11f7ff96abbf80ffea7bb840cb8913ff1f0d1f36d1bedefe764bf7'
                'Ensure Pester 4.10.1' = 'dccab939c447c634681f8de194ead9d8ef65c21f2f3630e016672cc9f6469f56'
                'Parse all PowerShell files' = '1c64e278d236481fabbac60bf28b9f86eb320b2e3dddae512c3a65518caf2204'
                'Check whitespace in the event range' = '72cc9da30eb1dd1dd4c34395f54907ab691cedf077a25e16b267dede987d9d6a'
                'Run the Standard v1 authority gate' = 'f89612f591f43ee7927099af98902f114bab2a5cd3b26037b77a5047fd5beeac'
                'Upload Windows Core authority evidence' = '7630b08af34e5c95e9fc0f5b41f98166f7ec2d125e17cf959dda8bc7b9dcfa49'
            }
            pester = [ordered]@{
                'Checkout' = 'a960680c2b7a8c3ef9a73d7241b0775881118a7237cfd93c5d2fdc50922ca76b'
                'Restore verified PowerShell archive cache' = 'ea953105e06e55782c110c86621e7102ab3b370357e9df2ed4ea0bb418b754df'
                'Install verified latest stable PowerShell' = '408d3e26305b99f60a0239d6f61a022b0f3d8acec0eac230809c5f1f10291b3a'
                'Verify the selected PowerShell runtime' = 'bcb53f4ffa11f7ff96abbf80ffea7bb840cb8913ff1f0d1f36d1bedefe764bf7'
                'Ensure Pester 4.10.1' = 'dccab939c447c634681f8de194ead9d8ef65c21f2f3630e016672cc9f6469f56'
                'Run the planned non-authority Pester shard' = 'd65e25e317e3643341a321e6921d60a9820569e414c98b9fd3fe6376949cc940'
                'Upload Windows Core shard evidence' = 'addb34125b24ed7e73250fcabe1647620e24345a0e17c0830bcb8491877c82c4'
            }
            fixtures = [ordered]@{
                'Checkout' = 'a960680c2b7a8c3ef9a73d7241b0775881118a7237cfd93c5d2fdc50922ca76b'
                'Restore verified PowerShell archive cache' = 'ea953105e06e55782c110c86621e7102ab3b370357e9df2ed4ea0bb418b754df'
                'Install verified latest stable PowerShell' = '408d3e26305b99f60a0239d6f61a022b0f3d8acec0eac230809c5f1f10291b3a'
                'Verify the selected PowerShell runtime' = 'bcb53f4ffa11f7ff96abbf80ffea7bb840cb8913ff1f0d1f36d1bedefe764bf7'
                'Ensure Pester 4.10.1' = 'dccab939c447c634681f8de194ead9d8ef65c21f2f3630e016672cc9f6469f56'
                'Run isolated SYP-214 fixture evidence child' = '24974e37e94f19a6854b3886ef7bbc0dc971786090de42a57e4515aa857ab692'
                'Run offline routine semantic fixtures once' = 'd7c5d03d3f09e764231b554adde3210f82a82e2e0ccf6196d2908baf03af57d4'
                'Upload Windows Core fixture evidence' = 'e2a5d44184df248c2269e9d917cd37d46b936a2e4d793aad1a56bdc9ba75a0dd'
            }
        }
        $script:WindowsCoreAggregateGolden = @'
  windows-core:
    name: Windows Core
    needs: [plan, authority, pester, fixtures]
    if: always()
    runs-on: windows-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Restore verified PowerShell archive cache
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: ${{ runner.temp }}/pwsh-cache/PowerShell-7.6.6-win-x64.zip
          key: pwsh-zip-${{ runner.os }}-7.6.6-02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860

      - name: Install verified latest stable PowerShell
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $version = '7.6.6'
          $expectedSha256 = '02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860'
          $archivePath = Join-Path $env:RUNNER_TEMP 'PowerShell-7.6.6-win-x64.zip'
          $installDirectory = Join-Path $env:RUNNER_TEMP 'pwsh-7.6.6'
          $cachePath = Join-Path $env:RUNNER_TEMP 'pwsh-cache/PowerShell-7.6.6-win-x64.zip'
          $downloadUri = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
          if ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $installDirectory)) { throw 'PowerShell setup paths must be new within this job.' }
          $cacheIsVerified = $false
          if (Test-Path -LiteralPath $cachePath) {
            $cacheItem = Get-Item -Force -LiteralPath $cachePath -ErrorAction Stop
            if ($cacheItem.PSIsContainer -or ($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
              Remove-Item -LiteralPath $cachePath -Force
            } else {
              $cacheSha256 = (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash.ToUpperInvariant()
              if ($cacheSha256 -ceq $expectedSha256) {
                Copy-Item -LiteralPath $cachePath -Destination $archivePath
                $cacheIsVerified = $true
              } else {
                Remove-Item -LiteralPath $cachePath -Force
              }
            }
          }
          if (-not $cacheIsVerified) { Invoke-WebRequest -Uri $downloadUri -OutFile $archivePath }
          $actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
          if ($actualSha256 -cne $expectedSha256) { throw "PowerShell archive SHA256 mismatch: expected $expectedSha256, got $actualSha256." }
          if (-not $cacheIsVerified) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cachePath)) | Out-Null
            Copy-Item -LiteralPath $archivePath -Destination $cachePath
          }
          Expand-Archive -LiteralPath $archivePath -DestinationPath $installDirectory
          $powerShellExe = Join-Path $installDirectory 'pwsh.exe'
          if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { throw 'Verified PowerShell archive did not contain pwsh.exe.' }
          $archiveRuntimeVersion = (& $powerShellExe -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
          if ($LASTEXITCODE -ne 0 -or ([string]$archiveRuntimeVersion).Trim() -cne $version) { throw "Verified archive launched unexpected PowerShell version '$archiveRuntimeVersion'." }
          [IO.File]::AppendAllText($env:GITHUB_PATH, $installDirectory + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
          $githubEnvironment = 'SYP_REQUIRED_PWSH_VERSION=' + $version + [Environment]::NewLine + 'SYP_REQUIRED_PWSH_SHA256=' + $expectedSha256 + [Environment]::NewLine
          [IO.File]::AppendAllText($env:GITHUB_ENV, $githubEnvironment, [Text.UTF8Encoding]::new($false))
          Write-Host "Resolved PowerShell $version from a SHA-256 verified ZIP; portable path: $powerShellExe"

      - name: Verify the selected PowerShell runtime
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP 'pwsh-7.6.6/pwsh.exe'))
          $selectedExecutable = [IO.Path]::GetFullPath((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
          $processExecutable = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
          $homeExecutable = [IO.Path]::GetFullPath((Join-Path $PSHOME 'pwsh.exe'))
          if (-not [string]::Equals($processExecutable, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase) -or
              -not [string]::Equals($homeExecutable, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The actual GitHub step shell is not the verified portable PowerShell: process=$processExecutable PSHOME=$PSHOME"
          }
          if (-not [string]::Equals($selectedExecutable, $expectedExecutable, [StringComparison]::OrdinalIgnoreCase)) { throw "The job shell did not select the verified portable runtime: $selectedExecutable" }
          if ($PSVersionTable.PSVersion.ToString() -cne $env:SYP_REQUIRED_PWSH_VERSION) { throw "Expected PowerShell $env:SYP_REQUIRED_PWSH_VERSION, running $($PSVersionTable.PSVersion)." }
          if ($env:SYP_REQUIRED_PWSH_SHA256 -cne '02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860') { throw 'The verified PowerShell download hash binding changed.' }
          Write-Host "PowerShell runtime verified: $($PSVersionTable.PSVersion) at $selectedExecutable"

      - name: Ensure Pester 4.10.1
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $pesterModules = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]'4.10.1' })
          if ($pesterModules.Count -eq 0) {
            Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser -Force -SkipPublisherCheck
            $pesterModules = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]'4.10.1' })
          }
          if ($pesterModules.Count -ne 1) { throw "Expected exactly one Pester 4.10.1 module; found $($pesterModules.Count)." }
          $manifestPath = Join-Path ([string]$pesterModules[0].ModuleBase) 'Pester.psd1'
          $manifestItem = Get-Item -Force -LiteralPath $manifestPath
          if ($manifestItem.PSIsContainer -or ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Pester manifest must be a regular non-reparse file.' }
          $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
          if ([version]$manifest.ModuleVersion -ne [version]'4.10.1') { throw 'Installed Pester manifest is not version 4.10.1.' }

      - name: Download Windows Core plan
        if: needs.plan.result == 'success'
        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: windows-core-plan-${{ github.run_id }}
          path: ${{ runner.temp }}/windows-core-artifacts/plan

      - name: Download Windows Core shard evidence
        if: needs.pester.result == 'success'
        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          pattern: windows-core-shard-*-${{ github.run_id }}
          path: ${{ runner.temp }}/windows-core-artifacts/shards

      - name: Assert the Windows Core aggregate
        shell: pwsh
        env:
          EXPECTED_PLAN_SHA256: ${{ needs.plan.outputs.planSha256 }}
          EXPECTED_MATRIX_JSON: ${{ needs.plan.outputs.matrix }}
          NEEDS_PLAN_RESULT: ${{ needs.plan.result }}
          NEEDS_AUTHORITY_RESULT: ${{ needs.authority.result }}
          NEEDS_PESTER_RESULT: ${{ needs.pester.result }}
          NEEDS_FIXTURES_RESULT: ${{ needs.fixtures.result }}
        run: |
          $ErrorActionPreference = 'Stop'
          & ./scripts/Assert-WindowsCoreAggregate.ps1 -RepositoryRoot . -ArtifactRoot (Join-Path $env:RUNNER_TEMP 'windows-core-artifacts') -OutputPath (Join-Path $env:RUNNER_TEMP 'windows-core-aggregate-result.json')
          if (-not $?) { throw 'Windows Core aggregate validation failed.' }

      - name: Upload Windows Core aggregate evidence
        if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: windows-core-aggregate-${{ github.run_id }}
          path: ${{ runner.temp }}/windows-core-aggregate-result.json
          if-no-files-found: error
          retention-days: 1
          overwrite: true
'@.TrimEnd()

        function Assert-WindowsCoreWorkflowContract {
            param([Parameter(Mandatory = $true)][string] $WorkflowText)
            $onGolden = @'
on:
  push:
    branches:
      - syp-79-multi-source-routing
      - syp-86
      - syp-101
      - main
  pull_request:
    branches:
      - syp-86
      - main
    # This required workflow always runs the complete retained source-test plan.
  workflow_dispatch:
'@.TrimEnd()
            $permissionsGolden = "permissions:`n  contents: read"
            $concurrencyGolden = @'
concurrency:
  group: powershell-regression-${{ github.event_name }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
'@.TrimEnd()
            if ((Get-WorkflowIndentedBlock $WorkflowText '^on:$' 0) -cne (ConvertTo-WorkflowLf $onGolden)) { throw 'The complete on block differs from its golden text.' }
            if ((Get-WorkflowIndentedBlock $WorkflowText '^permissions:$' 0) -cne $permissionsGolden) { throw 'The top-level permissions block differs from its golden text.' }
            if ((Get-WorkflowIndentedBlock $WorkflowText '^concurrency:$' 0) -cne (ConvertTo-WorkflowLf $concurrencyGolden)) { throw 'The concurrency block differs from its golden text.' }
            foreach ($jobId in $script:WindowsCoreJobHeaders.Keys) {
                $job = Get-WindowsCoreWorkflowJobBlock $WorkflowText $jobId
                $lines = $job.Split("`n")
                $stepsIndex = [Array]::IndexOf($lines, '    steps:')
                if ($stepsIndex -lt 0) { throw "Job '$jobId' is missing its steps block." }
                if (($lines[0..$stepsIndex] -join "`n") -cne (ConvertTo-WorkflowLf $script:WindowsCoreJobHeaders[$jobId])) { throw "Job '$jobId' header differs from its golden text." }
                foreach ($entry in $script:WindowsCoreStepHashes[$jobId].GetEnumerator()) {
                    $step = Get-WindowsCoreWorkflowStepBlock $job ([string]$entry.Key)
                    if ((Get-WorkflowBlockSha256 $step) -cne [string]$entry.Value) { throw "Job '$jobId' step '$($entry.Key)' differs from its byte-exact golden block." }
                }
            }
            $aggregate = Get-WindowsCoreWorkflowJobBlock $WorkflowText 'windows-core'
            if ($aggregate -cne (ConvertTo-WorkflowLf $script:WindowsCoreAggregateGolden)) { throw 'The complete Windows Core aggregate job differs from its golden text.' }
            $aggregateStep = Get-WindowsCoreWorkflowStepBlock $aggregate 'Assert the Windows Core aggregate'
            if ($aggregateStep -match '(?m)^        if:') { throw 'The aggregate validation step must not have a step-level if.' }
            if ([regex]::Matches($aggregateStep, 'Assert-WindowsCoreAggregate\.ps1').Count -ne 1) { throw 'The aggregate validator must be called exactly once.' }
            if ([regex]::Matches($WorkflowText, '(?m)^    name: Windows Core$').Count -ne 1) { throw 'Windows Core must occur exactly once as a job name.' }
        }

        function New-ConsumerEntryPointFixture {
            param([Parameter(Mandatory = $true)][string] $Root)

            [void](New-Item -ItemType Directory -Path $Root -Force)
            Write-TestUtf8File -Path (Join-Path $Root 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
            Write-TestUtf8File -Path (Join-Path $Root '.github/workflows/validate.yml') -Text @'
name: Canonical validation
on:
  pull_request:
    branches:
      - main
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        }
    }

    # Scenario: A workflow checkout is changed back to a mutable tag or leaves its token in Git config.
    # Purpose: Bind every production and authority checkout to the reviewed action commit without ambient credentials.
    It 'UnitT10_pins_every_checkout_and_disables_persisted_credentials' {
        foreach ($entry in $script:WorkflowExpectations.GetEnumerator()) {
            $path = Join-Path $script:RepositoryRoot ([string]$entry.Key)
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing workflow '$($entry.Key)'."
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            $checkoutPattern = "actions/checkout@$($script:CheckoutSha)\s+# v7"
            Assert-Equal ([regex]::Matches($workflow, $checkoutPattern)).Count ([int]$entry.Value) "Every checkout in '$($entry.Key)' must use the reviewed immutable v7 commit."
            Assert-Equal ([regex]::Matches($workflow, 'persist-credentials:\s*false')).Count ([int]$entry.Value) "Every checkout in '$($entry.Key)' must disable persisted credentials."
            Assert-NotMatch $workflow 'actions/checkout@v[0-9]+' "Workflow '$($entry.Key)' must not use a mutable checkout tag."
        }
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        Assert-Equal ([regex]::Matches($required, 'Import-Module \$pester\.Path -Force')).Count 0 'Core must leave module execution inside the bounded child executor.'
        Assert-Equal ([regex]::Matches($required, '& ./scripts/Invoke-PesterShardProcess\.ps1 @executorArguments')).Count 1 'Core must run the retained Pester difference through the bounded executor once.'
        Assert-Match $required 'SelectedTestFileNames = \$selectedTestNames' 'Core must select the complete non-authority difference.'
    }

    # Scenario: The required workflow is compared as raw indentation-bounded YAML blocks.
    # Purpose: Lock event, concurrency, every lane header, critical full steps, and the complete aggregate job without regex gaps.
    It 'UnitT12_matches_the_complete_Windows_Core_workflow_golden_contract' {
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml')
        Assert-WindowsCoreWorkflowContract -WorkflowText $required
    }

    # Scenario: One fail-closed workflow invariant is tampered with while the remaining YAML stays unchanged.
    # Purpose: Prove every specified aggregate and trigger mutation is rejected by the same text-parameter contract function.
    It 'UnitT13_rejects_workflow_tampering_<Mutation>' -TestCases @(
        @{ Mutation = 'aggregate-step-if' },
        @{ Mutation = 'missing-fixtures-need' },
        @{ Mutation = 'softened-always' },
        @{ Mutation = 'misbound-authority-result' },
        @{ Mutation = 'duplicate-Windows-Core-name' },
        @{ Mutation = 'push-paths-filter' }
    ) {
        param($Mutation)
        $workflow = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml')).Replace("`r`n", "`n")
        switch ($Mutation) {
            'aggregate-step-if' { $tampered = $workflow.Replace("      - name: Assert the Windows Core aggregate`n        shell: pwsh", "      - name: Assert the Windows Core aggregate`n        if: needs.pester.result == 'success'`n        shell: pwsh") }
            'missing-fixtures-need' { $tampered = $workflow.Replace('    needs: [plan, authority, pester, fixtures]', '    needs: [plan, authority, pester]') }
            'softened-always' { $tampered = $workflow.Replace('    if: always()', '    if: ${{ !cancelled() }}') }
            'misbound-authority-result' { $tampered = $workflow.Replace('          NEEDS_AUTHORITY_RESULT: ${{ needs.authority.result }}', '          NEEDS_AUTHORITY_RESULT: ${{ needs.plan.result }}') }
            'duplicate-Windows-Core-name' { $tampered = $workflow.TrimEnd() + "`n`n  duplicate-core:`n    name: Windows Core`n    runs-on: windows-latest`n    steps:`n      - run: exit 1`n" }
            'push-paths-filter' { $tampered = $workflow.Replace("  push:`n    branches:", "  push:`n    paths:`n      - docs/**`n    branches:") }
        }
        $tampered | Should Not Be $workflow
        { Assert-WindowsCoreWorkflowContract -WorkflowText $tampered } | Should Throw
    }

    # Scenario: The required workflow fans the suite across retired runtimes and duplicate platforms.
    # Purpose: Keep one Windows Core job, one Windows Install Smoke job, and verified PowerShell provenance.
    It 'UnitT15_ordinary_workflows_use_verified_Windows_PowerShell_only' {
        $workflowDirectory = Join-Path $script:RepositoryRoot '.github/workflows'
        $workflowPaths = @(Get-ChildItem -LiteralPath $workflowDirectory -File |
            Where-Object { $_.Extension -in @('.yml', '.yaml') } |
            ForEach-Object { [IO.Path]::GetRelativePath($script:RepositoryRoot, $_.FullName).Replace('\', '/') })
        $expectedWorkflowPaths = @(
            '.github/workflows/pr8-powershell-validation.yml',
            '.github/workflows/standards-conformance.yml',
            '.github/workflows/syp101-production-smoke.yml',
            '.github/workflows/syp86-production-lock.yml',
            '.github/workflows/validator-maintenance-producer.yml'
        )
        Assert-Equal $workflowPaths.Count $expectedWorkflowPaths.Count 'R4 must retain exactly the five registered active workflow files.'
        Assert-Equal (($workflowPaths | Sort-Object) -join '|') (($expectedWorkflowPaths | Sort-Object) -join '|') 'The workflow inventory must retire the unmatched protected maintenance consumer and reject unreviewed workflow additions.'
        $pullRequestWorkflows = New-Object 'System.Collections.Generic.List[string]'
        $pullRequestJobNames = New-Object 'System.Collections.Generic.List[string]'
        foreach ($relativePath in $workflowPaths) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot $relativePath)
            if ([regex]::IsMatch($workflow, '(?m)^  pull_request:\s*$')) {
                $pullRequestWorkflows.Add($relativePath)
                $jobsBlock = [regex]::Match($workflow, '(?ms)^jobs:\r?\n(?<block>.*)\z')
                Assert-True $jobsBlock.Success "Workflow '$relativePath' must define its jobs block."
                $jobMatches = [regex]::Matches($jobsBlock.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
                if ($relativePath -ceq '.github/workflows/pr8-powershell-validation.yml') {
                    Assert-Equal $jobMatches.Count 5 'PowerShell Regression must define plan, authority, pester, fixtures, and aggregate jobs.'
                    Assert-True (@($jobMatches | Where-Object { $_.Groups[1].Value -ceq 'windows-core' }).Count -eq 1) 'PowerShell Regression must retain exactly one windows-core aggregate job id.'
                    $pullRequestJobNames.Add('windows-core')
                } else {
                    Assert-Equal $jobMatches.Count 1 "Ordinary pull-request workflow '$relativePath' must have exactly one job."
                    $pullRequestJobNames.Add($jobMatches[0].Groups[1].Value)
                }
            }
            Assert-NotMatch $workflow 'windows-powershell-51|PowerShell 5\.1|Pester 3\.4\.0|shell:\s*powershell|runs-on:\s*ubuntu-latest|shell:\s*bash' "Workflow '$relativePath' must not retain a retired PowerShell 5.1 or Linux CI lane."
            Assert-NotMatch $workflow '(?ms)^\s*&\s+\./scripts/[^\r\n]+\.ps1[^\r\n]*\r?\n\s*if\s*\(\s*\$LASTEXITCODE' "Workflow '$relativePath' must use PowerShell success state or exceptions after PowerShell script calls, not a stale native exit code."
            Assert-NotMatch $workflow 'Get-Module Pester -ListAvailable -Name Pester' "Workflow '$relativePath' must not pass Pester both positionally and through -Name."
            Assert-Match $workflow 'runs-on:\s*windows-latest' "Workflow '$relativePath' must run on Windows."
            Assert-Match $workflow "version = '7\.6\.6'" "Workflow '$relativePath' must pin the reviewed latest stable PowerShell release."
            Assert-Match $workflow '02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860' "Workflow '$relativePath' must verify the reviewed PowerShell ZIP SHA256."
            Assert-Match $workflow 'Get-FileHash -LiteralPath \$archivePath -Algorithm SHA256' "Workflow '$relativePath' must hash the archive before use."
            Assert-Match $workflow 'Expand-Archive -LiteralPath \$archivePath' "Workflow '$relativePath' must use the verified portable archive."
            Assert-Match $workflow 'GITHUB_PATH' "Workflow '$relativePath' must put portable pwsh first for later steps."
            Assert-Match $workflow 'MainModule\.FileName' "Workflow '$relativePath' must verify the actual shell process executable."
            Assert-Match $workflow '\$PSHOME' "Workflow '$relativePath' must verify the active PowerShell home."
            Assert-Match $workflow '\$PSVersionTable\.PSVersion' "Workflow '$relativePath' must verify the active runtime version."
            if ($relativePath -cne '.github/workflows/standards-conformance.yml') {
                if ($relativePath -ceq '.github/workflows/pr8-powershell-validation.yml') {
                    Assert-Equal ([regex]::Matches($workflow, '(?m)^\s+matrix:\s*\$\{\{ fromJSON\(needs\.plan\.outputs\.matrix\) \}\}\s*$')).Count 1 'PowerShell Regression must use only the planner-owned Pester shard matrix.'
                } else {
                    Assert-NotMatch $workflow '(?m)^\s+matrix:\s*$' "Ordinary workflow '$relativePath' must not add a platform matrix during the P5.6 diagnostic phase."
                }
                Assert-NotMatch $workflow 'runs-on:\s*\$\{\{' "Ordinary workflow '$relativePath' must retain a fixed Windows runner during the P5.6 diagnostic phase."
                $runnerValues = @([regex]::Matches($workflow, '(?m)^\s+runs-on:\s*([^\r\n]+)\s*$') | ForEach-Object { $_.Groups[1].Value.Trim() })
                $expectedRunnerCount = if ($relativePath -ceq '.github/workflows/pr8-powershell-validation.yml') { 5 } else { 1 }
                Assert-Equal $runnerValues.Count $expectedRunnerCount "Ordinary workflow '$relativePath' must retain the expected Windows job count."
                Assert-Equal (@($runnerValues | Where-Object { $_ -cne 'windows-latest' }).Count) 0 "Ordinary workflow '$relativePath' may use only windows-latest."
            }
        }
        Assert-Equal $pullRequestWorkflows.Count 2 'Exactly the Core and Install Smoke workflows may run for ordinary pull requests.'
        $expectedPullRequestWorkflows = @(
            '.github/workflows/pr8-powershell-validation.yml',
            '.github/workflows/syp101-production-smoke.yml'
        )
        Assert-Equal (($pullRequestWorkflows.ToArray() | Sort-Object) -join '|') (($expectedPullRequestWorkflows | Sort-Object) -join '|') 'No Linux, SYP86, Standards, or maintenance workflow may add an ordinary pull-request job.'
        $expectedPullRequestJobNames = @('windows-core', 'windows-install-smoke')
        Assert-Equal (($pullRequestJobNames.ToArray() | Sort-Object) -join '|') (($expectedPullRequestJobNames | Sort-Object) -join '|') 'Ordinary pull-request CI must aggregate to exactly Windows Core and Windows Install Smoke.'

        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml')
        $smoke = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/syp101-production-smoke.yml')
        $executor = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-PesterShardProcess.ps1')
        $coreJobsBlock = [regex]::Match($required, '(?ms)^jobs:\r?\n(?<block>.*)\z')
        $smokeJobsBlock = [regex]::Match($smoke, '(?ms)^jobs:\r?\n(?<block>.*)\z')
        Assert-True $coreJobsBlock.Success 'PowerShell Regression must define its jobs block.'
        Assert-True $smokeJobsBlock.Success 'SYP101 must define its jobs block.'
        $coreJobs = [regex]::Matches($coreJobsBlock.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
        $smokeJobs = [regex]::Matches($smokeJobsBlock.Groups['block'].Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$')
        Assert-Equal $coreJobs.Count 5 'PowerShell Regression must have plan, authority, pester, fixtures, and aggregate jobs.'
        Assert-Equal (($coreJobs | ForEach-Object { $_.Groups[1].Value } | Sort-Object) -join '|') 'authority|fixtures|pester|plan|windows-core' 'PowerShell Regression job ids must equal the reviewed five-lane design.'
        Assert-Equal $smokeJobs.Count 1 'SYP101 must have one retained normal CI job.'
        Assert-Equal $smokeJobs[0].Groups[1].Value 'windows-install-smoke' 'The sole SYP101 job must be Windows Install Smoke.'
        foreach ($jobId in @('plan','authority','pester','fixtures','windows-core')) {
            $jobMatch=[regex]::Match($required,"(?ms)^  $([regex]::Escape($jobId)):\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)")
            Assert-True $jobMatch.Success "Windows Core workflow must contain the complete '$jobId' job block."
            $jobBlock=$jobMatch.Groups['block'].Value
            Assert-Match $jobBlock '(?m)^    runs-on:\s*windows-latest\s*$' "Job '$jobId' must run on windows-latest."
            $timeoutMatch=[regex]::Match($jobBlock,'(?m)^    timeout-minutes:\s*(\d+)\s*$')
            Assert-True $timeoutMatch.Success "Job '$jobId' must declare a bounded timeout."
            Assert-True ([int]$timeoutMatch.Groups[1].Value -le 75) "Job '$jobId' timeout must not exceed 75 minutes."
            Assert-Match $jobBlock '(?ms)^    permissions:\r?\n      contents:\s*read\s*$' "Job '$jobId' must use contents: read."
            Assert-Equal ([regex]::Matches($jobBlock,"actions/checkout@$($script:CheckoutSha)\s+# v7")).Count 1 "Job '$jobId' must use the pinned checkout exactly once."
            Assert-Equal ([regex]::Matches($jobBlock,'persist-credentials:\s*false')).Count 1 "Job '$jobId' must disable persisted checkout credentials."
            Assert-Equal ([regex]::Matches($jobBlock,'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\s+# v6\.1\.0')).Count 1 "Job '$jobId' must use the pinned ZIP cache action exactly once."
            Assert-Match $jobBlock '\$\{\{ runner\.temp \}\}/pwsh-cache/PowerShell-7\.6\.6-win-x64\.zip' "Job '$jobId' cache must use the separate runner.temp ZIP path."
            Assert-Match $jobBlock 'key:\s*pwsh-zip-\$\{\{ runner\.os \}\}-7\.6\.6-02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860' "Job '$jobId' cache key must bind OS, version and reviewed SHA-256."
            Assert-Equal ([regex]::Matches($jobBlock,'name:\s*Install verified latest stable PowerShell')).Count 1 "Job '$jobId' must install the verified portable runtime once."
            foreach ($setupPattern in @(
                "version = '7\.6\.6'",
                "expectedSha256 = '02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860'",
                'cachePath = Join-Path \$env:RUNNER_TEMP ''pwsh-cache/PowerShell-7\.6\.6-win-x64\.zip''',
                'PowerShell setup paths must be new within this job',
                'Get-FileHash -LiteralPath \$cachePath -Algorithm SHA256',
                'Get-FileHash -LiteralPath \$archivePath -Algorithm SHA256',
                'Remove-Item -LiteralPath \$cachePath -Force',
                'Invoke-WebRequest -Uri \$downloadUri -OutFile \$archivePath',
                'Copy-Item -LiteralPath \$archivePath -Destination \$cachePath',
                'Expand-Archive -LiteralPath \$archivePath -DestinationPath \$installDirectory'
            )) { Assert-Match $jobBlock $setupPattern "Job '$jobId' must retain verified cache/install behavior '$setupPattern'." }
            Assert-Equal ([regex]::Matches($jobBlock,'name:\s*Verify the selected PowerShell runtime')).Count 1 "Job '$jobId' must verify the selected runtime once."
            Assert-Match $jobBlock 'MainModule\.FileName' "Job '$jobId' must verify the actual shell executable."
            Assert-Match $jobBlock '\$PSHOME' "Job '$jobId' must verify the active PowerShell home."
            Assert-Match $jobBlock '\$PSVersionTable\.PSVersion' "Job '$jobId' must verify the runtime version."
            Assert-Equal ([regex]::Matches($jobBlock,'name:\s*Ensure Pester 4\.10\.1')).Count 1 "Job '$jobId' must retain the reviewed Pester verification step."
            Assert-Match $jobBlock "ModuleVersion -ne \[version\]'4\.10\.1'" "Job '$jobId' must validate the installed Pester manifest."
        }
        $allWorkflowText=($workflowPaths|ForEach-Object{Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot $_)}) -join "`n"
        Assert-Equal ([regex]::Matches($allWorkflowText,'(?m)^    name:\s*Windows Core\s*$')).Count 1 'Exactly one workflow job may publish the Windows Core required context.'
        Assert-Equal ([regex]::Matches($allWorkflowText,'(?m)^    name:\s*Windows Install Smoke\s*$')).Count 1 'Exactly one workflow job may publish the Windows Install Smoke required context.'
        Assert-Match ([regex]::Match($required,'(?ms)^  windows-core:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)').Groups['block'].Value) '(?m)^    name:\s*Windows Core\s*$' 'The required context name must belong to the windows-core aggregate job.'
        Assert-Match ([regex]::Match($smoke,'(?ms)^  windows-install-smoke:\r?\n(?<block>.*?)(?=^  [a-z][a-z0-9-]*:\s*$|\z)').Groups['block'].Value) '(?m)^    name:\s*Windows Install Smoke\s*$' 'The install required context name must belong to windows-install-smoke.'
        Assert-Match $required '(?ms)^  windows-core:\s*.*?^    name:\s*Windows Core\s*$.*?^    needs:\s*\[plan, authority, pester, fixtures\]\s*$.*?^    if:\s*always\(\)\s*$' 'The unique Windows Core aggregate must always run after every upstream lane.'
        Assert-NotMatch $smoke '(?m)^\s+needs:' 'Windows Install Smoke must not depend on a retired job.'
        $timeouts = @([regex]::Matches($required, '(?m)^\s+timeout-minutes:\s*(\d+)\s*$') | ForEach-Object { [int]$_.Groups[1].Value })
        Assert-Equal $timeouts.Count 5 'Every Windows Core lane must have a bounded timeout.'
        Assert-Equal (@($timeouts | Where-Object { $_ -gt 75 }).Count) 0 'No Windows Core lane timeout may exceed 75 minutes.'
        Assert-Match $required 'PesterVersion = ''4\.10\.1''' 'The retained suite must use the established Pester 4.10.1 engine.'
        Assert-Match $required '\$pester = Get-Module -ListAvailable -Name Pester' 'Core must discover the installed Pester module with a valid parameter binding.'
        Assert-Equal ([regex]::Matches($required, '& \./scripts/Invoke-PesterShardProcess\.ps1 @executorArguments')).Count 1 'Core must use the existing bounded executor exactly once.'
        Assert-Equal ([regex]::Matches($required, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 1 'Windows Core must execute the authority gate exactly once.'
        Assert-Match $required 'SelectedTestFileNames = \$selectedTestNames' 'Each matrix leg must pass only its planner-selected tests to the bounded executor.'
        Assert-Match $required 'ShardPartitionCount = 1' 'Each matrix leg must execute its assigned tests as one bounded schedule.'
        $planner = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Get-WindowsCorePlan.ps1')
        Assert-Match $planner 'core-test-skip-inventory\.json' 'The planner must load the reviewed machine-readable platform skip inventory.'
        Assert-Match $required 'ExpectedSkippedCount = \$expectedSkippedTests\.Count' 'Core must derive the skip count from the reviewed platform inventory.'
        Assert-Match $required 'ExpectedSkippedTests = \$expectedSkippedTests' 'Core must pass the reviewed per-case skip inventory to the bounded executor.'
        Assert-Match $required 'fail-fast:\s*false' 'Pester shards must all finish to preserve complete evidence.'
        Assert-Match $required 'matrix:\s*\$\{\{ fromJSON\(needs\.plan\.outputs\.matrix\) \}\}' 'The Pester matrix must come only from the planner output.'
        Assert-NotMatch (Get-WindowsCoreWorkflowJobBlock $required 'fixtures') '(?m)^    if:' 'Fixtures must execute for every full-plan event.'
        Assert-Match $required 'Assert-WindowsCoreAggregate\.ps1' 'The required aggregate must run the fail-closed aggregate validator.'
        Assert-Equal ([regex]::Matches($required,'actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333\s+# v8\.0\.2')).Count 2 'The aggregate must use the reviewed download action for plan and shard evidence.'
        Assert-NotMatch $required 'github\.run_attempt' 'Artifact names must remain stable across re-run failed jobs attempts.'
        Assert-Equal ([regex]::Matches($required,'(?m)^\s+overwrite:\s*true\s*$')).Count 5 'Every Windows Core upload must replace its same-run artifact on a rerun.'
        Assert-Match $required 'SummarySchemaVersion = 2' 'Windows Core shards must opt into exact skipped-test summary schema v2.'
        foreach ($binding in @(
            @('NEEDS_PLAN_RESULT','plan'),
            @('NEEDS_AUTHORITY_RESULT','authority'),
            @('NEEDS_PESTER_RESULT','pester'),
            @('NEEDS_FIXTURES_RESULT','fixtures')
        )) {
            $pattern = '(?m)^\s+' + [regex]::Escape($binding[0]) + ':\s*\$\{\{\s*needs\.' + [regex]::Escape($binding[1]) + '\.result\s*\}\}\s*$'
            Assert-Equal ([regex]::Matches($required,$pattern)).Count 1 "The aggregate must bind '$($binding[0])' exactly to needs.$($binding[1]).result."
        }
        Assert-Match $executor "ValidateSet\('4\.10\.1'\)" 'The bounded executor must retire the Pester 3.4/Windows PowerShell 5.1 lane.'
        Assert-Match $executor 'requires PowerShell 7 Core on Windows, Linux or macOS' 'The bounded executor must require a supported Core host.'
        Assert-Match $executor 'Start-PlatformOwnedProcess -ExecutableLease' 'P3 must own launch and executable identity.'
        Assert-Match $executor 'Stop-PlatformOwnedProcess -Lease' 'P3 must own termination and cleanup.'
        Assert-Match $executor 'manifestSha256 = ''[a-f0-9]{64}''' 'Runtime trust must be bound by the entry point before import.'
        Assert-Match $executor "-Filter '\*\.Tests\.ps1' -File -Recurse" 'Shard discovery must match recursive workflow discovery.'
        Assert-NotMatch $executor 'DllImport|CreateJobObject|AssignProcessToJobObject|Get-CimInstance|Stop-Process|\.Kill\(|setsid|ProcessStartInfo' 'The shard must not duplicate native containment or discovery backends.'
        Assert-Match $executor 'MainModule\.FileName' 'The bounded child must inherit the verified runner executable.'
        Assert-NotMatch $executor 'PlatformID\]::Unix|PesterShardLinux|/proc|Pester 3\.4\.0|Windows PowerShell 5\.1' 'The bounded executor must not retain retired Unix process or legacy Pester paths.'
        Assert-NotMatch $required 'Run cross-platform composition and acquisition tests' 'Source composition and acquisition must not run a second time outside full Core discovery.'
        foreach ($authorityTest in $script:AuthorityTests) {
            Assert-Match $planner ([regex]::Escape("'tests/$authorityTest'")) "The planner must exclude the authority-only test '$authorityTest' from shard execution."
        }
        Assert-Match $required 'Run offline routine semantic fixtures once' 'The fixtures lane must retain offline semantic fixtures for every event.'
        Assert-Match $required "pattern='test_routine_semantic_\*\.py'" 'Core must keep exact offline fixture discovery.'
        Assert-Match $required 'Exact offline fixture count changed' 'Core must keep its fixture coverage count assertion.'
        Assert-Match $smoke 'update-skills-catalog-lock\.ps1 -Check' 'Install Smoke must absorb production lock validation.'
        Assert-Match $smoke 'test-syp101-production-smoke\.ps1' 'Install Smoke must keep the real pinned-archive installation and idempotence exercise.'

        $diagnostic = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml')
        Assert-Equal ([regex]::Matches($diagnostic, '(?m)^\s+matrix:\s*$')).Count 1 'Standards Conformance must define exactly one matrix.'
        Assert-Equal ([regex]::Matches($diagnostic, '(?m)^\s+- platform:\s*(windows|linux|macos)\s*$')).Count 3 'Standards Conformance must define exactly three reviewed platform rows.'
        foreach ($matrixRow in @(
            "- platform: windows`n            os: windows-latest`n            asset: PowerShell-7.6.6-win-x64.zip`n            sha256: 02FE458BE20493FBDF43F61EA20610B811EE6C738AB1676C61B9CFCD1A33C860",
            "- platform: linux`n            os: ubuntu-latest`n            asset: powershell-7.6.6-linux-x64.tar.gz`n            sha256: DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC",
            "- platform: macos`n            os: macos-latest`n            asset: powershell-7.6.6-osx-arm64.tar.gz`n            sha256: 6DF833D094EBAC1C1A74340D7B3437F4AAF5E03CE640484A1C4359F3CE8B3DB1"
        )) { Assert-True $diagnostic.Replace("`r`n", "`n").Contains($matrixRow) "Standards Conformance is missing reviewed matrix row '$($matrixRow.Split("`n")[0])'." }
    }

    # Scenario: A diagnostic leg is softened or the summary accepts incomplete evidence.
    # Purpose: Keep all three manual platform legs fail-closed without changing required-platform claims.
    It 'UnitT16_standards_conformance_runs_three_platform_diagnostic_legs_and_fails_closed' {
        $diagnostic = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml')
        Assert-Match $diagnostic 'fail-fast:\s*false' 'The diagnostic matrix must allow every platform leg to finish.'
        Assert-NotMatch $diagnostic 'continue-on-error|\|\|\s*(true|:)|if:\s*always\(\)' 'Diagnostic failures must not be softened.'
        Assert-Match $diagnostic '(?ms)^  diagnostic-summary:\s*.*?^    needs:\s*diagnostic\s*$.*?^    if:\s*\$\{\{ !cancelled\(\) \}\}\s*$' 'The summary must depend on the diagnostic matrix and run unless cancelled.'
        foreach ($summaryToken in @('windows', 'linux', 'macos', 'GITHUB_RUN_ATTEMPT', 'needs.diagnostic.result', 'legStatus')) {
            Assert-Match $diagnostic ([regex]::Escape($summaryToken)) "The diagnostic summary must inspect '$summaryToken'."
        }
        foreach ($stepId in @('install', 'runtime', 'pester', 'parse', 'whitespace', 'authority', 'core', 'syp214', 'offline')) {
            Assert-Match $diagnostic ([regex]::Escape("steps.$stepId.outcome")) "The receipt must capture the '$stepId' outcome."
        }
        Assert-True $diagnostic.Contains("@('authorityResult', 'pesterSummary')") 'The diagnostic summary must require both evidence records.'
        Assert-True $diagnostic.Contains('is missing.') 'The diagnostic summary must report missing required evidence.'
        Assert-True $diagnostic.Contains('Write-Host "::error::$_"') 'The diagnostic summary must emit every failure as a GitHub annotation.'
        Assert-True (-not $diagnostic.Contains('ForEach-Object { Write-Error $_ }')) 'The diagnostic summary must not stop after the first Write-Error.'
        Assert-False $diagnostic.Contains('IsNullOrWhiteSpace([string]$evidenceProperty.Value.sha256)) { continue }') 'The diagnostic summary must not skip evidence records with missing SHA256 values.'
        Assert-True $diagnostic.Contains("@('install', 'runtime', 'pester', 'parse', 'whitespace', 'authority', 'core', 'syp214', 'offline')") 'The diagnostic summary must require every diagnostic step outcome.'
        Assert-True $diagnostic.Contains('outcome is') 'The diagnostic summary must report unsuccessful or missing required step outcomes.'
        Assert-Match $diagnostic 'actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333\s+# v8\.0\.2' 'The diagnostic summary must use the reviewed immutable download-artifact action.'
    }
    Context 'SYP325 central validation CI ownership' {
    # Scenario: The written ownership map drifts from the normal authority gate or the manual diagnostic workflow.
    # Purpose: Keep the central runner/resolver/security test owners tied to Windows Core and preserve the existing skip bound.
    It 'UnitT18_binds_the_central_validation_ownership_map_to_windows_core' {
        $standard=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'docs/standards/skill-repository-standard.md')
        $required=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml')
        $diagnostic=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml')
        $runner=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1')
        $resolver=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Resolve-StandardValidationTool.ps1')
        $planner=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Get-WindowsCorePlan.ps1')
        Assert-Match $standard '12\.3 Central reference implementation ownership and CI' 'The Standard must publish the central implementation ownership map.'
        Assert-Match $standard 'Invoke-StandardValidation\.ps1.*skill-repository-standard\.Tests\.ps1.*standard-validation-runner\.Tests\.ps1.*standard-core-pester-adapter\.Tests\.ps1' 'The Standard must map the runner and report owner to its regression paths.'
        Assert-Match $standard 'Resolve-StandardValidationTool\.ps1.*standard-validation-resolver-hardening\.Tests\.ps1' 'The Standard must map the tool resolver to its hardening regression.'
        Assert-Match $standard 'Invoke-StandardAuthorityGate\.ps1.*validation-security-gate\.json.*skill-repository-workflows\.Tests\.ps1' 'The Standard must map authority/security ownership to policy and workflow regressions.'
        foreach($boundary in @('normal reader PR and merged before candidate adoption', 'A pin or immutable version update alone MUST NOT transfer ownership', 'Source-copy equivalence or removal is deferred to downstream adoption', 'normal required three-platform Core CI gate', 'not a universal file inventory', 'Each source repository MUST retain its own protected reader identities')) {
            if(-not $standard.Contains($boundary)){throw "The ownership map is missing the source-reader or adoption boundary '$boundary'."}
        }
        Assert-Match $planner "values\.Count -ne 5.*Select-Object -Unique.*Count -ne 5" 'The planner must fail closed unless the reviewed Windows inventory retains exactly five unique skips.'
        Assert-Match $planner 'foreach \(\$identifier in \$expectedSkips\)' 'The full Windows Core plan must bind every reviewed skip to the selected inventory.'
        Assert-Match $required 'Invoke-StandardAuthorityGate\.ps1' 'Windows Core must run the required authority gate.'
        Assert-Match $required '\$\{\{ runner\.temp \}\}/syp325-source-scope-\*/\*\*/\*\.json' 'Windows Core must upload task-run-owned SYP325 measurement evidence from runner.temp.'
        Assert-Match $required '\$\{\{ runner\.temp \}\}/windows-core/authority-result\.json' 'Windows Core must upload the normal authority gate result.'
        Assert-Match $diagnostic '(?m)^  workflow_dispatch:\s*$' 'Standards Conformance must remain an on-demand diagnostic.'
        Assert-NotMatch $diagnostic '(?m)^  (pull_request|push):\s*$' 'The manual diagnostic must not be described as the required normal CI gate.'
        Assert-Match $runner '(?s)\^STANDARD_VALIDATION_\[A-Za-z0-9_\]\+\$.*outside the runner namespace' 'The runner must continue accepting only its namespaced child environment.'
        Assert-Match $resolver '(?s)STANDARD_VALIDATION_GITHUB_API_TOKEN.*GITHUB_TOKEN.*GH_TOKEN.*SetEnvironmentVariable' 'The resolver must consume the runner token namespace and clear every GitHub token alias.'
        Assert-Match $resolver "Host -cne 'api\.github\.com'.*continue" 'Authorization must be stripped from every non-api.github.com request.'
    }
    }
    # Scenario: A new discovered Pester file is added while the isolated-file set remains stable.
    # Purpose: Prove the pure planner assigns every path exactly once, preserves exact coverage across logical partitions, and rejects duplicate or missing inventory entries.
    It 'UnitT16_plans_dynamic_inventory_with_exact_four_partition_coverage' {
        $plannerScript = Get-PesterExecutorFunction -Name 'New-PesterShardPlan'
        . $plannerScript

        $isolatedNames = @('standard-validation-runner.Tests.ps1', 'syp101-production-smoke-contract.Tests.ps1')
        $newBindingTest = Join-Path 'inventory-root' 'standard-entry-point-binding.Tests.ps1'
        $allTestPaths = @(
            (Join-Path 'inventory-root' 'standard-validation-runner.Tests.ps1')
            (Join-Path 'inventory-root' 'syp101-production-smoke-contract.Tests.ps1')
            (Join-Path 'inventory-root' 'bulk-alpha.Tests.ps1')
            (Join-Path 'inventory-root' 'bulk-omega.Tests.ps1')
            $newBindingTest
        )
        $plan = @(New-PesterShardPlan -AllTestPaths $allTestPaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 1)
        $plannedPaths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($shard in $plan) { foreach ($path in @($shard.Paths)) { $plannedPaths.Add([string]$path) } }
        Assert-Equal $plannedPaths.Count $allTestPaths.Count 'The isolated and bulk plan must include each discovered path.'
        Assert-Equal @($plannedPaths.ToArray() | Select-Object -Unique).Count $allTestPaths.Count 'A path must appear in exactly one shard.'
        Assert-Equal @($plannedPaths.ToArray() | Where-Object { $_ -ceq $newBindingTest }).Count 1 'The added binding test must be planned exactly once.'
        [string[]]$plannedOrdinal = @($plannedPaths.ToArray())
        [Array]::Sort($plannedOrdinal, [StringComparer]::Ordinal)
        [string[]]$discoveredOrdinal = @($allTestPaths)
        [Array]::Sort($discoveredOrdinal, [StringComparer]::Ordinal)
        Assert-Equal ($plannedOrdinal -join '|') ($discoveredOrdinal -join '|') 'The planner union must equal complete discovery.'

        $partitionedPaths = New-Object 'System.Collections.Generic.List[string]'
        for ($partitionIndex = 0; $partitionIndex -lt 4; $partitionIndex++) {
            for ($shardIndex = 0; $shardIndex -lt $plan.Count; $shardIndex++) {
                if (($shardIndex % 4) -eq $partitionIndex) {
                    foreach ($path in @($plan[$shardIndex].Paths)) { $partitionedPaths.Add([string]$path) }
                }
            }
        }
        Assert-Equal $partitionedPaths.Count $allTestPaths.Count 'The four partitions must retain the complete file inventory.'
        Assert-Equal @($partitionedPaths.ToArray() | Select-Object -Unique).Count $allTestPaths.Count 'The four partitions must assign each discovered file exactly once.'
        [string[]]$partitionedOrdinal = @($partitionedPaths.ToArray())
        [Array]::Sort($partitionedOrdinal, [StringComparer]::Ordinal)
        Assert-Equal ($partitionedOrdinal -join '|') ($discoveredOrdinal -join '|') 'The four-partition union must equal complete discovery.'
        Assert-Equal @($partitionedPaths.ToArray() | Where-Object { $_ -ceq $newBindingTest }).Count 1 'The added binding test must appear in exactly one runtime partition.'

        $duplicatePaths = @($allTestPaths) + @($allTestPaths[2])
        Assert-Throws { New-PesterShardPlan -AllTestPaths $duplicatePaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 1 } 'The planner must reject a duplicate discovered path.'
        $missingIsolatedPaths = @($allTestPaths | Where-Object { (Split-Path -Leaf $_) -cne $isolatedNames[1] })
        Assert-Throws { New-PesterShardPlan -AllTestPaths $missingIsolatedPaths -IsolatedTestFileNames $isolatedNames -BulkShardSize 1 } 'The planner must reject a missing isolated test file.'
    }

    # Scenario: Pester returns shard and aggregate summaries that may be empty, malformed, failed, pending, or skipped.
    # Purpose: Accept truthful typed counts including platform skips, while refusing empty or incomplete results and a fully skipped aggregate.
    It 'UnitT17_rejects_empty_or_untruthful_summary_counts' {
        $assertCountsScript = Get-PesterExecutorFunction -Name 'Assert-PesterShardResultCounts'
        . $assertCountsScript

        $validSummary = [pscustomobject][ordered]@{
            TotalCount = [int]3
            PassedCount = [int]2
            FailedCount = [int]0
            SkippedCount = [int]1
            PendingCount = [int]0
            InconclusiveCount = [int]0
        }
        Assert-PesterShardResultCounts -Summary $validSummary -Context 'shard'
        $allSkippedSummary = [pscustomobject][ordered]@{
            TotalCount = [int]2
            PassedCount = [int]0
            FailedCount = [int]0
            SkippedCount = [int]2
            PendingCount = [int]0
            InconclusiveCount = [int]0
        }
        Assert-PesterShardResultCounts -Summary $allSkippedSummary -Context 'shard'
        Assert-Throws { Assert-PesterShardResultCounts -Summary $allSkippedSummary -Context 'aggregate' } 'An aggregate with no passed tests must be rejected.'

        $zeroSummary = [pscustomobject]@{ TotalCount = 0; PassedCount = 0; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $zeroSummary -Context 'shard' } 'A zero-test result must be rejected.'
        $stringSummary = [pscustomobject]@{ TotalCount = '1'; PassedCount = 1; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $stringSummary -Context 'shard' } 'A string count must be rejected.'
        $negativeSummary = [pscustomobject]@{ TotalCount = 1; PassedCount = 2; FailedCount = 0; SkippedCount = -1; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $negativeSummary -Context 'shard' } 'A negative result count must be rejected.'
        foreach ($field in @('FailedCount', 'PendingCount', 'InconclusiveCount')) {
            $badSummary = [ordered]@{ TotalCount = 1; PassedCount = 1; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
            $badSummary[$field] = [int]1
            Assert-Throws { Assert-PesterShardResultCounts -Summary ([pscustomobject]$badSummary) -Context 'shard' } "A nonzero $field must be rejected."
        }
        $incompleteSummary = [pscustomobject]@{ TotalCount = 2; PassedCount = 1; FailedCount = 0; SkippedCount = 0; PendingCount = 0; InconclusiveCount = 0 }
        Assert-Throws { Assert-PesterShardResultCounts -Summary $incompleteSummary -Context 'shard' } 'Counts that do not cover total results must be rejected.'
    }

    # Scenario: Multiple workflows can silently add normal pull-request CI, duplicate the authority gate, or reuse an outdated platform lane.
    # Purpose: Keep exactly Core and Install Smoke automatic while retaining Windows-only manual and push diagnostics.
    It 'UnitT20_keeps_two_Windows_PR_jobs_and_single_authority_gate' {
        $paths = [ordered]@{
            Core = '.github/workflows/pr8-powershell-validation.yml'
            Standards = '.github/workflows/standards-conformance.yml'
            Smoke = '.github/workflows/syp101-production-smoke.yml'
            Lock = '.github/workflows/syp86-production-lock.yml'
            Maintenance = '.github/workflows/validator-maintenance-producer.yml'
        }
        $workflows = [ordered]@{}
        foreach ($entry in $paths.GetEnumerator()) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot $entry.Value)
            $workflows[$entry.Key] = $workflow
            Assert-Match $workflow 'permissions:\s*contents:\s*read' "$($entry.Key) workflow must use read-only repository permissions."
            Assert-NotMatch $workflow 'sourceMergeExceptionProposal|pr12-source-merge-exception-proposal|sourceMergeDecision|pr12-source-merge-adoption' "$($entry.Key) workflow must not route or publish unrelated source-adoption contexts."
            Assert-NotMatch $workflow 'actions/setup-go|STANDARD_GO_RUNTIME_VERSION|STANDARD_GO_COMMAND_PATH|GITHUB_TOKEN' "$($entry.Key) workflow must not restore retired external resolver dependencies."
        }

        $coreEvents = [regex]::Match($workflows.Core, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $smokeEvents = [regex]::Match($workflows.Smoke, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $standardsEvents = [regex]::Match($workflows.Standards, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $lockEvents = [regex]::Match($workflows.Lock, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        $maintenanceEvents = [regex]::Match($workflows.Maintenance, '(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        Assert-NotMatch $coreEvents '(?m)^\s+paths(-ignore)?:\s*$' 'Windows Core must reject paths and paths-ignore under every configured event.'
        foreach ($pair in @(@{ Name='Core'; Events=$coreEvents }, @{ Name='Smoke'; Events=$smokeEvents })) {
            $pullRequest = [regex]::Match($pair.Events, '(?ms)^  pull_request:\r?\n(?<block>.*?)(?=^  [a-z_]+:\s*$|\z)')
            $push = [regex]::Match($pair.Events, '(?ms)^  push:\r?\n(?<block>.*?)(?=^  [a-z_]+:\s*$|\z)')
            Assert-True $pullRequest.Success "$($pair.Name) must run on ordinary pull requests."
            Assert-True $push.Success "$($pair.Name) must run on its configured push branches."
            Assert-Match $pullRequest.Groups['block'].Value '(?m)^\s*branches:\s*$' "$($pair.Name) pull requests must remain branch scoped."
            Assert-Match $pullRequest.Groups['block'].Value '(?m)^\s*-\s*main\s*$' "$($pair.Name) must cover main pull requests."
            Assert-NotMatch $pullRequest.Groups['block'].Value '(?m)^\s+paths(-ignore)?:\s*$' "$($pair.Name) must not filter the ordinary PR check."
            Assert-Match $workflows[$pair.Name] 'runs-on:\s*windows-latest' "$($pair.Name) must use Windows."
        }
        foreach ($entry in @(@{ Name='Standards'; Events=$standardsEvents }, @{ Name='Maintenance'; Events=$maintenanceEvents })) {
            $triggers = [regex]::Matches($entry.Events, '(?m)^  ([a-z_]+):\s*$')
            Assert-Equal $triggers.Count 1 "$($entry.Name) diagnostic must have exactly one manual trigger."
            Assert-Equal $triggers[0].Groups[1].Value 'workflow_dispatch' "$($entry.Name) diagnostic must be manual and outside ordinary PR CI."
        }
        $lockTriggers = [regex]::Matches($lockEvents, '(?m)^  ([a-z_]+):\s*$')
        $expectedLockTriggers = @('push', 'workflow_dispatch')
        Assert-Equal $lockTriggers.Count $expectedLockTriggers.Count 'SYP86 lock diagnostic must retain a push filter and manual trigger.'
        Assert-Equal (($lockTriggers | ForEach-Object { $_.Groups[1].Value } | Sort-Object) -join '|') (($expectedLockTriggers | Sort-Object) -join '|') 'SYP86 lock diagnostic may run only on path-filtered push or manual dispatch.'
        Assert-Match $lockEvents '(?ms)^  push:\r?\n.*?^    paths:\s*$' 'SYP86 lock diagnostics may remain path-filtered on push.'
        Assert-NotMatch $workflows.Lock '(?m)^  pull_request:\s*$' 'SYP86 lock must not add an ordinary PR job.'
        Assert-NotMatch $workflows.Maintenance '(?m)^  (pull_request|workflow_run|push|schedule):\s*$' 'Validator maintenance must remain an explicit manual diagnostic producer.'

        Assert-Equal ([regex]::Matches($workflows.Standards, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 1 'Manual Standards diagnostics must retain one real authority gate.'
        Assert-Equal ([regex]::Matches($workflows.Core, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 1 'Windows Core must invoke the authority gate exactly once.'
        Assert-Equal ([regex]::Matches($workflows.Smoke, '(?m)^\s*& \./scripts/Invoke-StandardAuthorityGate\.ps1')).Count 0 'Install Smoke must not duplicate the authority gate.'
        Assert-Equal ([regex]::Matches($workflows.Lock, 'update-skills-catalog-lock\.ps1 -Check')).Count 1 'The path-filtered SYP86 diagnostic must validate the lock once.'
        Assert-Equal ([regex]::Matches($workflows.Smoke, 'update-skills-catalog-lock\.ps1 -Check')).Count 1 'Install Smoke must absorb the production lock check once.'
        Assert-Equal ([regex]::Matches($workflows.Smoke, 'test-syp101-production-smoke\.ps1')).Count 1 'Install Smoke must retain the pinned-archive installation and idempotence test once.'
        Assert-Match $workflows.Core 'Run the Standard v1 authority gate' 'Windows Core must execute the true authority gate.'
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        foreach ($testName in $script:AuthorityTests) {
            Assert-Equal ([regex]::Matches($gate, [regex]::Escape($testName))).Count 1 "Shared authority gate must execute '$testName' exactly once."
        }
        $resolverHardeningName = 'standard-validation-resolver-hardening.Tests.ps1'
        $resolverHardeningPath = Join-Path $script:RepositoryRoot ('tests/' + $resolverHardeningName)
        $resolverHardeningTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolverHardeningPath
        $parserCoverageName='static-parser-coverage.Tests.ps1'
        $parserCoverage=Get-Content -Raw -LiteralPath (Join-Path $script:RepositoryRoot ('tests/'+$parserCoverageName))
        Assert-False ($script:AuthorityTests -contains $parserCoverageName) 'Native parser tests must be discovered once by the complete Windows Core test inventory.'
        Assert-Match $parserCoverage 'InterT10_runs_native_parser_contracts_without_skipping_or_scanner_installation' 'Windows Core must retain the real native grammar regression without installing SkillSpector.'
        Assert-Match $parserCoverage 'UnitT42_binds_approved_SkillSpector_sources_and_release_specific_parser_corrections' 'Windows Core must retain the approved-source and release-specific parser identity regression.'
        Assert-Match $resolverHardeningTests 'UnitT25_rejects_python_helper_mutation_after_hash_capture' 'Windows Core must retain the helper hash-binding negative regression.'
        Assert-Match $resolverHardeningTests 'UnitT29_keeps_joint_priority_as_backtracking_order_without_pruning' 'Windows Core must retain fallback eligibility and initial-seeding regression.'
        Assert-Match $resolverHardeningTests 'InterT29_reuses_only_complete_same_host_https_responses' 'Windows Core must retain the behavioral HTTPS lifecycle regression.'
        $wheelHelper = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Resolve-PythonWheelClosure.py')
        Assert-Match $wheelHelper '(?s)def self_test_command.*self_test_candidate_priority\(\)' 'The authority-owned offline helper regression must execute the real candidate-priority fixture.'
        Assert-Match $wheelHelper '(?s)def self_test_command.*self_test_sequential_https\(\)' 'The authority-owned offline helper regression must execute the real HTTPS response fixture.'
        Assert-False ($script:AuthorityTests -contains $resolverHardeningName) 'Resolver hardening tests must remain in Windows Core full-suite discovery.'
        $planner = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Get-WindowsCorePlan.ps1')
        Assert-Match $planner 'Get-ChildItem -LiteralPath \$testRoot -Filter ''\*\.Tests\.ps1'' -File -Recurse' 'Windows Core must discover the resolver hardening regression through the planner complete recursive test inventory.'
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        Assert-NotMatch $normalMain 'ExpectedGoRuntimeVersion|GoCommandPath|STANDARD_GO_|Resolve-StandardValidationTool|Resolve-PythonWheelClosure|New-AuthorityRunOwnedToolRoot|Invoke-AuthorityExternalCommand|skill-validator|skill-tools|SkillSpector|STANDARD_AUTHORITY_PYTHON|tenStageCompletionClaim' 'Normal authority gate must not require retired external dependencies.'
        Assert-Match $normalMain 'Invoke-AuthorityPesterTests -Runtime' 'Normal authority gate must execute the exact retained Pester paths.'
        Assert-Match $normalMain 'Get-AuthorityEntryPreflight @bindingParameters' 'Normal authority gate must rebind actual source hashes after execution.'
    }

    # Scenario: A pull request, push, or manual diagnostic is checked against an empty or unrelated revision range.
    # Purpose: Bind automatic whitespace checks to the event range and manual checks to the selected commit.
    It 'UnitT30_checks_the_actual_event_commit_range_and_manual_commit' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        Assert-Match $required 'PULL_REQUEST_BASE_SHA:\s*\$\{\{\s*github\.event\.pull_request\.base\.sha\s*\}\}' 'Core must bind the pull-request base SHA.'
        Assert-Match $required 'PUSH_BEFORE_SHA:\s*\$\{\{\s*github\.event\.before\s*\}\}' 'Core must bind the pre-push SHA.'
        Assert-Match $required 'GITHUB_EVENT_NAME' 'Core must select the commit range by event type.'
        Assert-Match $required 'git diff --check "\$env:PULL_REQUEST_BASE_SHA\.\.\.HEAD"' 'Core must check the pull-request merge-base range.'
        Assert-Match $required 'git diff --check "\$env:PUSH_BEFORE_SHA\.\.HEAD"' 'Core must check the exact push range.'
        Assert-Match $required 'git diff-tree --check --root -r HEAD' 'Core must support a root-commit fallback.'
        Assert-NotMatch $required 'git diff --check origin/main\.\.\.HEAD' 'Core must not use a range that becomes empty on a main-branch push.'
        Assert-Match $standards 'git diff --check ''HEAD\^\.\.HEAD''' 'Manual Standards diagnostics must check the selected commit against its parent.'
        Assert-Match $standards 'git diff-tree --check --root -r HEAD' 'Manual Standards diagnostics must support a root commit.'
        Assert-NotMatch $standards '(?m)^\s*(PULL_REQUEST_BASE_SHA|PUSH_BEFORE_SHA):' 'Manual Standards diagnostics must not depend on pull-request or push event payloads.'
    }

    # Scenario: The managed lifecycle contract changes while the manual diagnostic is the only workflow naming its files.
    # Purpose: Keep SYP-194 lifecycle semantics inside the required main Composition authority execution.
    It 'UnitT40_routes_managed_lifecycle_changes_through_the_central_authority_gate' {
        $standardsPath = Join-Path $script:RepositoryRoot 'docs/standards/managed-skill-lifecycle.md'
        $schemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'

        Assert-True (Test-Path -LiteralPath $standardsPath -PathType Leaf) 'Managed lifecycle authority document is missing.'
        Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Managed lifecycle evidence schema is missing.'
        $standardWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $requiredWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath

        Assert-Match $standardWorkflow '(?m)^  workflow_dispatch:\s*$' 'Standards Conformance remains available for manual authority diagnosis.'
        Assert-NotMatch $standardWorkflow '(?m)^  (push|pull_request):\s*$' 'Standards Conformance must not duplicate ordinary automatic authority execution.'
        Assert-Match $requiredWorkflow 'Run the Standard v1 authority gate' 'Windows Core must execute the authority gate for managed lifecycle changes.'
        $requiredEvents=[regex]::Match($requiredWorkflow,'(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        Assert-NotMatch $requiredEvents '(?m)^\s+paths(-ignore)?:\s*$' 'Windows Core must run without automatic event path filters.'
        Assert-Match $standardTests 'UnitT70_binds_managed_lifecycle_to_the_central_standard_authority' 'The workflow gate must execute lifecycle-specific authority regression.'
    }

    # Scenario: Upstream adapter changes remain visible to source-contract regressions after the optional package validator leaves the ordinary gate.
    # Purpose: Preserve source and workflow coverage without restoring external tool execution to the authority gate.
    It 'UnitT50_keeps_upstream_interoperability_source_regressions_in_authority_ci' {
        $upstreamPath = Join-Path $script:RepositoryRoot 'docs/standards/upstream-interoperability.md'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $adapterPolicyPath = Join-Path $script:RepositoryRoot 'docs/standards/upstream-adapter.json'
        $adapterSchemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/upstream-adapter-v1.schema.json'
        $adapterValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate-UpstreamAdapter.ps1'

        Assert-True (Test-Path -LiteralPath $upstreamPath -PathType Leaf) 'Upstream interoperability authority document is missing.'
        Assert-True (Test-Path -LiteralPath $adapterPolicyPath -PathType Leaf) 'Upstream adapter policy is missing.'
        Assert-True (Test-Path -LiteralPath $adapterSchemaPath -PathType Leaf) 'Upstream adapter schema is missing.'
        Assert-True (Test-Path -LiteralPath $adapterValidatorPath -PathType Leaf) 'Upstream adapter validator is missing.'
        $upstream = Get-Content -Raw -Encoding UTF8 -LiteralPath $upstreamPath
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath
        Assert-Match $standards '(?m)^  workflow_dispatch:\s*$' 'Standards Conformance remains an explicit manual diagnostic.'
        Assert-NotMatch $standards '(?m)^  (push|pull_request):\s*$' 'Standards Conformance must not rerun automatically for the same event.'
        Assert-Match $required 'Run the Standard v1 authority gate' 'Windows Core must execute the shared gate for upstream changes.'
        foreach ($sourceTestName in @('skills-source-composition.Tests.ps1', 'skills-source-acquisition.Tests.ps1')) {
            $sourceTestPath = Join-Path $script:RepositoryRoot "tests/$sourceTestName"
            Assert-True (Test-Path -LiteralPath $sourceTestPath -PathType Leaf) "Core source regression '$sourceTestName' must remain present."
            Assert-False ($script:AuthorityTests -contains $sourceTestName) "Core source regression '$sourceTestName' must run in the complete non-authority difference rather than be duplicated by the shared authority gate."
        }
        $planner = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Get-WindowsCorePlan.ps1')
        Assert-Match $planner 'Get-ChildItem -LiteralPath \$testRoot -Filter ''\*\.Tests\.ps1'' -File -Recurse' 'The planner must discover every retained Pester test file once for full mode.'
        Assert-Match $planner '-not \$authoritySet\.Contains\(\$_\)' 'The planner must exclude only the exact shared authority test paths from full discovery.'
        $requiredEvents=[regex]::Match($required,'(?ms)^on:\r?\n(?<block>.*?)(?=^permissions:)').Groups['block'].Value
        Assert-NotMatch $requiredEvents '(?m)^\s+paths(-ignore)?:\s*$' 'Windows Core must cover every event without paths or paths-ignore filtering.'
        Assert-Match $standardTests 'UnitT80_binds_upstream_interoperability_to_explicit_central_decisions' 'The workflow gate must execute the upstream interoperability regression.'
        Assert-Match $standardTests 'UnitT81_routes_upstream_negative_cases_through_the_executable_adapter' 'The workflow gate must execute the executable adapter regression.'
        foreach ($caseId in @(
            'package-missing-skill-md',
            'plugin-path-out-of-root',
            'plugin-path-backslash',
            'plugin-path-rooted-windows',
            'plugin-path-dot',
            'plugin-path-colon',
            'plugin-duplicate-field',
            'mcp-unapproved-endpoint',
            'app-unknown-mcp-server',
            'marketplace-mutable-ref',
            'marketplace-duplicate-name',
            'marketplace-duplicate-nested-field',
            'marketplace-unknown-field',
            'marketplace-source-subpath',
            'marketplace-unapproved-repository',
            'marketplace-repository-case-variant',
            'marketplace-unapproved-endpoint',
            'plugin-hook-bypass'
        )) {
            Assert-Match $standardTests ([regex]::Escape($caseId)) "The upstream authority regression must retain negative case '$caseId'."
        }
        Assert-Match $upstream 'SYP-192 Gate 1' 'The upstream decision must bind Plugin conformance to Gate 1.'
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        . (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1') -DefineFunctionsOnly
        @(Get-AuthorityTestPaths -Root $script:RepositoryRoot) | Should Contain (Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1')
        Assert-NotMatch $normalMain 'Validate-UpstreamAdapter\.ps1|upstream-adapter\.json' 'The ordinary authority gate must not invoke the external adapter validator or load its policy.'
    }

    # Scenario: The canonical validation/security policy changes while the ordinary gate remains source-focused.
    # Purpose: Validate the policy as data and keep consumer-stage regressions distinct from ordinary gate execution.
    It 'UnitT60_checks_validation_security_policy_without_restoring_external_gate_chain' {
        $policyPath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $schemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/validation-security-gate-v1.schema.json'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'

        Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) 'Canonical validation/security policy is missing.'
        Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Canonical validation/security policy schema is missing.'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath
        . $gatePath -DefineFunctionsOnly

        Assert-Match $standards '(?m)^  workflow_dispatch:\s*$' 'Standards Conformance remains available as a manual authority diagnostic.'
        Assert-NotMatch $standards '(?m)^  (push|pull_request):\s*$' 'Standards Conformance must not repeat the automatic required gate.'
        Assert-Match $required 'Run the Standard v1 authority gate' 'Windows Core must execute the authority gate for policy and semantic contract changes.'
        Assert-NotMatch $required '(?ms)^on:.*?^  paths(-ignore)?:\s*$' 'Required Composition must run on main events without path filtering.'
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json
        Assert-AuthorityValidationSecurityGate -Policy $policy | Out-Null
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        Assert-NotMatch $normalMain 'validation-security-gate\.json|Assert-AuthorityValidationSecurityGate|semanticPreflight|llm-input-equals-strict-utf8-decoding-of-verified-source-bytes|full-byte-manifest-plus-authenticated-provider-text-subset|standard-semantic-(inventory-probe|preflight|raw-graph)\.Advanced\.ps1|standard-semantic-bridge\.Tests\.ps1|STANDARD_AUTHORITY_PYTHON|one-successful-provider-call-per-planned-work-item' 'The ordinary authority gate must not run policy-controlled external or semantic stages.'
        foreach ($isolatedPythonSuite in @('standard-semantic-inventory-probe.Advanced.ps1','standard-semantic-raw-graph.Advanced.ps1')) {
            $suiteText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot $isolatedPythonSuite)
            Assert-Match $suiteText '& \$script:Python -I -B' "Semantic suite '$isolatedPythonSuite' must use isolated Python startup."
        }
        Assert-Match $standardTests 'UnitT90_binds_canonical_validation_security_order_and_fail_closed_severity' 'The workflow gate must execute SYP-192 validation/security regression.'
    }

    # Scenario: A consumer adds a renamed workflow, hook, release command, or duplicate trigger adapter around a component script.
    # Purpose: Enforce the central entry-point inventory while keeping the unmatched maintenance consumer retired and its manual producer non-admitting.
    It 'UnitT70_rejects_consumer_alternate_gates_but_preserves_authority_workflow_roles' {
        $maintenanceConsumerPath = Join-Path $script:RepositoryRoot '.github/workflows/validator-maintenance-protected-consumer.yml'
        $maintenanceProducer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/validator-maintenance-producer.yml')
        Assert-False (Test-Path -LiteralPath $maintenanceConsumerPath) 'The automatic protected consumer must be retired because workflow_run cannot pair its PR-bound producer identity with a manual diagnostic run.'
        Assert-Match $maintenanceProducer '(?m)^  workflow_dispatch:\s*$' 'The maintenance producer must remain manually dispatchable.'
        Assert-NotMatch $maintenanceProducer '(?m)^  (pull_request|workflow_run|push|schedule):\s*$' 'The maintenance producer must not run as normal CI or an automatic consumer input.'
        Assert-Match $maintenanceProducer 'CANDIDATE_REVISION:\s*\$\{\{\s*github\.sha\s*\}\}' 'The manual producer must bind candidate evidence to the actual workflow-dispatch checkout.'
        Assert-Match $maintenanceProducer '-CandidateRevision \$env:CANDIDATE_REVISION' 'The producer must pass the checked-out candidate revision.'
        Assert-Match $maintenanceProducer '-EventName \$env:GITHUB_EVENT_NAME' 'The producer must report the real workflow-dispatch event name.'
        Assert-Match $maintenanceProducer "ciAdmission\s+-cne\s+'BLOCKED'" 'Diagnostic data must never grant CI admission.'
        Assert-Match $maintenanceProducer 'releaseEligible\s+-ne\s*\$false' 'Diagnostic data must never grant release eligibility.'
        Assert-False ($maintenanceProducer -match '(?m)^\s*(actions|contents|pull-requests):\s*write') 'The diagnostic producer must use no write permissions.'
        $producerScript = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidatorMaintenanceProducer.ps1')
        Assert-Match $producerScript "ValidateSet\('workflow_dispatch'\).*EventName" 'The producer script must accept only the real manual diagnostic event.'
        Assert-Match $producerScript 'eventName = \$EventName' 'The diagnostic report must record the supplied event name.'
        Assert-Match $producerScript 'ciAdmission = ''BLOCKED''' 'The producer result must remain explicitly non-admitting.'
        Assert-Match $producerScript 'releaseEligible = \$false' 'The producer result must remain ineligible for release.'
        $workflowTestText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'tests/skill-repository-workflows.Tests.ps1')
        $maintenanceTestText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:RepositoryRoot 'tests/standard-validation-runner.Tests.ps1')
        foreach ($inventory in @(
            @{ Name='workflow'; Pattern='(?ms)^\$workflowIds = @\((.*?)^\)'; Source=$workflowTestText },
            @{ Name='maintenance'; Pattern='(?ms)^\$maintenanceIds = @\((.*?)^\)'; Source=$maintenanceTestText }
        )) {
            $inventoryMatch = [regex]::Match($producerScript, $inventory.Pattern)
            Assert-True $inventoryMatch.Success "Producer must declare its exact $($inventory.Name) diagnostic test inventory."
            $ids = @([regex]::Matches($inventoryMatch.Groups[1].Value, "'([^']+)'\s*,?\s*") | ForEach-Object { [string]$_.Groups[1].Value })
            Assert-True ($ids.Count -gt 0) "Producer $($inventory.Name) test inventory must not be empty."
            Assert-Equal @($ids | Select-Object -Unique).Count $ids.Count "Producer $($inventory.Name) test inventory must not contain duplicate IDs."
            foreach ($id in $ids) {
                $escapedId = [regex]::Escape($id)
                Assert-Equal ([regex]::Matches($inventory.Source, "(?m)^\s*It '$escapedId'\s*\{")).Count 1 "Producer $($inventory.Name) ID '$id' must match exactly one actual Pester test."
            }
        }
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json
        $authorityGate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        . $script:AuthorityGatePath -DefineFunctionsOnly

        Assert-True ($null -ne $policy.entryPointContract) 'Canonical validation/security policy must declare the entry-point contract.'
        Assert-Match $authorityGate 'Assert-AuthorityConsumerEntryPointContract' 'The shared authority gate must expose the consumer entry-point contract checker.'

        $canonicalFixture = Join-Path $TestDrive 'entry-point-valid'
        New-ConsumerEntryPointFixture -Root $canonicalFixture
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $canonicalFixture `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A single canonical workflow must satisfy the entry-point contract.'

        Write-TestUtf8File -Path (Join-Path $canonicalFixture 'scripts/check-domain.ps1') -Text "Invoke-Pester -Path tests/domain`n"
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $canonicalFixture `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A component script must not become an alternate gate merely because it exists.'

        $negativeCases = @(
            @{
                Name = 'arbitrary-workflow-name'
                RelativePath = '.github/workflows/domain-check.yaml'
                Text = "name: Domain check`non:`n  pull_request:`njobs:`n  domain:`n    steps:`n      - run: ./scripts/run-domain-tests.ps1`n"
            },
            @{
                Name = 'pre-push-hook-bypass'
                RelativePath = '.githooks/pre-push'
                Text = "#!/bin/sh`nInvoke-Pester -Path tests/domain`n"
            },
            @{
                Name = 'pre-commit-hook-bypass'
                RelativePath = '.githooks/pre-commit'
                Text = "#!/bin/sh`nInvoke-Pester -Path tests/domain`n"
            },
            @{
                Name = 'authority-role-name-bypass'
                RelativePath = '.github/workflows/standards-conformance.yml'
                Text = "name: Fake authority role`non:`n  pull_request:`njobs:`n  domain:`n    steps:`n      - run: ./scripts/run-domain-tests.ps1`n"
            },
            @{
                Name = 'public-release-command'
                RelativePath = 'README.md'
                Text = "Run ./scripts/run-domain-tests.ps1 as the release gate.`n"
            },
            @{
                Name = 'release-workflow-without-canonical'
                RelativePath = '.github/workflows/release.yml'
                Text = @'
name: Release
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-action-without-canonical'
                RelativePath = '.github/workflows/release-action.yml'
                Text = @'
name: Release action
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - uses: softprops/action-gh-release@v2
'@
            },
            @{
                Name = 'release-workflow-step-name-only-canonical'
                RelativePath = '.github/workflows/release-step-name.yml'
                Text = @'
name: Release step metadata
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - name: ./scripts/Validate.ps1
        run: gh release create v1.0.0
'@
            },
            @{
                Name = 'release-workflow-comment-only-canonical'
                RelativePath = '.github/workflows/release-comment.yml'
                Text = @'
name: Release comment metadata
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - run: |
          # ./scripts/Validate.ps1
          gh release create v1.0.0
'@
            },
            @{
                Name = 'release-workflow-suppresses-canonical-failure'
                RelativePath = '.github/workflows/release-suppressed.yml'
                Text = @'
name: Release with suppressed validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: ./scripts/Validate.ps1 || true
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-disables-canonical-step'
                RelativePath = '.github/workflows/release-disabled-canonical.yml'
                Text = @'
name: Release with disabled canonical validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - if: ${{ false }}
        run: ./scripts/Validate.ps1
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-conditional-release'
                RelativePath = '.github/workflows/release-conditional.yml'
                Text = @'
name: Conditional release without canonical validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - if: startsWith(github.ref, 'refs/tags/')
        run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-references-canonical-only'
                RelativePath = '.github/workflows/release-canonical-reference.yml'
                Text = @'
name: Release with canonical path reference only
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: Get-Item ./scripts/Validate.ps1
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-same-step-without-success-gate'
                RelativePath = '.github/workflows/release-same-step.yml'
                Text = @'
name: Release with ungated same-step validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - shell: bash
        run: |
          ./scripts/Validate.ps1
          gh release create $GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-with-unbound-validation'
                RelativePath = '.github/workflows/release-unbound.yml'
                Text = @'
name: Release with unbound validation
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    steps:
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-unrelated-list-item'
                RelativePath = '.github/workflows/release-unrelated-list.yml'
                Text = @'
name: Release with unrelated list item
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    steps:
      - canonical-validation
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-opaque-local-helper'
                RelativePath = '.github/workflows/release-opaque-helper.yml'
                Text = @'
name: Release with opaque local helper
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    needs: canonical-validation
    steps:
      - run: ./ship
'@
                Files = @(
                    @{
                        RelativePath = 'ship'
                        Text = "gh release create `$env:GITHUB_REF_NAME`n"
                    }
                )
            },
            @{
                Name = 'release-workflow-opaque-action-delegate'
                RelativePath = '.github/workflows/release-opaque-action.yml'
                Text = @'
name: Release with opaque action delegate
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - uses: acme/ship@0123456789012345678901234567890123456789
'@
            },
            @{
                Name = 'compatibility-independent-validation'
                RelativePath = '.github/workflows/compatibility-independent.yml'
                Text = @'
name: Compatibility status
on:
  workflow_dispatch:
jobs:
  compatibility-status:
    needs: canonical-validation
    steps:
      - run: Invoke-Pester -Path tests/domain
'@
            }
        )
        foreach ($case in $negativeCases) {
            $root = Join-Path $TestDrive ("entry-point-negative-{0}" -f $case.Name)
            New-ConsumerEntryPointFixture -Root $root
            Write-TestUtf8File -Path (Join-Path $root $case.RelativePath) -Text $case.Text
            if ($case.ContainsKey('Files')) {
                foreach ($file in @($case.Files)) {
                    Write-TestUtf8File -Path (Join-Path $root $file.RelativePath) -Text $file.Text
                }
            }
            $errorMessage = $null
            try {
                Assert-AuthorityConsumerEntryPointContract `
                    -RepositoryRoot $root `
                    -CanonicalValidatorPath 'scripts/Validate.ps1' `
                    -Policy $policy | Out-Null
            }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'entry-point contract|alternate|canonical|opaque|release' "Consumer entry-point case '$($case.Name)' must fail closed."
        }

        $compatibilityRoot = Join-Path $TestDrive 'entry-point-compatibility-status'
        New-ConsumerEntryPointFixture -Root $compatibilityRoot
        Write-TestUtf8File -Path (Join-Path $compatibilityRoot '.github/workflows/compatibility-status.yml') -Text @'
name: Compatibility status
on:
  pull_request:
jobs:
  compatibility-status:
    needs: canonical-validation
    steps:
      - run: echo canonical-validation.result
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $compatibilityRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A compatibility status job may depend on and mirror the canonical result.'

        $releaseBoundRoot = Join-Path $TestDrive 'entry-point-release-bound'
        [void](New-Item -ItemType Directory -Path $releaseBoundRoot -Force)
        Write-TestUtf8File -Path (Join-Path $releaseBoundRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $releaseBoundRoot '.github/workflows/release-bound.yml') -Text @'
name: Release with bound validation
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    needs:
      - canonical-validation
    steps:
      - canonical-validation
      - run: gh release create $env:GITHUB_REF_NAME
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $releaseBoundRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A release job must be allowed when it depends on the canonical validation job.'

        $duplicateRoot = Join-Path $TestDrive 'entry-point-duplicate-event'
        New-ConsumerEntryPointFixture -Root $duplicateRoot
        Write-TestUtf8File -Path (Join-Path $duplicateRoot '.github/workflows/duplicate-pr.yaml') -Text @'
name: Duplicate PR adapter
on:
  pull_request:
    branches:
      - main
jobs:
  duplicate:
    steps:
      - run: ./scripts/Validate.ps1
'@
        $duplicateError = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $duplicateRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $duplicateError = $_.Exception.Message }
        Assert-Match $duplicateError 'duplicate|event|candidate' 'Two canonical executions for the same event/candidate must fail closed.'

        $splitRoot = Join-Path $TestDrive 'entry-point-split-triggers'
        [void](New-Item -ItemType Directory -Path $splitRoot -Force)
        Write-TestUtf8File -Path (Join-Path $splitRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $splitRoot '.github/workflows/protected-pr.yml') -Text @'
name: Protected PR adapter
on:
  pull_request:
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Write-TestUtf8File -Path (Join-Path $splitRoot '.github/workflows/trusted-push.yml') -Text @'
name: Trusted push adapter
on:
  push:
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $splitRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'Protected PR and trusted push adapters may be separate when their events do not duplicate execution.'

        $disjointCandidateRoot = Join-Path $TestDrive 'entry-point-disjoint-candidates'
        [void](New-Item -ItemType Directory -Path (Join-Path $disjointCandidateRoot '.github/workflows') -Force)
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot '.github/workflows/main-pr.yml') -Text @'
name: Main pull request adapter
on:
  pull_request:
    branches:
      - main
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot '.github/workflows/release-pr.yml') -Text @'
name: Release pull request adapter
on:
  pull_request:
    branches:
      - release
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        $filterOverlapError = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $disjointCandidateRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $filterOverlapError = $_.Exception.Message }
        Assert-Match $filterOverlapError 'duplicate|event/candidate|overlap' 'Different path or branch filters must not be treated as proof of disjoint canonical execution.'

        $roles = @($policy.entryPointContract.authorityWorkflowRoles)
        Assert-Equal $roles.Count 4 'The authority repository must explicitly classify all four legitimate workflow roles.'
        foreach ($role in $roles) {
            Assert-False ([bool]$role.consumerAlternateGate) "Authority workflow '$($role.path)' must not be classified as a consumer alternate gate."
            Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $role.path) -PathType Leaf) "Authority workflow role '$($role.path)' must remain present."
        }
        Assert-Match $authorityGate 'standards-conformance\.yml|pr8-powershell-validation\.yml|syp86-production-lock\.yml|syp101-production-smoke\.yml' 'The authority gate contract must retain the explicit four-workflow role surface.'
    }

    # Scenario: Canonical release validation is documented beside optional hook setup and repository/API diagnostics.
    # Purpose: Keep non-admitting setup and diagnostic commands from becoming alternate release gates.
    It 'UnitT71_accepts_markdown_setup_and_diagnostics_outside_release_admission' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $root = Join-Path $TestDrive 'entry-point-markdown-setup-diagnostics'
        New-ConsumerEntryPointFixture -Root $root
        Write-TestUtf8File -Path (Join-Path $root 'README.md') -Text @'
## Repository validation
Run the canonical source gate:
```powershell
pwsh -File ./scripts/Validate.ps1
```
### Optional pre-push setup
Enable the optional hook:
```powershell
pwsh -File ./scripts/Set-PrePushHook.ps1 -Mode Enable
```
Disable the optional hook:
```powershell
pwsh -File ./scripts/Set-PrePushHook.ps1 -Mode Disable
```
Inspect repository and API diagnostics:
```powershell
pwsh -File ./tests/validate-repository.ps1
pwsh -File ./tests/validate-api-access.ps1
```
'@

        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $root `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json)) `
            'Optional hook setup and repository/API diagnostics must not be inferred as release gates.'
    }

    # Scenario: README places the canonical command under Diagnostics and a release command under Release.
    # Purpose: Require each release command section to document its own canonical validation dependency.
    It 'UnitT72_rejects_release_command_with_only_an_unrelated_canonical_section' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $root = Join-Path $TestDrive 'entry-point-markdown-unrelated-canonical'
        New-ConsumerEntryPointFixture -Root $root
        Write-TestUtf8File -Path (Join-Path $root 'README.md') -Text @'
## Diagnostics
```powershell
pwsh -File ./scripts/Validate.ps1
```
## Release
```powershell
gh release create v1.0.0
```
'@

        $errorMessage = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $root `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json) | Out-Null
        }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'without exactly one canonical' 'A canonical command in another Markdown section must not authorize a release command.'
    }

    # Scenario: A consumer workflow replaces its canonical validator invocation with a component check.
    # Purpose: Preserve executable workflow enforcement independently from Markdown documentation consistency.
    It 'UnitT73_rejects_workflow_replacement_of_the_canonical_validator' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $root = Join-Path $TestDrive 'entry-point-workflow-canonical-replaced'
        New-ConsumerEntryPointFixture -Root $root
        $workflowPath = Join-Path $root '.github/workflows/validate.yml'
        $workflow = [IO.File]::ReadAllText($workflowPath).Replace('./scripts/Validate.ps1', './scripts/check-domain.ps1')
        Write-TestUtf8File -Path $workflowPath -Text $workflow
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json

        $errorMessage = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $root `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'alternate|non-canonical|bypass|canonical' 'A workflow that replaces the canonical validator with another check must fail closed.'
    }

    # Scenario: A fenced PowerShell release example contains a comment that begins with a Markdown heading marker.
    # Purpose: Keep literal code comments inside their section so the canonical validator remains documented with the release command.
    It 'UnitT74_accepts_release_example_with_fenced_comment' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $text = @'
## Release
```powershell
pwsh -File ./scripts/Validate.ps1
# Publish after validation
gh release create v1.0.0
```
'@

        $sections = @(Get-AuthorityMarkdownCommandSections -Text $text)
        Assert-Equal $sections.Count 1 'A heading-looking fenced comment must not create a second Markdown section.'
        Assert-AuthorityConsumerPublicCommandDocumentation `
            -Text $text `
            -PublicRelativePath 'README.md' `
            -CanonicalRelativePath 'scripts/Validate.ps1' `
            -RequiresFailurePropagation $true
    }

    # Scenario: README uses Setext headings to separate canonical diagnostics from a release command.
    # Purpose: Keep canonical validation in Diagnostics from authorizing an unrelated Release section.
    It 'UnitT75_rejects_release_command_with_only_an_unrelated_setext_canonical_section' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $text = @'
Diagnostics
===========
```powershell
pwsh -File ./scripts/Validate.ps1
```
Release
 =======
```powershell
gh release create v1.0.0
```
'@

        $sections = @(Get-AuthorityMarkdownCommandSections -Text $text)
        Assert-Equal $sections.Count 2 'Setext headings must delimit independent Markdown command sections.'

        $errorMessage = $null
        try {
            Assert-AuthorityConsumerPublicCommandDocumentation `
                -Text $text `
                -PublicRelativePath 'README.md' `
                -CanonicalRelativePath 'scripts/Validate.ps1' `
                -RequiresFailurePropagation $true
        }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'without exactly one canonical' 'A canonical command in another Setext section must not authorize a release command.'
    }
}
Describe 'Third-party raw Skill authority routing' {
    # Scenario: The alternate ownership adapter remains beneath the canonical source gate.
    # Purpose: Prevent a new package utility from becoming a parallel workflow or approval gate.
    It 'UnitT10_routes_raw_packages_to_existing_core_source_validation' {
        $root=Split-Path -Parent $PSScriptRoot
        $raw=Get-Content -Raw (Join-Path $root 'docs/standards/third-party-raw-skill-sources.md')
        $raw | Should Match 'sourceValidation.packageAdapter'
        $raw | Should Match 'one candidate, authority and fresh RunId'
        $raw | Should Match 'typed general/Pester evidence remain mandatory'
        $raw | Should Match 'separately reviewed Catalog/source-pin/Lock'
        $raw | Should Match 'Source checks do not authorize adoption'
        $raw | Should Match 'explicit adoption caller.*MUST.*reject a pending descriptor'
    }
    # Scenario: Raw ownership uses central tests while owned sources retain their full repository test tree.
    # Purpose: Keep the raw route explicit and prevent caller-selected partial source checks.
    It 'UnitT20_binds_the_complete_central_raw_suite_to_the_canonical_authority_gate' {
        $root=Split-Path -Parent $PSScriptRoot
        $raw=Get-Content -Raw (Join-Path $root 'docs/standards/third-party-raw-skill-sources.md')
        foreach ($required in @('central-third-party-raw-skill-v1','tests/third-party-skill-source.Tests.ps1','tests/third-party-source-envelope.Tests.ps1','testSourceIdentity','complete-central-raw-skill-suite','zero failed/skipped/inconclusive/not-run','Omitting the selector retains the complete unfiltered')) {
            if (-not $raw.Contains($required)) {throw ('Missing raw source authority invariant: '+$required)}
        }
        $gate=Get-Content -Raw (Join-Path $root 'scripts/Invoke-StandardAuthorityGate.ps1')
        if (-not $gate.Contains('skill-repository-standard.Tests.ps1')) {throw 'The same authority gate must execute the raw ownership regression.'}
    }
}

Describe 'Validator platform authority routing' {
    # Scenario: The platform receipt contract changes while authority preparation stays in P5.3.
    # Purpose: Keep both existing authority workflows routed through the same gate and retain shared primitives in policy.
    It 'UnitT10_preserves_authority_gate_and_shared_primitive_policy' {
        $root = Split-Path -Parent $PSScriptRoot
        $policy = Get-Content -Raw (Join-Path $root 'docs/standards/standard-core-validation-v2.json') | ConvertFrom-Json
        foreach ($primitive in @('Open-PlatformDirectory','Open-PlatformFile','Assert-PlatformFileIdentity','Enter-PlatformLock','Start-PlatformOwnedProcess','Stop-PlatformOwnedProcess')) {
            $policy.processOwnership.primitives | Should -Contain $primitive
        }
        $policy.processOwnership.executableResolution | Should -Be 'resolve-links-then-no-follow-lease-and-revalidate-identity'
        $policy.processOwnership.argumentZero.nativeCommand | Should -Be 'original-command-path'
        $policy.processOwnership.argumentZero.wrapper | Should -Be 'original-interpreter-path'
        $policy.processOwnership.scriptFailurePolicy | Should -Be 'stop-on-error-and-propagate-last-native-exit-code'
        foreach ($name in @('commandPath','resolvedCommandPath')) {
            $policy.processOwnership.commandBinding | Should -Contain $name
        }
        $workflow = Get-Content -Raw (Join-Path $root '.github/workflows/standards-conformance.yml')
        $workflow.Contains('Invoke-StandardAuthorityGate.ps1') | Should -BeTrue
        $composition = Get-Content -Raw (Join-Path $root '.github/workflows/pr8-powershell-validation.yml')
        $composition.Contains('Invoke-StandardAuthorityGate.ps1') | Should -BeTrue
    }
}
