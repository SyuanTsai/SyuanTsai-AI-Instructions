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
        function ConvertTo-FixtureFileUrl([string]$Path) {
            $fullPath = [IO.Path]::GetFullPath($Path)
            $url = [Uri]::new($fullPath, [UriKind]::Absolute).AbsoluteUri
            if ([string]::IsNullOrWhiteSpace($url)) { throw 'Authority fixture file URL is empty.' }
            if (-not $url.StartsWith('file:///', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Authority fixture file URL is invalid.'
            }
            $url
        }
        function New-BootstrapWorkRootLease([string]$LocalRoot,[string]$Name) {
            $boundary=if(-not[string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){
                [IO.Path]::GetFullPath($env:RUNNER_TEMP)
            }else{[IO.Path]::GetFullPath($LocalRoot)}
            $root=Join-Path $boundary ("p11-$($Name.Substring(0,1))-"+[guid]::NewGuid().ToString('N').Substring(0,8))
            if(Test-Path -LiteralPath $root){throw 'Bootstrap test WorkRoot already exists.'}
            [void][IO.Directory]::CreateDirectory($root)
            [pscustomobject]@{Root=$root;Boundary=$boundary}
        }
        function Remove-BootstrapWorkRootLease($Lease) {
            if($null-eq$Lease-or-not(Test-Path -LiteralPath $Lease.Root)){return}
            $root=[IO.Path]::GetFullPath([string]$Lease.Root)
            $boundary=[IO.Path]::GetFullPath([string]$Lease.Boundary).TrimEnd([IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
            if(-not$root.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){
                throw 'Bootstrap test WorkRoot escaped its cleanup boundary.'
            }
            Remove-Item -LiteralPath $root -Recurse -Force
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
        function New-RevisionFixture([string]$Root,[string]$BaseRoot,[scriptblock]$InitializeTopic) {
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
            if($null-ne$InitializeTopic){& $InitializeTopic $Root}
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

    if ($IsWindows) {
        # Scenario: A Windows fixture path contains a space and is converted to a local file URL.
        # Purpose: Preserve a non-empty file:/// URL that round-trips to the exact absolute Windows path.
        It 'UnitT05_converts_windows_fixture_paths_to_round_trip_file_urls' {
            $path = Join-Path $TestDrive 'x y'
            $expected = [IO.Path]::GetFullPath($path)
            $url = ConvertTo-FixtureFileUrl $path
            $url | Should Not BeNullOrEmpty
            $url.StartsWith('file:///', [StringComparison]::OrdinalIgnoreCase) | Should Be $true
            [IO.Path]::GetFullPath(([Uri]$url).LocalPath) | Should Be $expected
        }
    }
    else {
        # Scenario: A Unix fixture path contains a space and is converted to a local file URL.
        # Purpose: Preserve a non-empty file:/// URL that round-trips to the exact absolute Unix path.
        It 'UnitT06_converts_unix_fixture_paths_to_round_trip_file_urls' {
            $path = '/tmp/x y'
            $expected = [IO.Path]::GetFullPath($path)
            $url = ConvertTo-FixtureFileUrl $path
            $url | Should Not BeNullOrEmpty
            $url.StartsWith('file:///', [StringComparison]::OrdinalIgnoreCase) | Should Be $true
            [IO.Path]::GetFullPath(([Uri]$url).LocalPath) | Should Be $expected
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
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($script:BootstrapPath,[ref]$tokens,[ref]$errors)
        @($errors).Count|Should Be 0
        $authorityFunction=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
            $node.Name-ceq'New-PinnedAuthority'},$true)
        $remoteCalls=@($authorityFunction.Body.FindAll({param($node)
                    $node-is[Management.Automation.Language.CommandAst]-and
                    $node.GetCommandName()-ceq'Invoke-PinnedGit'-and
                    $node.Extent.Text-match "'ls-remote'|'fetch'"
                },$true)|ForEach-Object{([string]$_.Extent.Text).Trim()-replace'\s+',' '})
        $remoteCalls|Should Be @(
            "Invoke-PinnedGit `$gitRoot (`$remote+@('ls-remote','--get-url','origin')) -AllowFileProtocol:`$AllowFileProtocol",
            "Invoke-PinnedGit `$gitRoot (`$remote+@('fetch','--no-tags','--filter=blob:none','origin','+refs/heads/main:refs/remotes/aii/main')) -AllowFileProtocol:`$AllowFileProtocol",
            "Invoke-PinnedGit `$gitRoot (`$remote+@('ls-remote','--get-url','origin')) -AllowFileProtocol:`$AllowFileProtocol",
            "Invoke-PinnedGit `$gitRoot (`$remote+@('fetch','--no-tags','origin',`$Commit)) @(0,1,128) -AllowFileProtocol:`$AllowFileProtocol"
        )
         $text | Should Match "'ls-tree', '-r', '-z'"
         $text | Should Match 'hash-object'
        foreach($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN','GITHUB_TOKEN','GH_TOKEN')){$text|Should Match ([regex]::Escape("'$name'"))}
        $text|Should Match '(?s)function Invoke-PinnedGit.*SetEnvironmentVariable\(\$name,\$null,''Process''\)'
        $text | Should Match 'function Invoke-ConsumerGateProcess\([^)]*Token'
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
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'prepare' (Join-Path $root 'binding.json') `
            'phase-token-sentinel')|Should Be 0
        $observed=Get-Content -Raw -Encoding UTF8 $outputPath|ConvertFrom-Json
        $observed.phase|Should Be 'prepare'
        $observed.token|Should Be 'phase-token-sentinel'
        $observed.github|Should BeNullOrEmpty
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'validate' (Join-Path $root 'binding.json') `
            'phase-token-sentinel')|Should Be 0
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
                    prepare (Join-Path $root 'binding.json') "${stream}-token-sentinel"
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
        $suppressionAssignment = '$credentialLeak = $true'
        ([regex]::Matches($bootstrapText,[regex]::Escape($suppressionAssignment))).Count | Should Be 1
        $mutantText = $bootstrapText.Replace($suppressionAssignment, '$credentialLeak = $false')
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
                        param($root,$leakPath,$interfacePath,$sentinel)
                        $script:BaseRoot=$root
                        $script:CandidateRoot=$root
                        $script:WorkRoot=$root
                        $script:Platform='windows'
                        $script:TransitionFromLegacy=$false
                        Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $leakPath $interfacePath `
                            prepare (Join-Path $root 'binding.json') $sentinel
                    } $root $leakPath $interfacePath $sentinel
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
        It 'UnitT52_rejects_a_windows_junction_workroot_ancestor' {
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
        It 'UnitT53_rejects_a_unix_symbolic_link_workroot_ancestor' {
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
        $workLease=New-BootstrapWorkRootLease $TestDrive 'formal-phases'
        try{
        $source = Join-Path $TestDrive 'phase-authority-source'
        foreach($directory in @('consumer/bootstrap','consumer/workflows','scripts/consumer','scripts','docs/standards')){
            [void][IO.Directory]::CreateDirectory((Join-Path $source $directory))
        }
        [void](Invoke-FixtureGit $source @('init','-q','-b','main'))
        [void](Invoke-FixtureGit $source @('config','user.name','Fixture'))
        [void](Invoke-FixtureGit $source @('config','user.email','fixture@example.test'))
        $sourceUrl = ConvertTo-FixtureFileUrl $source
        $consumerRepository='https://github.com/example/fixture.git'
        foreach($path in @(
                'consumer/bootstrap/Invoke-PinnedAuthority.ps1','consumer/workflows/consumer-gate.yml',
                'consumer/workflows/consumer-gate-transition.yml','scripts/consumer/ConsumerGate.psm1',
                'scripts/consumer/Invoke-GateGitByteCapture.ps1',
                'scripts/consumer/ConsumerManifestClosure.psm1','scripts/consumer/Invoke-ConsumerSourceGate.ps1',
                'scripts/consumer/Invoke-ConsumerValidationChild.ps1','scripts/consumer/Invoke-ConsumerRepositoryCheck.ps1',
                'scripts/Validate-UpstreamAdapter.ps1','docs/standards/upstream-adapter.json',
                'docs/standards/validation-toolchain.json','docs/standards/validation-security-gate.json')){
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $path) -Destination (Join-Path $source $path)
        }
        $platformRuntimeManifest=Import-PowerShellDataFile (Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1')
        foreach($relative in @('platform-runtime.psd1')+@($platformRuntimeManifest.FileList)|Select-Object -Unique){
            $destination=Join-Path (Join-Path $source 'scripts') $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path (Join-Path $script:RepositoryRoot 'scripts') $relative) -Destination $destination
        }
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'tests/fixtures/consumer-gate-validation-runner-fixture.ps1') `
            -Destination (Join-Path $source 'scripts/Invoke-StandardValidation.ps1')
        foreach($productionPath in @('consumer/bootstrap/Invoke-PinnedAuthority.ps1','scripts/consumer/ConsumerGate.psm1',
                'scripts/consumer/Invoke-GateGitByteCapture.ps1','scripts/consumer/Invoke-ConsumerSourceGate.ps1')){
            (Get-FileHash -LiteralPath (Join-Path $source $productionPath) -Algorithm SHA256).Hash|Should Be `
                (Get-FileHash -LiteralPath (Join-Path $script:RepositoryRoot $productionPath) -Algorithm SHA256).Hash
        }
        $interface=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json')|ConvertFrom-Json
        $fixtureEnvironment=@('CONSUMER_GATE_POWERSHELL_METADATA_URI','CONSUMER_GATE_RUNTIME_SOURCE_ROOT',
            'CONSUMER_GATE_RUNTIME_EXECUTABLE_RELATIVE_PATH','CONSUMER_GATE_RESOLVER_SCRIPT_PATH',
            'CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS','CONSUMER_GATE_ACQUISITION_CANCEL_PATH',
            'CONSUMER_GATE_EVENT_LOG_PATH','CONSUMER_GATE_PHASE_ENV_DUMP_PATH')
        $interface.phaseEnvironment.prepare=@($interface.phaseEnvironment.prepare)+$fixtureEnvironment
        $interface.phaseEnvironment.validate=@($interface.phaseEnvironment.validate)+@('CONSUMER_GATE_EVENT_LOG_PATH',
            'CONSUMER_GATE_PHASE_ENV_DUMP_PATH')
        $interface.phaseEnvironment.finalize=@($interface.phaseEnvironment.finalize)+@('CONSUMER_GATE_EVENT_LOG_PATH','CONSUMER_GATE_PHASE_ENV_DUMP_PATH')
        [IO.File]::WriteAllText((Join-Path $source 'consumer/consumer-gate-interface.json'),
            ($interface|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $manifest=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/legacy-migration.json')|ConvertFrom-Json -Depth 100
        (@($manifest.repositories|Where-Object id -eq 'skill-general')[0]).repository=$consumerRepository
        [IO.File]::WriteAllText((Join-Path $source 'consumer/legacy-migration.json'),
            ($manifest|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
        [void](Invoke-FixtureGit $source @('add','.'))
        [void](Invoke-FixtureGit $source @('commit','-q','-m','phase authority'))
        $commit = Get-FixtureGitScalar $source @('rev-parse','HEAD')
        $bootstrapCopy = Join-Path $TestDrive 'Invoke-PinnedAuthority-formal-fixture.ps1'
        $bootstrapText = Get-Content -Raw -Encoding UTF8 $script:BootstrapPath
        $bootstrapText = $bootstrapText.Replace($script:AuthorityRepository, $sourceUrl)
        $bootstrapText = $bootstrapText.Replace(
            'New-PinnedAuthority $WorkRoot ([string]$pin.Value.commit)',
            'New-PinnedAuthority $WorkRoot ([string]$pin.Value.commit) $script:AuthorityRepository -AllowFileProtocol'
        )
        [IO.File]::WriteAllText($bootstrapCopy, $bootstrapText, [Text.UTF8Encoding]::new($false))

        $revision = New-RevisionFixture (Join-Path $TestDrive 'phase-candidate') (Join-Path $TestDrive 'phase-base') {
            param($candidateRoot)
            foreach($directory in @('config','skills/general','scripts','.github/workflows','tests')){
                [void][IO.Directory]::CreateDirectory((Join-Path $candidateRoot $directory))
            }
            Copy-Item (Join-Path $source 'consumer/bootstrap/Invoke-PinnedAuthority.ps1') `
                (Join-Path $candidateRoot 'scripts/Invoke-PinnedAuthority.ps1')
            Copy-Item (Join-Path $source 'consumer/workflows/consumer-gate.yml') `
                (Join-Path $candidateRoot '.github/workflows/consumer-gate.yml')
            [IO.File]::WriteAllText((Join-Path $candidateRoot 'skills/general/SKILL.md'),
                "---`nname: general`ndescription: fixture`n---`n",[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $candidateRoot 'scripts/Test-SkillGeneral.ps1'),'exit 0',
                [Text.UTF8Encoding]::new($false))
            $config=[ordered]@{schemaVersion=1;repositoryId='skill-general';sourceRepository=$consumerRepository
                activeSkills=@('general');repositoryChecks=@(
                    [ordered]@{id='repository-general';kind='general';path='scripts/Test-SkillGeneral.ps1'},
                    [ordered]@{id='repository-pester';kind='pester';path='tests'})}
            [IO.File]::WriteAllText((Join-Path $candidateRoot 'config/consumer-gate.json'),
                ($config|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $candidateRoot 'config/authority-pin.json'),
                (@{schemaVersion=1;repository=$sourceUrl;commit=$commit}|ConvertTo-Json -Compress),
                [Text.UTF8Encoding]::new($false))
        }
        $pinPath = Join-Path $revision.CandidateRoot 'config/authority-pin.json'
        $platformWork = Join-Path $workLease.Root 'p'
        $aggregateWork = Join-Path $workLease.Root 'a'
        $env:CONSUMER_GATE_TEST_TEMP_ROOT = $TestDrive
        $env:CONSUMER_GATE_EVENT_REPOSITORY = $consumerRepository
        $summary=Join-Path $TestDrive 'phase-summary.txt'
        $artifacts=Join-Path $TestDrive 'phase-artifacts'
        [void][IO.Directory]::CreateDirectory($artifacts)
        $env:GITHUB_STEP_SUMMARY=$summary
        $env:CONSUMER_GATE_ARTIFACT_PATHS=$artifacts
        $runtimeSource=Join-Path $workLease.Root 'runtime-source'
        [void][IO.Directory]::CreateDirectory($runtimeSource)
        $runtimeFixtureFiles=@(Get-ChildItem -LiteralPath $PSHOME -File -Force)
        if(Test-Path -LiteralPath (Join-Path $PSHOME 'ref') -PathType Container){
            $runtimeFixtureFiles+=@(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Recurse -File -Force)
        }
        foreach($moduleName in @('Microsoft.PowerShell.Management','Microsoft.PowerShell.Utility')){
            $runtimeFixtureFiles+=@(Get-ChildItem -LiteralPath (Join-Path $PSHOME "Modules/$moduleName") -Recurse -File -Force)
        }
        foreach($file in $runtimeFixtureFiles){
            $target=Join-Path $runtimeSource ([IO.Path]::GetRelativePath($PSHOME,$file.FullName))
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.File]::Copy($file.FullName,$target,$false)
        }
        $assetBytes=[Text.UTF8Encoding]::new($false).GetBytes('fixture archive')
        $assetSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assetBytes)).ToLowerInvariant()
        $assetName="PowerShell-7.99.1-win-$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()).zip"
        $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start()
        $port=([Net.IPEndPoint]$probe.LocalEndpoint).Port;$probe.Stop()
        $ready=Join-Path $TestDrive 'phase-http.ready'
        $serverStart=[Diagnostics.ProcessStartInfo]::new()
        $serverStart.FileName=(Get-Process -Id $PID).Path;$serverStart.UseShellExecute=$false
        foreach($argument in @('-NoProfile','-NonInteractive','-File',
                (Join-Path $script:RepositoryRoot 'tests/fixtures/consumer-gate-http-fixture.ps1'),
                '-Port',[string]$port,'-Mode','success','-ReadyPath',$ready,'-AssetName',$assetName,
                '-AssetSha256',$assetSha,'-Sentinel','phase-token-sentinel')){[void]$serverStart.ArgumentList.Add($argument)}
        $server=[Diagnostics.Process]::new();$server.StartInfo=$serverStart;[void]$server.Start()
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while(-not(Test-Path $ready)-and[DateTime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 25}
        $env:CONSUMER_GATE_POWERSHELL_METADATA_URI="http://127.0.0.1:$port/metadata"
        $env:CONSUMER_GATE_RUNTIME_SOURCE_ROOT=$runtimeSource
        $env:CONSUMER_GATE_RUNTIME_EXECUTABLE_RELATIVE_PATH=[IO.Path]::GetFileName((Get-Process -Id $PID).Path)
        $env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH=Join-Path $script:RepositoryRoot 'tests/fixtures/consumer-gate-resolver-fixture.ps1'
        $env:CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS='10'
        $env:CONSUMER_GATE_ACQUISITION_CANCEL_PATH=Join-Path $TestDrive 'phase-cancel.signal'
        $env:CONSUMER_GATE_EVENT_LOG_PATH=Join-Path $platformWork 'events.log'
        $common = @(
            '-BaseRoot',$revision.BaseRoot,'-CandidateRoot',$revision.CandidateRoot,
            '-TriggerEvent','pull_request_target','-BaseRevision',$revision.Base,
            '-CandidateRevision',$revision.Candidate,'-HeadRevision',$revision.Head,
            '-WorkflowRunId','1001','-WorkflowRunAttempt','1'
        )
        function Invoke-FormalBootstrap([string]$Phase,[string]$WorkRoot,[string]$Platform) {
            [void][IO.Directory]::CreateDirectory($WorkRoot)
            $env:CONSUMER_GATE_PHASE_ENV_DUMP_PATH=Join-Path $WorkRoot "environment-$Phase.json"
            $phaseSentinelHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(`
                    [Text.Encoding]::UTF8.GetBytes('phase-token-sentinel'))).ToLowerInvariant()
            [IO.File]::WriteAllText("$($env:CONSUMER_GATE_PHASE_ENV_DUMP_PATH).sentinel.sha256",$phaseSentinelHash,
                [Text.UTF8Encoding]::new($false))
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
        function Assert-FormalBootstrapExit([int]$Actual,[int]$Expected,[string]$Context) {
            if($Actual-ne$Expected){
                throw "$Context expected exit $Expected but got $Actual`: $(@($script:FormalBootstrapOutput)-join' | ')"
            }
            $Actual | Should Be $Expected
        }

        $env:STANDARD_VALIDATION_GITHUB_API_TOKEN = 'phase-token-sentinel'
        $prepareExit=Invoke-FormalBootstrap prepare $platformWork windows
        if($prepareExit-ne0){
            throw "Formal prepare expected exit 0 but got $prepareExit`: $(@($script:FormalBootstrapOutput)-join' | ')"
        }
        $prepareExit | Should Be 0
        Assert-FormalPhaseOutput (Join-Path $platformWork 'environment-prepare.json') prepare
        $server.WaitForExit(3000)|Should Be $true
        $server.Dispose()
        $residualStart=[Diagnostics.ProcessStartInfo]::new()
        $residualStart.FileName=(Get-Process -Id $PID).Path;$residualStart.UseShellExecute=$false
        $residualStart.RedirectStandardOutput=$true;$residualStart.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-NonInteractive','-File',(Join-Path $platformWork 'authority/scripts/consumer/Invoke-ConsumerSourceGate.ps1'),
                '-Interface','consumer-gate-v1','-Phase','validate','-AuthorityBindingPath',(Join-Path $platformWork 'authority-binding.json'),
                '-BaseRoot',$revision.BaseRoot,'-CandidateRoot',$revision.CandidateRoot,'-WorkRoot',$platformWork,'-Platform','windows')){
            [void]$residualStart.ArgumentList.Add($argument)
        }
        $residualPreserved=@{}
        foreach($name in @('PATH','Path','PATHEXT','SystemRoot','WINDIR','TEMP','TMP','HOME','USERPROFILE','PSModulePath')){
            $value=[Environment]::GetEnvironmentVariable($name,'Process');if($null-ne$value){$residualPreserved[$name]=$value}
        }
        $residualStart.Environment.Clear()
        foreach($name in $residualPreserved.Keys){$residualStart.Environment[$name]=[string]$residualPreserved[$name]}
        $residualStart.Environment['CONSUMER_GATE_EVENT_REPOSITORY']=$consumerRepository
        $residualStart.Environment['CONSUMER_GATE_PHASE_ENV_DUMP_PATH']=Join-Path $platformWork 'environment-validate.json'
        $residualStart.Environment['STANDARD_VALIDATION_GITHUB_API_TOKEN']='phase-token-sentinel'
        [IO.File]::WriteAllText("$($residualStart.Environment['CONSUMER_GATE_PHASE_ENV_DUMP_PATH']).sentinel.sha256",`
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('phase-token-sentinel'))).ToLowerInvariant(),`
            [Text.UTF8Encoding]::new($false))
        $residualProcess=[Diagnostics.Process]::new()
        try{$residualProcess.StartInfo=$residualStart;[void]$residualProcess.Start();$residualProcess.StandardOutput.ReadToEnd()|Out-Null
            $residualProcess.StandardError.ReadToEnd()|Out-Null;$residualProcess.WaitForExit();$residualProcess.ExitCode|Should Be 30}
        finally{$residualStart.Environment.Clear();$residualPreserved.Clear();$residualProcess.Dispose()}
        (Join-Path $platformWork 'validation-artifacts/consumer-core-evidence.json')|Should Not Exist
        $residualEnvironment=Get-Content -Raw -LiteralPath (Join-Path $platformWork 'environment-validate.json')|ConvertFrom-Json
        if(@($residualEnvironment.tokenNames).Count-ne0){
            throw "Residual source gate exposed token-named environment variables: $(@($residualEnvironment.tokenNames)-join',')."
        }
        if(@($residualEnvironment.sentinelValueNames).Count-ne0){
            throw "Residual source gate exposed sentinel-valued environment variables: $(@($residualEnvironment.sentinelValueNames)-join',')."
        }
        Remove-Item Env:STANDARD_VALIDATION_GITHUB_API_TOKEN -ErrorAction SilentlyContinue
        foreach ($phase in @('validate','finalize')) {
            $phaseExit=Invoke-FormalBootstrap $phase $platformWork windows
            if($phaseExit-ne0){
                throw "Formal $phase expected exit 0 but got $phaseExit`: $(@($script:FormalBootstrapOutput)-join' | ')"
            }
            $phaseExit | Should Be 0
            Assert-FormalPhaseOutput (Join-Path $platformWork "environment-$phase.json") $phase
        }
        $evidencePath=Join-Path $platformWork 'validation-artifacts/consumer-core-evidence.json'
        $casePath=[string](Get-Content -Raw -LiteralPath $evidencePath|ConvertFrom-Json).sourceValidation.pesterCaseInventory.path
        $validatedBindingPath=Join-Path $platformWork 'validated-report-binding.json'
        function Set-FormalCaseCount($Value){
            $caseInventory=Get-Content -Raw -LiteralPath $casePath|ConvertFrom-Json
            $caseInventory.caseDiscoveryCount=$Value
            $caseInventory.caseExecutionCount=$Value
            [IO.File]::WriteAllText($casePath,($caseInventory|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            $evidence=Get-Content -Raw -LiteralPath $evidencePath|ConvertFrom-Json
            $evidence.sourceValidation.pesterCaseInventory.sha256=(Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            $validatedBinding=Get-Content -Raw -LiteralPath $validatedBindingPath|ConvertFrom-Json
            $validatedBinding.evidenceSha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($validatedBindingPath,($validatedBinding|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        }
        $formalCountCases=@(
            @{Value='2';Exit=20},@{Value=[double]2.5;Exit=20},@{Value=$true;Exit=20},
            @{Value=[int]::MaxValue;Exit=0},@{Value=[long]::MaxValue;Exit=0}
        )
        foreach($countCase in $formalCountCases){
            Set-FormalCaseCount $countCase.Value
            Remove-Item -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json') -ErrorAction SilentlyContinue
            $countExit=Invoke-FormalBootstrap finalize $platformWork windows
            Assert-FormalBootstrapExit $countExit $countCase.Exit "Formal receipt count type '$($countCase.Value.GetType().Name)'"
        }
        Set-FormalCaseCount ([long]1)
        Remove-Item -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json') -ErrorAction SilentlyContinue
        (Invoke-FormalBootstrap finalize $platformWork windows)|Should Be 0
        $formalLedger=Get-Content -Raw -LiteralPath $casePath|ConvertFrom-Json -Depth 30
        function Write-FormalLedger($Ledger,[bool]$UpdateBindings=$true){
            [IO.File]::WriteAllText($casePath,($Ledger|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
            if($UpdateBindings){
                $evidence=Get-Content -Raw -LiteralPath $evidencePath|ConvertFrom-Json
                $evidence.sourceValidation.pesterCaseInventory.sha256=(Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash.ToLowerInvariant()
                [IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
                $validatedBinding=Get-Content -Raw -LiteralPath $validatedBindingPath|ConvertFrom-Json
                $validatedBinding.evidenceSha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
                [IO.File]::WriteAllText($validatedBindingPath,($validatedBinding|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
            }
        }
        $ledgerMutations=@(
            @{Name='extra property';Apply={param($value)$value|Add-Member -NotePropertyName unexpected -NotePropertyValue 'x';$value}},
            @{Name='missing property';Apply={param($value)$value.PSObject.Properties.Remove('candidateSnapshotSha256');$value}},
            @{Name='unequal counts';Apply={param($value)$value.caseExecutionCount=[long]2;$value}},
            @{Name='wrong coreRunId';Apply={param($value)$value.coreRunId='wrong-run';$value}}
        )
        foreach($mutation in $ledgerMutations){
            $mutated=$formalLedger|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30
            $mutated=& $mutation.Apply $mutated
            Write-FormalLedger $mutated
            Remove-Item -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json') -ErrorAction SilentlyContinue
            Assert-FormalBootstrapExit (Invoke-FormalBootstrap finalize $platformWork windows) 20 "Formal ledger $($mutation.Name)"
            Write-FormalLedger $formalLedger
        }
        [IO.File]::AppendAllText($casePath," `n",[Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json') -ErrorAction SilentlyContinue
        Assert-FormalBootstrapExit (Invoke-FormalBootstrap finalize $platformWork windows) 20 'Formal ledger sha256 drift'
        Write-FormalLedger $formalLedger
        Remove-Item -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json') -ErrorAction SilentlyContinue
        (Invoke-FormalBootstrap finalize $platformWork windows)|Should Be 0
        $mutantAuthority=Join-Path $TestDrive 'formal-receipt-validator-mutant'
        Copy-Item -LiteralPath (Join-Path $platformWork 'authority') -Destination $mutantAuthority -Recurse
        $mutantModulePath=Join-Path $mutantAuthority 'scripts/consumer/ConsumerGate.psm1'
        $mutantText=Get-Content -Raw -LiteralPath $mutantModulePath
        $mutantTokens=$null;$mutantErrors=$null
        $mutantAst=[Management.Automation.Language.Parser]::ParseInput($mutantText,[ref]$mutantTokens,[ref]$mutantErrors)
        @($mutantErrors).Count|Should Be 0
        $receiptFunction=@($mutantAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Write-GateLegReceipt'},$true))[0]
        $projection=@($receiptFunction.Body.FindAll({param($node)$node-is[Management.Automation.Language.AssignmentStatementAst]-and
                    $node.Left.Extent.Text.Trim()-ceq'$inventory'},$true))
        @($projection).Count|Should Be 1
        $mutantText=$mutantText.Insert($projection[0].Extent.StartOffset,"Assert-GatePlatformTestInventory `$cases`n")
        [IO.File]::WriteAllText($mutantModulePath,$mutantText,[Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json') -ErrorAction SilentlyContinue
        $mutantOutput=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File `
                (Join-Path $mutantAuthority 'scripts/consumer/Invoke-ConsumerSourceGate.ps1') -Interface consumer-gate-v1 -Phase finalize `
                -AuthorityBindingPath (Join-Path $platformWork 'authority-binding.json') -BaseRoot $revision.BaseRoot `
                -CandidateRoot $revision.CandidateRoot -WorkRoot $platformWork -Platform windows 2>&1)
        $mutantExit=$LASTEXITCODE
        $mutantExit|Should Be 30
        Remove-Item -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json') -ErrorAction SilentlyContinue
        (Invoke-FormalBootstrap finalize $platformWork windows)|Should Be 0
        $aggregateReceipts=Join-Path $aggregateWork 'receipts'
        [void][IO.Directory]::CreateDirectory($aggregateReceipts)
        $platformReceipt=Get-Content -Raw -LiteralPath (Join-Path $platformWork 'receipts/leg-windows.json')|ConvertFrom-Json
        foreach($receiptPlatform in @('windows','linux','macos')){
            $receipt=$platformReceipt|ConvertTo-Json -Depth 30|ConvertFrom-Json
            $receipt.platform=$receiptPlatform
            [IO.File]::WriteAllText((Join-Path $aggregateReceipts "leg-$receiptPlatform.json"),
                ($receipt|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        }
        $aggregateExit=Invoke-FormalBootstrap aggregate $aggregateWork aggregate
        if($aggregateExit-ne0){
            throw "Formal aggregate expected exit 0 but got $aggregateExit`: $(@($script:FormalBootstrapOutput)-join' | ')"
        }
        $aggregateExit | Should Be 0
        (Join-Path $aggregateWork 'aggregate-receipt.json')|Should Exist
        (Join-Path $aggregateWork 'authority-git') | Should Exist
        (Join-Path $aggregateWork 'authority') | Should Exist
        (Join-Path $aggregateWork 'authority') | Should Not Be (Join-Path $platformWork 'authority')

        foreach ($phase in @('validate','finalize')) {
            $environment = Get-Content -Raw -LiteralPath (Join-Path $platformWork "environment-$phase.json") | ConvertFrom-Json
            @($environment.tokenNames).Count | Should Be 0
            @($environment.sentinelValueNames).Count | Should Be 0
            ($environment | ConvertTo-Json -Depth 5) | Should Not Match 'phase-token-sentinel'
        }
        $phaseMutant=Join-Path $TestDrive 'Invoke-PinnedAuthority-phase-value-mutant.ps1'
        $phaseMutantText=Get-Content -Raw -LiteralPath $bootstrapCopy;$phaseTokens=$null;$phaseErrors=$null
        $phaseAst=[Management.Automation.Language.Parser]::ParseInput($phaseMutantText,[ref]$phaseTokens,[ref]$phaseErrors)
        @($phaseErrors).Count|Should Be 0
        $processFunction=@($phaseAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and
                    $node.Name-ceq'Invoke-ConsumerGateProcess'},$true))[0]
        $credentialAssignment=@($processFunction.Body.FindAll({param($node)
                    $node-is[Management.Automation.Language.AssignmentStatementAst]-and
                    $node.Left.Extent.Text.Trim()-ceq'$credentialNames'
                },$true))
        @($credentialAssignment).Count|Should Be 1
        $phaseInjection=@'
$start.Environment['CONSUMER_GATE_EVENT_REPOSITORY']=$Token
[void]$start.Environment.Remove('STANDARD_VALIDATION_GITHUB_API_TOKEN')
'@
        $phaseMutantText=$phaseMutantText.Insert($credentialAssignment[0].Extent.StartOffset,$phaseInjection+[Environment]::NewLine)
        [IO.File]::WriteAllText($phaseMutant,$phaseMutantText,[Text.UTF8Encoding]::new($false))
        $bindingPath=Join-Path $platformWork 'authority-binding.json'
        $bindingOriginal=Get-Content -Raw -LiteralPath $bindingPath
        $mutantBinding=$bindingOriginal|ConvertFrom-Json
        $mutantBinding.bootstrapSha256=(Get-FileHash -LiteralPath $phaseMutant -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($bindingPath,($mutantBinding|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        try{
            foreach($phase in @('validate','finalize')){
                $env:STANDARD_VALIDATION_GITHUB_API_TOKEN='phase-token-sentinel'
                $env:CONSUMER_GATE_PHASE_ENV_DUMP_PATH=Join-Path $platformWork "environment-$phase.json"
                $phaseSentinelHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                        [Text.Encoding]::UTF8.GetBytes('phase-token-sentinel'))).ToLowerInvariant()
                [IO.File]::WriteAllText("$($env:CONSUMER_GATE_PHASE_ENV_DUMP_PATH).sentinel.sha256",$phaseSentinelHash,
                    [Text.UTF8Encoding]::new($false))
                $mutantOutput=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $phaseMutant `
                    -Phase $phase -WorkRoot $platformWork -Platform windows @common 2>&1)
                $mutantPhaseExit=$LASTEXITCODE
                $mutantPhaseExit|Should Be $(if($phase-ceq'validate'){30}else{20})
                $mutantEnvironment=Get-Content -Raw -LiteralPath (Join-Path $platformWork "environment-$phase.json")|ConvertFrom-Json
                @($mutantEnvironment.sentinelValueNames)|Should Be @('CONSUMER_GATE_EVENT_REPOSITORY')
                {if(@($mutantEnvironment.sentinelValueNames).Count-ne0){
                        throw "PHASE_SENTINEL_VALUE_ORACLE_MISMATCH|$(@($mutantEnvironment.sentinelValueNames)-join',')"
                    }}|Should Throw 'PHASE_SENTINEL_VALUE_ORACLE_MISMATCH'
            }
        }finally{
            Remove-Item Env:STANDARD_VALIDATION_GITHUB_API_TOKEN -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText($bindingPath,$bindingOriginal,[Text.UTF8Encoding]::new($false))
        }
        $boundaryEvents=@(Get-Content -LiteralPath (Join-Path $platformWork 'events.log'))
        @($boundaryEvents[0..2])|Should Be @('runtime-installed','source-tools-prepared','source-report-asserted')
        @($boundaryEvents|Select-Object -Skip 3|Where-Object{$_-cne'source-report-asserted'}).Count|Should Be 0

        $bindingPath = Join-Path $platformWork 'authority-binding.json'
        $bindingText = Get-Content -Raw -LiteralPath $bindingPath
        $binding = $bindingText | ConvertFrom-Json
        $bindingValueMutations=[ordered]@{
            schemaVersion=2;scope='aggregate';interface='consumer-gate-v2';repository='https://example.test/other.git'
            commit=('f'*40);aiiMainTip=('f'*40);treeSha=('f'*40);baseRevision=('f'*40);candidateRevision=('f'*40)
            headRevision=('f'*40);triggerEvent='push';runId=('f'*32);platform='linux';pinSha256=('f'*64)
            bootstrapSha256=('f'*64)
        }
        (@($binding.PSObject.Properties.Name)-join"`n") | Should Be (@($bindingValueMutations.Keys)-join"`n")
        foreach ($property in $bindingValueMutations.Keys) {
            $candidateBinding = $bindingText | ConvertFrom-Json
            $candidateBinding.$property=$bindingValueMutations[$property]
            [IO.File]::WriteAllText($bindingPath, ($candidateBinding | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
            Assert-FormalBootstrapExit $mutationExit 20 "Binding value mutation '$property'"
            [IO.File]::WriteAllText($bindingPath, $bindingText, [Text.UTF8Encoding]::new($false))
        }
        foreach($property in $bindingValueMutations.Keys){
            $candidateBinding=$bindingText|ConvertFrom-Json
            $candidateBinding.PSObject.Properties.Remove($property)
            [IO.File]::WriteAllText($bindingPath,($candidateBinding|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
            Assert-FormalBootstrapExit $mutationExit 30 "Binding missing-property mutation '$property'"
            [IO.File]::WriteAllText($bindingPath,$bindingText,[Text.UTF8Encoding]::new($false))
        }
        $candidateBinding=$bindingText|ConvertFrom-Json
        $candidateBinding|Add-Member -NotePropertyName unknownBinding -NotePropertyValue blocked
        [IO.File]::WriteAllText($bindingPath,($candidateBinding|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
        Assert-FormalBootstrapExit $mutationExit 30 'Binding unknown-property mutation'
        [IO.File]::WriteAllText($bindingPath,$bindingText,[Text.UTF8Encoding]::new($false))

        Move-Item -LiteralPath $bindingPath -Destination "$bindingPath.moved"
        $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
        Assert-FormalBootstrapExit $mutationExit 30 'Binding missing-file mutation'
        Move-Item -LiteralPath "$bindingPath.moved" -Destination $bindingPath

        $runtimePath = Join-Path $platformWork 'runtime/consumer-runtime-receipt.json'
        $runtimeText = Get-Content -Raw -LiteralPath $runtimePath
        $runtime=$runtimeText|ConvertFrom-Json
        $runtimeMutations=[ordered]@{
            schemaVersion=2;report='consumer-runtime-receipt-v2';executablePath=(Join-Path $platformWork 'runtime/missing/pwsh')
            executableSha256=('f'*64);version='invalid';archiveSha256=('f'*63)
        }
        (@($runtime.PSObject.Properties.Name)-join"`n") | Should Be (@($runtimeMutations.Keys)-join"`n")
        foreach($property in $runtimeMutations.Keys){
            $candidateRuntime=$runtimeText|ConvertFrom-Json
            $candidateRuntime.$property=$runtimeMutations[$property]
            [IO.File]::WriteAllText($runtimePath,($candidateRuntime|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
            Assert-FormalBootstrapExit $mutationExit 20 "Runtime value mutation '$property'"
            [IO.File]::WriteAllText($runtimePath,$runtimeText,[Text.UTF8Encoding]::new($false))
        }
        foreach($property in $runtimeMutations.Keys){
            $candidateRuntime=$runtimeText|ConvertFrom-Json
            $candidateRuntime.PSObject.Properties.Remove($property)
            [IO.File]::WriteAllText($runtimePath,($candidateRuntime|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
            Assert-FormalBootstrapExit $mutationExit 30 "Runtime missing-property mutation '$property'"
            [IO.File]::WriteAllText($runtimePath,$runtimeText,[Text.UTF8Encoding]::new($false))
        }
        $candidateRuntime=$runtimeText|ConvertFrom-Json
        $candidateRuntime|Add-Member -NotePropertyName unknownReceipt -NotePropertyValue blocked
        [IO.File]::WriteAllText($runtimePath,($candidateRuntime|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
        Assert-FormalBootstrapExit $mutationExit 30 'Runtime unknown-property mutation'
        [IO.File]::WriteAllText($runtimePath,$runtimeText,[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $runtimePath -Destination "$runtimePath.moved"
        $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
        Assert-FormalBootstrapExit $mutationExit 30 'Runtime missing-file mutation'
        Move-Item -LiteralPath "$runtimePath.moved" -Destination $runtimePath

        $aggregateReuse=Join-Path $workLease.Root 'r'
        [void][IO.Directory]::CreateDirectory($aggregateReuse)
        Copy-Item -LiteralPath $bindingPath -Destination (Join-Path $aggregateReuse 'authority-binding.json')
        $mutationExit=Invoke-FormalBootstrap aggregate $aggregateReuse aggregate
        Assert-FormalBootstrapExit $mutationExit 20 'Aggregate reused-platform-binding mutation'

        $pinText = Get-Content -Raw -LiteralPath $pinPath
        [IO.File]::AppendAllText($pinPath, "`n")
        $mutationExit=Invoke-FormalBootstrap validate $platformWork windows
        Assert-FormalBootstrapExit $mutationExit 20 'Authority pin byte mutation'
        [IO.File]::WriteAllText($pinPath, $pinText, [Text.UTF8Encoding]::new($false))

        }finally{
        Remove-Item Env:CONSUMER_GATE_TEST_TEMP_ROOT,Env:CONSUMER_GATE_EVENT_REPOSITORY,Env:GITHUB_STEP_SUMMARY,
            Env:CONSUMER_GATE_ARTIFACT_PATHS,Env:CONSUMER_GATE_POWERSHELL_METADATA_URI,
            Env:CONSUMER_GATE_RUNTIME_SOURCE_ROOT,Env:CONSUMER_GATE_RUNTIME_EXECUTABLE_RELATIVE_PATH,
            Env:CONSUMER_GATE_RESOLVER_SCRIPT_PATH,Env:CONSUMER_GATE_ACQUISITION_TIMEOUT_SECONDS,
            Env:CONSUMER_GATE_ACQUISITION_CANCEL_PATH,Env:CONSUMER_GATE_EVENT_LOG_PATH,
            Env:CONSUMER_GATE_PHASE_ENV_DUMP_PATH -ErrorAction SilentlyContinue
        Remove-BootstrapWorkRootLease $workLease
        }
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
        $workLease=New-BootstrapWorkRootLease $TestDrive 'transition'
        $oldTestTemp=$env:CONSUMER_GATE_TEST_TEMP_ROOT
        $env:CONSUMER_GATE_TEST_TEMP_ROOT=$TestDrive
        try {
            $transitionCase=0
            foreach($relative in @('scripts/Invoke-PinnedAuthority.ps1','config/authority-pin.json')) {
                $transitionCase++
                foreach($cleanup in @('scripts/Invoke-PinnedAuthority.ps1','config/authority-pin.json')){Remove-Item -LiteralPath (Join-Path `
                    $fixture.BaseRoot $cleanup) -Force -ErrorAction SilentlyContinue}
                $path=Join-Path $fixture.BaseRoot $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
                [IO.File]::WriteAllText($path,'fixture',[Text.UTF8Encoding]::new($false))
                $work=Join-Path $workLease.Root "w$transitionCase"
                $output=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script:BootstrapPath `
                        -Phase prepare -BaseRoot $fixture.BaseRoot -CandidateRoot $fixture.CandidateRoot `
                        -WorkRoot $work -TriggerEvent pull_request -BaseRevision $fixture.Base `
                        -CandidateRevision $fixture.Candidate -HeadRevision $fixture.Head `
                        -WorkflowRunId 1 -WorkflowRunAttempt 1 -Platform windows -TransitionFromLegacy 2>&1)
                $LASTEXITCODE|Should Be 20
                ($output-join' ')|Should Match 'Transition base already contains'
            }
        } finally {
            $env:CONSUMER_GATE_TEST_TEMP_ROOT=$oldTestTemp
            Remove-BootstrapWorkRootLease $workLease
        }
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
        $sourceUrl=ConvertTo-FixtureFileUrl $source
        $accepted=New-PinnedAuthority (Join-Path $TestDrive 'accepted') $mainCommit $sourceUrl -AllowFileProtocol
        (Test-Path -LiteralPath (Join-Path $accepted.Root 'authority.txt') -PathType Leaf)|Should Be $true
        $gitConfigNames=@('GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0')
        $savedGitConfig=@{}
        foreach($name in $gitConfigNames){$savedGitConfig[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        try{
            $env:GIT_CONFIG_COUNT='1';$env:GIT_CONFIG_KEY_0='remote.origin.url';$env:GIT_CONFIG_VALUE_0=''
            $isolated=New-PinnedAuthority (Join-Path $TestDrive 'config-isolated') $mainCommit $sourceUrl -AllowFileProtocol
            (Test-Path -LiteralPath (Join-Path $isolated.Root 'authority.txt') -PathType Leaf)|Should Be $true
        }finally{
            foreach($name in $gitConfigNames){[Environment]::SetEnvironmentVariable($name,$savedGitConfig[$name],'Process')}
        }
        [void](Invoke-FixtureGit $source @('checkout','-q','-b','topic'))
        [IO.File]::WriteAllText((Join-Path $source 'topic.txt'),'topic',[Text.UTF8Encoding]::new($false))
        [void](Invoke-FixtureGit $source @('add','topic.txt'))
        [void](Invoke-FixtureGit $source @('commit','-q','-m','topic only'))
        $topicCommit=Get-FixtureGitScalar $source @('rev-parse','HEAD')
        [void](Invoke-FixtureGit $source @('checkout','-q','main'))
        {New-PinnedAuthority (Join-Path $TestDrive 'topic-rejected') $topicCommit $sourceUrl -AllowFileProtocol}|Should Throw 'not on official AII main'
        {New-PinnedAuthority (Join-Path $TestDrive 'missing-rejected') ('f'*40) $sourceUrl -AllowFileProtocol}|Should Throw
    }

    # Scenario: Authority acquisition runs with isolated global Git config and produces a detached worktree with a persistent canonical origin.
    # Purpose: The validator's exact local-origin source-binding path must pass, while deleting the persistent-origin statement must reproduce the hosted-runner failure.
    It 'InterT75_persists_origin_for_validator_binding_with_isolated_git_config' {
        $source=Join-Path $TestDrive 'origin-source'
        [void](New-AuthorityFixture $source)
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'scripts'))
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardValidation.ps1') `
            -Destination (Join-Path $source 'scripts/Invoke-StandardValidation.ps1')
        $runtimeManifest=Import-PowerShellDataFile (Join-Path $script:RepositoryRoot 'scripts/platform-runtime.psd1')
        foreach($relative in @($runtimeManifest.FileList)){
            $destination=Join-Path $source "scripts/$relative"
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot "scripts/$relative") -Destination $destination
        }
        [void](Invoke-FixtureGit $source @('add','scripts'))
        [void](Invoke-FixtureGit $source @('commit','-q','-m','add validator'))
        $commit=Get-FixtureGitScalar $source @('rev-parse','HEAD')
        $sourceUrl=ConvertTo-FixtureFileUrl $source
        $isolatedHome=Join-Path $TestDrive 'isolated-home'
        [void][IO.Directory]::CreateDirectory($isolatedHome)
        $isolatedGlobal=Join-Path $isolatedHome 'gitconfig'
        [IO.File]::WriteAllText($isolatedGlobal,'',[Text.UTF8Encoding]::new($false))
        $savedHome=$env:HOME;$savedGlobal=$env:GIT_CONFIG_GLOBAL;$savedPath=$env:PATH
        $savedHooks=$script:PinnedGitHooksPath
        $env:HOME=$isolatedHome;$env:GIT_CONFIG_GLOBAL=$isolatedGlobal
        try{
            $accepted=New-PinnedAuthority (Join-Path $TestDrive 'origin-accepted') $commit $sourceUrl -AllowFileProtocol
            (Get-FixtureGitScalar $accepted.GitRoot @('config','--local','--get-all','remote.origin.url'))|Should BeExactly $sourceUrl
            $detached=Invoke-PinnedGit $accepted.Root @('symbolic-ref','-q','HEAD') @(0,1) -AllowFileProtocol
            $detached.ExitCode|Should Be 1
            . (Join-Path $accepted.Root 'scripts/Invoke-StandardValidation.ps1') `
                -CandidateRoot $accepted.Root -AdapterPath (Join-Path $accepted.Root 'unused-adapter.json') `
                -ArtifactsRoot (Join-Path $accepted.Root 'unused-artifacts') `
                -SourceRepository 'https://example.test/source.git' -SourceRevision ('a'*40) -BaseRevision ('b'*40) `
                -DefineFunctionsOnly
            if($IsWindows){
                $shimRoot=Join-Path $TestDrive 'single-link-git'
                [void][IO.Directory]::CreateDirectory($shimRoot)
                $resolvedGit=(Get-Command git.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
                $gitExecPathOutput=@(& $resolvedGit --exec-path 2>$null)
                if($LASTEXITCODE-ne 0-or$gitExecPathOutput.Count-ne 1-or[string]::IsNullOrWhiteSpace([string]$gitExecPathOutput[0])){
                    throw "Git did not report one usable exec path: $resolvedGit"
                }
                $gitExecPath=[IO.Path]::GetFullPath(([string]$gitExecPathOutput[0]).Trim())
                if(-not(Test-Path -LiteralPath $gitExecPath -PathType Container)){throw "The Git exec path is missing: $gitExecPath"}
                $gitPrefix=Split-Path -Parent (Split-Path -Parent $gitExecPath)
                $realGit=Join-Path $gitPrefix 'bin/git.exe'
                if(-not(Test-Path -LiteralPath $realGit -PathType Leaf)){throw "The Git for Windows binary is missing: $realGit"}
                $realGit=(Get-Item -LiteralPath $realGit).FullName
                $realGitDirectory=Split-Path -Parent $realGit
                $shimGit=Join-Path $shimRoot 'git.exe'
                Copy-Item -LiteralPath $realGit -Destination $shimGit
                $env:PATH="$shimRoot$([IO.Path]::PathSeparator)$realGitDirectory$([IO.Path]::PathSeparator)$savedPath"
                (Get-Command git.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source|Should BeExactly $shimGit
                $childPathEntries=@((Get-StandardValidationChildEnvironment -Environment @{})['PATH']-split[IO.Path]::PathSeparator)
                $childPathEntries[0]|Should BeExactly $shimRoot
                $childPathEntries[1]|Should BeExactly $realGitDirectory
            }
            $originResult=Invoke-StandardCoreGit -RepositoryRoot $accepted.Root -WorkingDirectory $accepted.Root `
                -Arguments @('config','--local','--get-all','remote.origin.url')
            $originValues=@(([string]$originResult.stdout-split"`r?`n")|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
            $originValues.Count|Should Be 1
            $originValues[0]|Should BeExactly $sourceUrl

            $mutant=Join-Path $TestDrive 'Invoke-PinnedAuthority-no-origin.ps1'
            $sourceText=Get-Content -Raw -LiteralPath $script:BootstrapPath
            $tokens=$null;$errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput($sourceText,[ref]$tokens,[ref]$errors)
            @($errors).Count|Should Be 0
            $authorityFunction=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'New-PinnedAuthority'},$true)
            $originStatement=@($authorityFunction.Body.FindAll({param($node)
                        $node-is[Management.Automation.Language.PipelineAst]-and
                        $node.Parent-is[Management.Automation.Language.NamedBlockAst]-and
                        $node.Extent.Text-match "Invoke-PinnedGit.*'remote','add','origin'"
                    },$true))
            $originStatement.Count|Should Be 1
            $mutantText=$sourceText.Remove($originStatement[0].Extent.StartOffset,$originStatement[0].Extent.EndOffset-$originStatement[0].Extent.StartOffset)
            [IO.File]::WriteAllText($mutant,$mutantText,[Text.UTF8Encoding]::new($false))
            . $mutant -DefineFunctionsOnly
            $script:PinnedGitHooksPath=$savedHooks
            $mutated=New-PinnedAuthority (Join-Path $TestDrive 'origin-mutated') $commit $sourceUrl -AllowFileProtocol
            {Invoke-StandardCoreGit -RepositoryRoot $mutated.Root -WorkingDirectory $mutated.Root `
                    -Arguments @('config','--local','--get-all','remote.origin.url')}|Should Throw 'Git source binding command failed'
        }finally{
            $env:HOME=$savedHome;$env:GIT_CONFIG_GLOBAL=$savedGlobal;$env:PATH=$savedPath
            . $script:BootstrapPath -DefineFunctionsOnly
            $script:PinnedGitHooksPath=$savedHooks
        }
    }

    # Scenario: An acquired authority worktree is modified, extended, or truncated after checkout.
    # Purpose: Revalidation rejects changed bytes, extra files, and missing files before another phase runs.
    It 'InterT80_rejects_authority_byte_extra_and_missing_file_drift' {
        $source=Join-Path $TestDrive 'tree-source'
        $commit=New-AuthorityFixture $source
        $acquired=New-PinnedAuthority (Join-Path $TestDrive 'tree-acquired') $commit (ConvertTo-FixtureFileUrl $source) -AllowFileProtocol
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
            {New-PinnedAuthority (Join-Path $TestDrive "unsafe-acquired-$mode") $commit (ConvertTo-FixtureFileUrl $source) `
                -AllowFileProtocol}|Should Throw 'unsupported entry'
        }
    }
}
