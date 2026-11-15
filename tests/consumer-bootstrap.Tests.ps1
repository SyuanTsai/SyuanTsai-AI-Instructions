Describe 'Consumer authority bootstrap v1' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:BootstrapPath = Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
        . $script:BootstrapPath -DefineFunctionsOnly
        $script:BootstrapHooksRoot = Join-Path $TestDrive 'bootstrap-hooks-root'
        [void][IO.Directory]::CreateDirectory($script:BootstrapHooksRoot)
        Initialize-PinnedGitHooks $script:BootstrapHooksRoot
        function Invoke-FixtureGit([string]$Root,[string[]]$Arguments) {
            $output=@(& git -c core.autocrlf=false -C $Root @Arguments 2>&1)
            if($LASTEXITCODE-ne0){throw "fixture git failed: $($output-join' ')"}
            $output
        }
        function Get-FixtureGitScalar([string]$Root,[string[]]$Arguments) {
            ([string](@(Invoke-FixtureGit $Root $Arguments)[0])).Trim()
        }
        function New-AuthorityFixture([string]$Root) {
            [void][IO.Directory]::CreateDirectory($Root)
            [void](Invoke-FixtureGit $Root @('init','-q','-b','main'))
            [void](Invoke-FixtureGit $Root @('config','user.name','Fixture'))
            [void](Invoke-FixtureGit $Root @('config','user.email','fixture@example.test'))
            [IO.File]::WriteAllText((Join-Path $Root 'authority.txt'),'authority-v1',[Text.UTF8Encoding]::new($false))
            [void](Invoke-FixtureGit $Root @('add','authority.txt'))
            [void](Invoke-FixtureGit $Root @('commit','-q','-m','authority fixture'))
            Get-FixtureGitScalar $Root @('rev-parse','HEAD')
        }
        function New-RevisionFixture([string]$Root,[string]$BaseRoot) {
            [void][IO.Directory]::CreateDirectory($Root)
            [void](Invoke-FixtureGit $Root @('init','-q','-b','main'))
            [void](Invoke-FixtureGit $Root @('config','user.name','Fixture'))
            [void](Invoke-FixtureGit $Root @('config','user.email','fixture@example.test'))
            [IO.File]::WriteAllText((Join-Path $Root 'history.txt'),'older')
            [void](Invoke-FixtureGit $Root @('add','.'))
            [void](Invoke-FixtureGit $Root @('commit','-q','-m','older'))
            $older=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [IO.File]::AppendAllText((Join-Path $Root 'history.txt'),' base')
            [void](Invoke-FixtureGit $Root @('commit','-q','-am','base'))
            $base=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [void](Invoke-FixtureGit $Root @('checkout','-q','-b','topic'))
            [IO.File]::WriteAllText((Join-Path $Root 'topic.txt'),'topic')
            [void](Invoke-FixtureGit $Root @('add','.'))
            [void](Invoke-FixtureGit $Root @('commit','-q','-m','head'))
            $head=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [void](Invoke-FixtureGit $Root @('checkout','-q','main'))
            [void](Invoke-FixtureGit $Root @('merge','-q','--no-ff','topic','-m','merge candidate'))
            $candidate=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [void](Invoke-FixtureGit $Root @('worktree','add','-q','--detach',$BaseRoot,$base))
            $emptyTree='4b825dc642cb6eb9a060e54bf8d69288fbee4904'
            $unrelated=Get-FixtureGitScalar $Root @('commit-tree',$emptyTree,'-m','unrelated')
            [pscustomobject]@{Older=$older
            Base=$base
            Head=$head
            Candidate=$candidate
            Unrelated=$unrelated
            CandidateRoot=$Root
            BaseRoot=$BaseRoot}
        }
    }

    # Scenario: Workflow identity is converted to the RFC 9562 version-8 N-format identifier.
    # Purpose: Keep all platform legs and aggregate bound to the same deterministic run.
    It 'UnitT10_derives_fixed_version_8_run_id_vectors' {
        (Get-ConsumerRunId 'https://github.com/example/skill.git' '123456789' '1') | Should Be '3dfbadf3ba80828f901e5f8fd085de54'
        (Get-ConsumerRunId 'https://github.com/example/skill.git' '123456789' '2') | Should Be 'd1ba05c0ccb98666949e882495d17394'
        (Get-ConsumerRunId 'https://github.com/example/skill.git' '123456789' '1').Substring(12,1) | Should Be '8'
        [Convert]::ToInt32((Get-ConsumerRunId 'https://github.com/example/skill.git' '123456789' '1').Substring(16,1),16) -band 12 | Should Be 8
    }

    # Scenario: The same repository and workflow attempt are evaluated for each leg and aggregate.
    # Purpose: Platform names must not create distinct validation identities.
    It 'UnitT20_keeps_platform_and_aggregate_run_ids_identical' {
        $ids = @('windows','linux','macos','aggregate') | ForEach-Object { Get-ConsumerRunId 'https://github.com/example/skill.git' '77' '3' }
        @($ids | Select-Object -Unique).Count | Should Be 1
        (Get-ConsumerRunId 'https://github.com/example/skill.git' '77' '4') | Should Not Be $ids[0]
        { Get-ConsumerRunId 'https://github.com/example/skill.git' '77' '0' } | Should Throw
    }

    # Scenario: Pin JSON has the exact v1 shape and official repository identity.
    # Purpose: Reject extension fields, missing fields, wrong repositories, duplicate keys, BOM, and oversized input.
    It 'UnitT30_reads_only_the_strict_authority_pin_shape' {
        $root = Join-Path $TestDrive 'pin'
         [void][IO.Directory]::CreateDirectory((Join-Path $root 'config'))
        $path = Join-Path $root 'config/authority-pin.json'
         $utf8 = New-Object Text.UTF8Encoding($false)
        $valid = '{"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '"}'
        [IO.File]::WriteAllText($path,$valid,$utf8)
         (Read-AuthorityPin $root).Value.commit | Should Be ('a' * 40)
        foreach ($invalid in @(
            '{"schemaVersion":1,"repository":"https://example.org/authority.git","commit":"' + ('a' * 40) + '"}',
            '{"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git"}',
            '{"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '","extra":true}',
            '{"schemaVersion":1,"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '"}',
            '{"schemaVersion":1,"SchemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '"}'
        )) { [IO.File]::WriteAllText($path,$invalid,$utf8)
         { Read-AuthorityPin $root } | Should Throw }
        [IO.File]::WriteAllBytes($path,@(239,187,191) + [Text.Encoding]::UTF8.GetBytes($valid))
         { Read-AuthorityPin $root } | Should Throw
        [IO.File]::WriteAllText($path,$valid + (' ' * 4097),$utf8)
         { Read-AuthorityPin $root } | Should Throw
    }

    # Scenario: The bootstrap is inspected as the byte-for-byte consumer template.
    # Purpose: Preserve the thin built-in-only boundary and fixed formal authority URL.
    It 'UnitT40_keeps_the_bootstrap_thin_and_without_native_or_module_escape_hatches' {
        $lines = @(Get-Content -LiteralPath $script:BootstrapPath -Encoding UTF8)
        $lines.Count | Should BeLessThan 401
        $text = $lines -join "`n"
        $text | Should Not Match '(?im)^\s*(Add-Type|Import-Module)\b|DllImport'
        ([regex]::Matches($text,[regex]::Escape('https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'))).Count | Should Be 1
        $text | Should Match 'protocol\.file\.allow='
         $text | Should Match 'core\.hooksPath='
         $text | Should Match 'credential\.helper='
        $text | Should Match 'merge-base.*--is-ancestor'
         $text | Should Match "'ls-tree', '-r', '-z'"
         $text | Should Match 'hash-object'
    }

    # Scenario: Phase environment and interface retirement are authority-owned data.
    # Purpose: Token access remains prepare-only and v1 support cannot disappear silently.
    It 'UnitT50_declares_prepare_only_token_access_and_interface_retirement_evidence' {
        $contract = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json') | ConvertFrom-Json
        Assert-ConsumerInterface $contract
        @($contract.supportedInterfaces) | Should Contain 'consumer-gate-v1'
        $contract.retiredInterfaces -is [array] | Should Be $true
        @($contract.phaseEnvironment.prepare) | Should Contain 'STANDARD_VALIDATION_GITHUB_API_TOKEN'
        foreach ($phase in @('validate','finalize','aggregate')) { (@($contract.phaseEnvironment.$phase) -join ',') | Should Not Match `
            '(?i)TOKEN|SECRET|PASSWORD|PRIVATE_KEY' }
        $unsupported=($contract|ConvertTo-Json -Depth 10|ConvertFrom-Json)
        $unsupported.supportedInterfaces=@('consumer-gate-v2')
        $unsupported.currentInterface='consumer-gate-v2'
        $unsupported.retiredInterfaces=@([pscustomobject]@{interface='consumer-gate-v1'
        evidence=@()})
        {Assert-ConsumerInterface $unsupported}|Should Throw 'cannot cross a retired interface boundary'
    }

    # Scenario: A gate child receives only its phase allowlist and returns an unknown or recognized exit code.
    # Purpose: Preserve the minimal subprocess environment and the public exit-code boundary.
    It 'UnitT55_filters_child_environment_and_normalizes_unknown_exit_codes' {
        $root=Join-Path $TestDrive 'process'
        [void][IO.Directory]::CreateDirectory($root)
        $interfacePath=Join-Path $root 'interface.json'
        $childPath=Join-Path $root 'child.ps1'
        $outputPath=Join-Path $root 'environment.json'
        $contract=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json')|ConvertFrom-Json
        $contract.phaseEnvironment.validate=@($contract.phaseEnvironment.validate)+@('FIXTURE_EXIT_CODE','FIXTURE_OUTPUT')
        [IO.File]::WriteAllText($interfacePath,($contract|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
        $child=@'
param([string]$Interface,[string]$Phase,[string]$AuthorityBindingPath,[string]$BaseRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$Platform,[switch]$TransitionFromLegacy)
[IO.File]::WriteAllText($env:FIXTURE_OUTPUT,(@{allowed=$env:FIXTURE_EXIT_CODE;unlisted=$env:UNLISTED_SENTINEL}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
exit [int]$env:FIXTURE_EXIT_CODE
'@
        [IO.File]::WriteAllText($childPath,$child,(New-Object Text.UTF8Encoding($false)))
        $script:BaseRoot=$root
        $script:CandidateRoot=$root
        $script:WorkRoot=$root
        $script:Platform='windows'
        $script:TransitionFromLegacy=$false
        $env:FIXTURE_OUTPUT=$outputPath
        $env:UNLISTED_SENTINEL='must-not-cross'
        $env:FIXTURE_EXIT_CODE='9'
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'validate' (Join-Path $root 'binding.json'))|Should Be 30
        $observed=Get-Content -Raw -Encoding UTF8 $outputPath|ConvertFrom-Json
        $observed.allowed|Should Be '9'
        $observed.unlisted|Should BeNullOrEmpty
        $env:FIXTURE_EXIT_CODE='10'
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'validate' (Join-Path $root 'binding.json'))|Should Be 10
        Remove-Item Env:FIXTURE_OUTPUT,Env:FIXTURE_EXIT_CODE,Env:UNLISTED_SENTINEL -ErrorAction SilentlyContinue
    }

    # Scenario: A prepare child receives the resolver token while the same child in validate does not.
    # Purpose: Exercise phase-scoped credential isolation at the actual child-process boundary.
    It 'UnitT57_passes_the_resolver_token_only_to_prepare' {
        $root=Join-Path $TestDrive 'phase-environment'
        [void][IO.Directory]::CreateDirectory($root)
        $interfacePath=Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json'
        $childPath=Join-Path $root 'child.ps1'
        $outputPath=Join-Path $root 'observed.json'
        $child=@'
param([string]$Interface,[string]$Phase,[string]$AuthorityBindingPath,[string]$BaseRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$Platform,[switch]$TransitionFromLegacy)
[IO.File]::WriteAllText($env:GITHUB_STEP_SUMMARY,(@{phase=$Phase;token=$env:STANDARD_VALIDATION_GITHUB_API_TOKEN;github=$env:GITHUB_TOKEN}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
exit 0
'@
        [IO.File]::WriteAllText($childPath,$child,(New-Object Text.UTF8Encoding($false)))
        $script:BaseRoot=$root
        $script:CandidateRoot=$root
        $script:WorkRoot=$root
        $script:Platform='windows'
        $script:TransitionFromLegacy=$false
        $env:GITHUB_STEP_SUMMARY=$outputPath
        $env:STANDARD_VALIDATION_GITHUB_API_TOKEN='phase-token-sentinel'
        $env:GITHUB_TOKEN='must-not-cross'
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'prepare' (Join-Path $root 'binding.json'))|Should Be 0
        $observed=Get-Content -Raw -Encoding UTF8 $outputPath|ConvertFrom-Json
        $observed.phase|Should Be 'prepare'
        $observed.token|Should Be 'phase-token-sentinel'
        $observed.github|Should BeNullOrEmpty
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'validate' (Join-Path $root 'binding.json'))|Should Be 0
        $observed=Get-Content -Raw -Encoding UTF8 $outputPath|ConvertFrom-Json
        $observed.phase|Should Be 'validate'
        $observed.token|Should BeNullOrEmpty
        $observed.github|Should BeNullOrEmpty

        foreach ($stream in @('Out','Error')) {
            $leakPath = Join-Path $root "leak-$stream.ps1"
            [IO.File]::WriteAllText(
                $leakPath,
                "param(`$Interface,`$Phase,`$AuthorityBindingPath,`$BaseRoot,`$CandidateRoot,`$WorkRoot,`$Platform)`n" +
                "[Console]::$stream.WriteLine(`"fixture HTTP timeout diagnostic: `$env:STANDARD_VALIDATION_GITHUB_API_TOKEN`")`nexit 20`n",
                [Text.UTF8Encoding]::new($false)
            )
            $env:STANDARD_VALIDATION_GITHUB_API_TOKEN = "${stream}-token-sentinel"
            $originalError = [Console]::Error
            $diagnosticWriter = [IO.StringWriter]::new()
            try {
                [Console]::SetError($diagnosticWriter)
                $leakExit = Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $leakPath $interfacePath `
                    prepare (Join-Path $root 'binding.json')
            }
            finally {
                [Console]::SetError($originalError)
            }
            $leakExit | Should Be 20
            $diagnostic = $diagnosticWriter.ToString()
            $diagnostic | Should Not Match ([regex]::Escape("${stream}-token-sentinel"))
            $diagnostic | Should Match 'credential sentinel.*suppressed'
        }

        $bootstrapText = Get-Content -Raw -Encoding UTF8 $script:BootstrapPath
        $suppressionCondition = '$standardOutput.Contains($sentinel, [StringComparison]::Ordinal) -or $standardError.Contains($sentinel, [StringComparison]::Ordinal)'
        $mutantText = $bootstrapText.Replace($suppressionCondition, '$false')
        $mutantText | Should Not Be $bootstrapText
        $mutantPath = Join-Path $TestDrive 'Invoke-PinnedAuthority-output-suppression-mutant.ps1'
        [IO.File]::WriteAllText($mutantPath,$mutantText,[Text.UTF8Encoding]::new($false))
        $mutantModule = New-Module -Name BootstrapOutputSuppressionMutant -ArgumentList $mutantPath -ScriptBlock {
            param($path)
            . $path -DefineFunctionsOnly
        }
        try {
            foreach ($stream in @('Out','Error')) {
                $leakPath = Join-Path $root "mutant-leak-$stream.ps1"
                [IO.File]::WriteAllText(
                    $leakPath,
                    "param(`$Interface,`$Phase,`$AuthorityBindingPath,`$BaseRoot,`$CandidateRoot,`$WorkRoot,`$Platform)`n" +
                    "[Console]::$stream.WriteLine(`"fixture diagnostic: `$env:STANDARD_VALIDATION_GITHUB_API_TOKEN`")`nexit 20`n",
                    [Text.UTF8Encoding]::new($false)
                )
                $sentinel = "mutant-${stream}-token-sentinel"
                $env:STANDARD_VALIDATION_GITHUB_API_TOKEN = $sentinel
                $originalOut = [Console]::Out
                $originalError = [Console]::Error
                $outWriter = [IO.StringWriter]::new()
                $errorWriter = [IO.StringWriter]::new()
                try {
                    [Console]::SetOut($outWriter)
                    [Console]::SetError($errorWriter)
                    $mutantExit = & $mutantModule {
                        param($root,$leakPath,$interfacePath)
                        $script:BaseRoot=$root
                        $script:CandidateRoot=$root
                        $script:WorkRoot=$root
                        $script:Platform='windows'
                        $script:TransitionFromLegacy=$false
                        Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $leakPath $interfacePath `
                            prepare (Join-Path $root 'binding.json')
                    } $root $leakPath $interfacePath
                }
                finally {
                    [Console]::SetOut($originalOut)
                    [Console]::SetError($originalError)
                }
                $mutantExit | Should Be 20
                ($outWriter.ToString() + $errorWriter.ToString()) | Should Match ([regex]::Escape($sentinel))
            }
        }
        finally {
            Remove-Module $mutantModule -Force
        }
        Remove-Item Env:GITHUB_STEP_SUMMARY,Env:STANDARD_VALIDATION_GITHUB_API_TOKEN,Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    }

    # Scenario: An attacker pre-creates or redirects the predictable hooks location under WorkRoot.
    # Purpose: The create-only helper accepts only a new empty physical directory with the exact run-owned name.
    It 'UnitT58_creates_hooks_only_in_a_new_empty_physical_workroot_directory' {
        $root = Join-Path $TestDrive 'bootstrap-hook-hardening'
        [void][IO.Directory]::CreateDirectory($root)
        $name = 'git-hooks-' + ('a' * 32)
        $created = New-PinnedGitHooksDirectory $root $name
        $created | Should Be (Join-Path $root $name)
        @(Get-ChildItem -LiteralPath $created -Force).Count | Should Be 0

        { New-PinnedGitHooksDirectory $root $name } | Should Throw 'already exists'
        $nonEmptyName = 'git-hooks-' + ('b' * 32)
        $nonEmpty = Join-Path $root $nonEmptyName
        [void][IO.Directory]::CreateDirectory($nonEmpty)
        [IO.File]::WriteAllText((Join-Path $nonEmpty 'pre-commit'), 'malicious')
        { New-PinnedGitHooksDirectory $root $nonEmptyName } | Should Throw 'already exists'

    }

    if ($IsWindows) {
        # Scenario: A Windows WorkRoot has a Junction ancestor controlled outside the physical directory.
        # Purpose: Register the Windows reparse-point attack only on its native host.
        It 'UnitT58a_rejects_a_windows_junction_workroot_ancestor' {
            $physical = Join-Path $TestDrive 'bootstrap-hook-physical'
            $junction = Join-Path $TestDrive 'bootstrap-hook-junction'
            [void][IO.Directory]::CreateDirectory($physical)
            [void](New-Item -ItemType Junction -Path $junction -Target $physical)
            { New-PinnedGitHooksDirectory $junction ('git-hooks-' + ('c' * 32)) } | Should Throw 'reparse ancestor'
        }
    }
    else {
        # Scenario: A Unix WorkRoot has a symbolic-link ancestor controlled outside the physical directory.
        # Purpose: Exercise the corresponding Unix link-redirection attack without registering a Windows-only item.
        It 'UnitT58b_rejects_a_unix_symbolic_link_workroot_ancestor' {
            $physical = Join-Path $TestDrive 'bootstrap-hook-physical'
            $symbolicLink = Join-Path $TestDrive 'bootstrap-hook-symbolic-link'
            [void][IO.Directory]::CreateDirectory($physical)
            [void](New-Item -ItemType SymbolicLink -Path $symbolicLink -Target $physical)
            { New-PinnedGitHooksDirectory $symbolicLink ('git-hooks-' + ('c' * 32)) } | Should Throw 'reparse ancestor'
        }
    }

    # Scenario: A local file authority drives prepare, validate, finalize, and a fresh aggregate acquisition.
    # Purpose: Exercise cross-phase binding and receipt mutations without network access or candidate-controlled authority code.
    It 'InterT59_executes_all_gate_phases_and_rejects_cross_phase_drift' {
        $source = Join-Path $TestDrive 'phase-authority-source'
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'consumer'))
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'scripts/consumer'))
        [void](Invoke-FixtureGit $source @('init','-q','-b','main'))
        [void](Invoke-FixtureGit $source @('config','user.name','Fixture'))
        [void](Invoke-FixtureGit $source @('config','user.email','fixture@example.test'))
        Copy-Item (Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json') `
            (Join-Path $source 'consumer/consumer-gate-interface.json')
        $fakeGate = @'
param([string]$Interface,[string]$Phase,[string]$AuthorityBindingPath,[string]$BaseRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$Platform,[switch]$TransitionFromLegacy)
if (-not (Test-Path -LiteralPath $AuthorityBindingPath -PathType Leaf)) { exit 20 }
$binding = Get-Content -Raw -LiteralPath $AuthorityBindingPath | ConvertFrom-Json
if ($Phase -eq 'aggregate' -and $binding.scope -cne 'aggregate') { exit 20 }
$environment = [Environment]::GetEnvironmentVariables('Process')
$environmentDump = [ordered]@{}
foreach ($name in @($environment.Keys | Sort-Object)) { $environmentDump[[string]$name] = [string]$environment[$name] }
[IO.File]::WriteAllText((Join-Path $WorkRoot "environment-$Phase.json"),($environmentDump | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
if ($Phase -eq 'prepare') {
    $runtimeRoot = Join-Path $WorkRoot 'runtime/pwsh'
    [void][IO.Directory]::CreateDirectory($runtimeRoot)
    foreach ($file in @(Get-ChildItem -LiteralPath $PSHOME -File -Force -Recurse)) {
        $relative = [IO.Path]::GetRelativePath($PSHOME,$file.FullName)
        $target = Join-Path $runtimeRoot $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        try { [void](New-Item -ItemType HardLink -Path $target -Target $file.FullName -ErrorAction Stop) }
        catch { Copy-Item -LiteralPath $file.FullName -Destination $target }
    }
    $currentExecutable = (Get-Process -Id $PID).Path
    $runtimeExecutable = Join-Path $runtimeRoot ([IO.Path]::GetFileName($currentExecutable))
    $receipt = [ordered]@{
        schemaVersion = 1
        report = 'consumer-runtime-receipt-v1'
        executablePath = $runtimeExecutable
        executableSha256 = (Get-FileHash -LiteralPath $runtimeExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        version = $PSVersionTable.PSVersion.ToString()
        archiveSha256 = ('0' * 64)
    }
    [IO.File]::WriteAllText((Join-Path $WorkRoot 'runtime/consumer-runtime-receipt.json'),($receipt | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
}
if ($Phase -eq 'validate' -and -not (Test-Path -LiteralPath (Join-Path $WorkRoot 'phase-prepare.json'))) { exit 20 }
if ($Phase -eq 'finalize' -and -not (Test-Path -LiteralPath (Join-Path $WorkRoot 'phase-validate.json'))) { exit 20 }
[IO.File]::WriteAllText((Join-Path $WorkRoot "phase-$Phase.json"),($binding | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
        [IO.File]::WriteAllText(
            (Join-Path $source 'scripts/consumer/Invoke-ConsumerSourceGate.ps1'),
            $fakeGate,
            [Text.UTF8Encoding]::new($false)
        )
        [void](Invoke-FixtureGit $source @('add','.'))
        [void](Invoke-FixtureGit $source @('commit','-q','-m','phase authority'))
        $commit = Get-FixtureGitScalar $source @('rev-parse','HEAD')
        $sourceUrl = ([Uri](Resolve-Path $source).Path).AbsoluteUri
        $bootstrapCopy = Join-Path $TestDrive 'Invoke-PinnedAuthority-formal-fixture.ps1'
        $bootstrapText = Get-Content -Raw -Encoding UTF8 $script:BootstrapPath
        $bootstrapText = $bootstrapText.Replace($script:AuthorityRepository, $sourceUrl)
        $bootstrapText = $bootstrapText.Replace(
            'New-PinnedAuthority $WorkRoot ([string]$pin.Value.commit)',
            'New-PinnedAuthority $WorkRoot ([string]$pin.Value.commit) $script:AuthorityRepository -AllowFileProtocol'
        )
        [IO.File]::WriteAllText($bootstrapCopy, $bootstrapText, [Text.UTF8Encoding]::new($false))

        $revision = New-RevisionFixture (Join-Path $TestDrive 'phase-candidate') (Join-Path $TestDrive 'phase-base')
        [void][IO.Directory]::CreateDirectory((Join-Path $revision.CandidateRoot 'config'))
        $pinPath = Join-Path $revision.CandidateRoot 'config/authority-pin.json'
        [IO.File]::WriteAllText(
            $pinPath,
            (@{schemaVersion=1;repository=$sourceUrl;commit=$commit} | ConvertTo-Json -Compress),
            [Text.UTF8Encoding]::new($false)
        )
        $platformWork = Join-Path $TestDrive 'phase-platform-work'
        $aggregateWork = Join-Path $TestDrive 'phase-aggregate-work'
        $env:CONSUMER_GATE_TEST_TEMP_ROOT = $TestDrive
        $env:CONSUMER_GATE_EVENT_REPOSITORY = 'https://example.test/fixture.git'
        $common = @(
            '-BaseRoot',$revision.BaseRoot,'-CandidateRoot',$revision.CandidateRoot,
            '-TriggerEvent','pull_request_target','-BaseRevision',$revision.Base,
            '-CandidateRevision',$revision.Candidate,'-HeadRevision',$revision.Head,
            '-WorkflowRunId','1001','-WorkflowRunAttempt','1'
        )
        function Invoke-FormalBootstrap([string]$Phase,[string]$WorkRoot,[string]$Platform) {
            $script:FormalBootstrapOutput = @(
                & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $bootstrapCopy `
                    -Phase $Phase -WorkRoot $WorkRoot -Platform $Platform @common 2>&1
            )
            $script:FormalBootstrapExitCode = $LASTEXITCODE
            $script:FormalBootstrapExitCode
        }
        function Assert-FormalPhaseOutput([string]$Path,[string]$Phase) {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "Formal $Phase gate did not create its boundary evidence (exit=$script:FormalBootstrapExitCode): " +
                    (@($script:FormalBootstrapOutput) -join ' | ')
            }
        }

        $env:STANDARD_VALIDATION_GITHUB_API_TOKEN = 'phase-token-sentinel'
        Invoke-FormalBootstrap prepare $platformWork windows | Should Be 0
        Assert-FormalPhaseOutput (Join-Path $platformWork 'environment-prepare.json') prepare
        Remove-Item Env:STANDARD_VALIDATION_GITHUB_API_TOKEN -ErrorAction SilentlyContinue
        foreach ($phase in @('validate','finalize')) {
            Invoke-FormalBootstrap $phase $platformWork windows | Should Be 0
            Assert-FormalPhaseOutput (Join-Path $platformWork "environment-$phase.json") $phase
        }
        Invoke-FormalBootstrap aggregate $aggregateWork aggregate | Should Be 0
        Assert-FormalPhaseOutput (Join-Path $aggregateWork 'environment-aggregate.json') aggregate
        (Join-Path $aggregateWork 'authority-git') | Should Exist
        (Join-Path $aggregateWork 'authority') | Should Exist
        (Join-Path $aggregateWork 'authority') | Should Not Be (Join-Path $platformWork 'authority')

        foreach ($phase in @('validate','finalize')) {
            $environment = Get-Content -Raw -LiteralPath (Join-Path $platformWork "environment-$phase.json") | ConvertFrom-Json
            @($environment.PSObject.Properties.Name | Where-Object { $_ -in @(
                        'STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN'
                    ) }).Count | Should Be 0
            ($environment | ConvertTo-Json -Depth 5) | Should Not Match 'phase-token-sentinel'
        }

        $bindingPath = Join-Path $platformWork 'authority-binding.json'
        $bindingText = Get-Content -Raw -LiteralPath $bindingPath
        $binding = $bindingText | ConvertFrom-Json
        foreach ($mutation in @(
                @{ Name='candidate binding'; Apply={ $binding.candidateRevision = ('f' * 40) } },
                @{ Name='scope binding'; Apply={ $binding.scope = 'aggregate' } },
                @{ Name='platform binding'; Apply={ $binding.platform = 'linux' } }
            )) {
            $candidateBinding = $bindingText | ConvertFrom-Json
            $binding = $candidateBinding
            & $mutation.Apply
            [IO.File]::WriteAllText($bindingPath, ($binding | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            Invoke-FormalBootstrap validate $platformWork windows | Should Be 20
            [IO.File]::WriteAllText($bindingPath, $bindingText, [Text.UTF8Encoding]::new($false))
        }

        $runtimePath = Join-Path $platformWork 'runtime/consumer-runtime-receipt.json'
        $runtimeText = Get-Content -Raw -LiteralPath $runtimePath
        $runtime = $runtimeText | ConvertFrom-Json
        $runtime.executableSha256 = 'f' * 64
        [IO.File]::WriteAllText($runtimePath, ($runtime | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Invoke-FormalBootstrap validate $platformWork windows | Should Be 20
        [IO.File]::WriteAllText($runtimePath, $runtimeText, [Text.UTF8Encoding]::new($false))

        $runtime = $runtimeText | ConvertFrom-Json
        $runtime.executablePath = Join-Path $platformWork 'runtime/missing/pwsh'
        [IO.File]::WriteAllText($runtimePath, ($runtime | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Invoke-FormalBootstrap validate $platformWork windows | Should Be 20
        [IO.File]::WriteAllText($runtimePath, $runtimeText, [Text.UTF8Encoding]::new($false))

        $pinText = Get-Content -Raw -LiteralPath $pinPath
        [IO.File]::AppendAllText($pinPath, "`n")
        Invoke-FormalBootstrap validate $platformWork windows | Should Be 20
        [IO.File]::WriteAllText($pinPath, $pinText, [Text.UTF8Encoding]::new($false))

        Remove-Item Env:CONSUMER_GATE_TEST_TEMP_ROOT,Env:CONSUMER_GATE_EVENT_REPOSITORY -ErrorAction SilentlyContinue
    }

    # Scenario: Revision and transition checks are changed in the bootstrap source.
    # Purpose: Preserve explicit merge-parent, push-ancestor, pin-byte, fresh-aggregate, and legacy-base barriers.
    It 'UnitT60_contains_all_event_and_transition_fail_closed_bindings' {
        $text = Get-Content -Raw -Encoding UTF8 $script:BootstrapPath
        $requiredPatterns = @(
            'parents\[0\]', 'parents\[1\]', 'merge-base.*--is-ancestor', 'pinSha256',
            'authority-binding\.json', 'Phase -in.*prepare.*aggregate',
            'Transition base already contains', 'pull_request.*accepted only for transition'
        )
        foreach ($required in $requiredPatterns) { $text | Should Match $required }
    }

    # Scenario: Transition mode starts from a base that already contains either protected bootstrap artifact.
    # Purpose: The one-time candidate-controlled transition cannot be reused after adoption has begun.
    It 'InterT62_rejects_transition_bases_that_already_contain_bootstrap_or_pin' {
        $fixture=New-RevisionFixture (Join-Path $TestDrive 'transition-source') (Join-Path $TestDrive 'transition-base')
        $oldTestTemp=$env:CONSUMER_GATE_TEST_TEMP_ROOT
        $env:CONSUMER_GATE_TEST_TEMP_ROOT=$TestDrive
        try {
            foreach($relative in @('scripts/Invoke-PinnedAuthority.ps1','config/authority-pin.json')) {
                foreach($cleanup in @('scripts/Invoke-PinnedAuthority.ps1','config/authority-pin.json')){Remove-Item -LiteralPath (Join-Path `
                    $fixture.BaseRoot $cleanup) -Force -ErrorAction SilentlyContinue}
                $path=Join-Path $fixture.BaseRoot $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                [IO.File]::WriteAllText($path,'fixture',[Text.UTF8Encoding]::new($false))
                $work=Join-Path $TestDrive ('transition-work-'+[IO.Path]::GetFileName($relative))
                $output=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script:BootstrapPath `
                        -Phase prepare -BaseRoot $fixture.BaseRoot -CandidateRoot $fixture.CandidateRoot `
                        -WorkRoot $work -TriggerEvent pull_request -BaseRevision $fixture.Base `
                        -CandidateRevision $fixture.Candidate -HeadRevision $fixture.Head `
                        -WorkflowRunId 1 -WorkflowRunAttempt 1 -Platform windows -TransitionFromLegacy 2>&1)
                $LASTEXITCODE|Should Be 20
                ($output-join' ')|Should Match 'Transition base already contains'
            }
        } finally { $env:CONSUMER_GATE_TEST_TEMP_ROOT=$oldTestTemp }
    }

    # Scenario: Pull-request, transition, and push revisions are evaluated against real local Git history.
    # Purpose: Accept exact merge/ancestor bindings and reject stale parents, expired merge refs, wrong heads, and unrelated push bases.
    It 'InterT65_enforces_all_three_revision_mappings' {
        $fixture=New-RevisionFixture (Join-Path $TestDrive 'revision-source') (Join-Path $TestDrive 'revision-base')
        Assert-Revisions 'pull_request_target' $fixture.Base $fixture.Candidate $fixture.Head $fixture.BaseRoot $fixture.CandidateRoot
        Assert-Revisions 'pull_request' $fixture.Base $fixture.Candidate $fixture.Head $fixture.BaseRoot $fixture.CandidateRoot
        Assert-Revisions 'push' $fixture.Base $fixture.Candidate $fixture.Candidate $fixture.BaseRoot $fixture.CandidateRoot
        {
            Assert-Revisions 'pull_request_target' $fixture.Older $fixture.Candidate $fixture.Head `
                $fixture.BaseRoot $fixture.CandidateRoot
        } | Should Throw 'base may have advanced'
        {Assert-Revisions 'pull_request_target' $fixture.Base $fixture.Head $fixture.Head $fixture.BaseRoot $fixture.CandidateRoot}|Should `
            Throw 'Candidate checkout HEAD differs'
        {Assert-Revisions 'pull_request' $fixture.Base $fixture.Candidate $fixture.Base $fixture.BaseRoot $fixture.CandidateRoot}|Should Throw
        $unrelatedRoot=Join-Path $TestDrive 'revision-unrelated'
        [void](Invoke-FixtureGit $fixture.CandidateRoot @('worktree','add','-q','--detach',$unrelatedRoot,$fixture.Unrelated))
        {Assert-Revisions 'push' $fixture.Unrelated $fixture.Candidate $fixture.Candidate $unrelatedRoot $fixture.CandidateRoot}|Should Throw 'not an ancestor'
    }

    # Scenario: A local authority commit is on main, then a topic-only commit is requested.
    # Purpose: Exercise immutable acquisition and the official-main ancestry decision without network access.
    It 'InterT70_accepts_main_ancestry_and_rejects_branch_only_or_missing_pins' {
        $source=Join-Path $TestDrive 'authority-source'
        $mainCommit=New-AuthorityFixture $source
        $sourceUrl=([Uri](Resolve-Path $source).Path).AbsoluteUri
        $accepted=New-PinnedAuthority (Join-Path $TestDrive 'accepted') $mainCommit $sourceUrl -AllowFileProtocol
        (Test-Path -LiteralPath (Join-Path $accepted.Root 'authority.txt') -PathType Leaf)|Should Be $true
        [void](Invoke-FixtureGit $source @('checkout','-q','-b','topic'))
        [IO.File]::WriteAllText((Join-Path $source 'topic.txt'),'topic',[Text.UTF8Encoding]::new($false))
        [void](Invoke-FixtureGit $source @('add','topic.txt'))
        [void](Invoke-FixtureGit $source @('commit','-q','-m','topic only'))
        $topicCommit=Get-FixtureGitScalar $source @('rev-parse','HEAD')
        [void](Invoke-FixtureGit $source @('checkout','-q','main'))
        {New-PinnedAuthority (Join-Path $TestDrive 'topic-rejected') $topicCommit $sourceUrl -AllowFileProtocol}|Should Throw 'not on official AII main'
        {New-PinnedAuthority (Join-Path $TestDrive 'missing-rejected') ('f'*40) $sourceUrl -AllowFileProtocol}|Should Throw
    }

    # Scenario: An acquired authority worktree is modified, extended, or truncated after checkout.
    # Purpose: Revalidation rejects changed bytes, extra files, and missing files before another phase runs.
    It 'InterT80_rejects_authority_byte_extra_and_missing_file_drift' {
        $source=Join-Path $TestDrive 'tree-source'
        $commit=New-AuthorityFixture $source
        $acquired=New-PinnedAuthority (Join-Path $TestDrive 'tree-acquired') $commit ([Uri](Resolve-Path $source).Path).AbsoluteUri -AllowFileProtocol
        $path=Join-Path $acquired.Root 'authority.txt'
        [IO.File]::WriteAllText($path,'tampered',[Text.UTF8Encoding]::new($false))
        {Assert-AuthorityTree $acquired.GitRoot $acquired.Root $commit}|Should Throw
        [IO.File]::WriteAllText($path,'authority-v1',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $acquired.Root 'extra.txt'),'extra')
        {Assert-AuthorityTree $acquired.GitRoot $acquired.Root $commit}|Should Throw
        Remove-Item (Join-Path $acquired.Root 'extra.txt')
        Remove-Item $path
        {Assert-AuthorityTree $acquired.GitRoot $acquired.Root $commit}|Should Throw
    }

    # Scenario: Authority trees carry Git link or gitlink modes.
    # Purpose: Symlinks and submodules never become executable authority bytes.
    It 'InterT90_rejects_symlink_and_submodule_tree_modes' {
        foreach($mode in @('120000','160000')){
            $source=Join-Path $TestDrive "unsafe-$mode"
            $base=New-AuthorityFixture $source
            $object=if($mode-eq'160000'){$base}else{[IO.File]::WriteAllText((Join-Path $source 'target.txt'),'authority.txt',[Text.UTF8Encoding]::new($false))
            Get-FixtureGitScalar $source @('hash-object','-w','target.txt')}
            $cacheInfo=[string]::Concat($mode,',',$object,',unsafe-entry')
            [void](Invoke-FixtureGit -Root $source -Arguments @('update-index','--add','--cacheinfo',$cacheInfo))
            [void](Invoke-FixtureGit $source @('commit','-q','-m',"unsafe $mode"))
            $commit=Get-FixtureGitScalar $source @('rev-parse','HEAD')
            {New-PinnedAuthority (Join-Path $TestDrive "unsafe-acquired-$mode") $commit ([Uri](Resolve-Path $source).Path).AbsoluteUri `
                -AllowFileProtocol}|Should Throw 'unsupported entry'
        }
    }
}
