Describe 'Consumer authority bootstrap v1' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:BootstrapPath = Join-Path $script:RepositoryRoot 'consumer/bootstrap/Invoke-PinnedAuthority.ps1'
        . $script:BootstrapPath -DefineFunctionsOnly
        function Invoke-FixtureGit([string]$Root,[string[]]$Arguments) {
            $output=@(& git -c core.autocrlf=false -C $Root @Arguments 2>&1)
            if($LASTEXITCODE-ne0){throw "fixture git failed: $($output-join' ')"};$output
        }
        function Get-FixtureGitScalar([string]$Root,[string[]]$Arguments) {
            ([string](@(Invoke-FixtureGit $Root $Arguments)[0])).Trim()
        }
        function New-AuthorityFixture([string]$Root) {
            [void][IO.Directory]::CreateDirectory($Root);[void](Invoke-FixtureGit $Root @('init','-q','-b','main'))
            [void](Invoke-FixtureGit $Root @('config','user.name','Fixture'));[void](Invoke-FixtureGit $Root @('config','user.email','fixture@example.test'))
            [IO.File]::WriteAllText((Join-Path $Root 'authority.txt'),'authority-v1',[Text.UTF8Encoding]::new($false))
            [void](Invoke-FixtureGit $Root @('add','authority.txt'));[void](Invoke-FixtureGit $Root @('commit','-q','-m','authority fixture'))
            Get-FixtureGitScalar $Root @('rev-parse','HEAD')
        }
        function New-RevisionFixture([string]$Root,[string]$BaseRoot) {
            [void][IO.Directory]::CreateDirectory($Root);[void](Invoke-FixtureGit $Root @('init','-q','-b','main'));[void](Invoke-FixtureGit $Root @('config','user.name','Fixture'));[void](Invoke-FixtureGit $Root @('config','user.email','fixture@example.test'))
            [IO.File]::WriteAllText((Join-Path $Root 'history.txt'),'older');[void](Invoke-FixtureGit $Root @('add','.'));[void](Invoke-FixtureGit $Root @('commit','-q','-m','older'));$older=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [IO.File]::AppendAllText((Join-Path $Root 'history.txt'),' base');[void](Invoke-FixtureGit $Root @('commit','-q','-am','base'));$base=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [void](Invoke-FixtureGit $Root @('checkout','-q','-b','topic'));[IO.File]::WriteAllText((Join-Path $Root 'topic.txt'),'topic');[void](Invoke-FixtureGit $Root @('add','.'));[void](Invoke-FixtureGit $Root @('commit','-q','-m','head'));$head=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [void](Invoke-FixtureGit $Root @('checkout','-q','main'));[void](Invoke-FixtureGit $Root @('merge','-q','--no-ff','topic','-m','merge candidate'));$candidate=Get-FixtureGitScalar $Root @('rev-parse','HEAD')
            [void](Invoke-FixtureGit $Root @('worktree','add','-q','--detach',$BaseRoot,$base))
            $emptyTree='4b825dc642cb6eb9a060e54bf8d69288fbee4904';$unrelated=Get-FixtureGitScalar $Root @('commit-tree',$emptyTree,'-m','unrelated')
            [pscustomobject]@{Older=$older;Base=$base;Head=$head;Candidate=$candidate;Unrelated=$unrelated;CandidateRoot=$Root;BaseRoot=$BaseRoot}
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
        $root = Join-Path $TestDrive 'pin'; [void][IO.Directory]::CreateDirectory((Join-Path $root 'config'))
        $path = Join-Path $root 'config/authority-pin.json'; $utf8 = New-Object Text.UTF8Encoding($false)
        $valid = '{"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '"}'
        [IO.File]::WriteAllText($path,$valid,$utf8); (Read-AuthorityPin $root).Value.commit | Should Be ('a' * 40)
        foreach ($invalid in @(
            '{"schemaVersion":1,"repository":"https://example.org/authority.git","commit":"' + ('a' * 40) + '"}',
            '{"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git"}',
            '{"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '","extra":true}',
            '{"schemaVersion":1,"schemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '"}',
            '{"schemaVersion":1,"SchemaVersion":1,"repository":"https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git","commit":"' + ('a' * 40) + '"}'
        )) { [IO.File]::WriteAllText($path,$invalid,$utf8); { Read-AuthorityPin $root } | Should Throw }
        [IO.File]::WriteAllBytes($path,@(239,187,191) + [Text.Encoding]::UTF8.GetBytes($valid)); { Read-AuthorityPin $root } | Should Throw
        [IO.File]::WriteAllText($path,$valid + (' ' * 4097),$utf8); { Read-AuthorityPin $root } | Should Throw
    }

    # Scenario: The bootstrap is inspected as the byte-for-byte consumer template.
    # Purpose: Preserve the thin built-in-only boundary and fixed formal authority URL.
    It 'UnitT40_keeps_the_bootstrap_thin_and_without_native_or_module_escape_hatches' {
        $lines = @(Get-Content -LiteralPath $script:BootstrapPath -Encoding UTF8)
        $lines.Count | Should BeLessThan 351
        $text = $lines -join "`n"
        $text | Should Not Match '(?im)^\s*(Add-Type|Import-Module)\b|DllImport'
        ([regex]::Matches($text,[regex]::Escape('https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'))).Count | Should Be 1
        $text | Should Match 'protocol\.file\.allow='; $text | Should Match 'core\.hooksPath='; $text | Should Match 'credential\.helper='
        $text | Should Match 'merge-base.*--is-ancestor'; $text | Should Match "'ls-tree', '-r', '-z'"; $text | Should Match 'hash-object'
    }

    # Scenario: Phase environment and interface retirement are authority-owned data.
    # Purpose: Token access remains prepare-only and v1 support cannot disappear silently.
    It 'UnitT50_declares_prepare_only_token_access_and_interface_retirement_evidence' {
        $contract = Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json') | ConvertFrom-Json
        Assert-ConsumerInterface $contract
        @($contract.supportedInterfaces) | Should Contain 'consumer-gate-v1'
        $contract.retiredInterfaces -is [array] | Should Be $true
        @($contract.phaseEnvironment.prepare) | Should Contain 'STANDARD_VALIDATION_GITHUB_API_TOKEN'
        foreach ($phase in @('validate','finalize','aggregate')) { (@($contract.phaseEnvironment.$phase) -join ',') | Should Not Match '(?i)TOKEN|SECRET|PASSWORD|PRIVATE_KEY' }
        $unsupported=($contract|ConvertTo-Json -Depth 10|ConvertFrom-Json);$unsupported.supportedInterfaces=@('consumer-gate-v2');$unsupported.currentInterface='consumer-gate-v2';$unsupported.retiredInterfaces=@([pscustomobject]@{interface='consumer-gate-v1';evidence=@()})
        {Assert-ConsumerInterface $unsupported}|Should Throw 'cannot cross a retired interface boundary'
    }

    # Scenario: A gate child receives only its phase allowlist and returns an unknown or recognized exit code.
    # Purpose: Preserve the minimal subprocess environment and the public exit-code boundary.
    It 'UnitT55_filters_child_environment_and_normalizes_unknown_exit_codes' {
        $root=Join-Path $TestDrive 'process';[void][IO.Directory]::CreateDirectory($root);$interfacePath=Join-Path $root 'interface.json';$childPath=Join-Path $root 'child.ps1';$outputPath=Join-Path $root 'environment.json'
        $contract=Get-Content -Raw -Encoding UTF8 (Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json')|ConvertFrom-Json
        $contract.phaseEnvironment.validate=@($contract.phaseEnvironment.validate)+@('FIXTURE_EXIT_CODE','FIXTURE_OUTPUT')
        [IO.File]::WriteAllText($interfacePath,($contract|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
        $child=@'
param([string]$Interface,[string]$Phase,[string]$AuthorityBindingPath,[string]$BaseRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$Platform,[switch]$TransitionFromLegacy)
[IO.File]::WriteAllText($env:FIXTURE_OUTPUT,(@{allowed=$env:FIXTURE_EXIT_CODE;unlisted=$env:UNLISTED_SENTINEL}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
exit [int]$env:FIXTURE_EXIT_CODE
'@
        [IO.File]::WriteAllText($childPath,$child,(New-Object Text.UTF8Encoding($false)))
        $script:BaseRoot=$root;$script:CandidateRoot=$root;$script:WorkRoot=$root;$script:Platform='windows';$script:TransitionFromLegacy=$false
        $env:FIXTURE_OUTPUT=$outputPath;$env:UNLISTED_SENTINEL='must-not-cross';$env:FIXTURE_EXIT_CODE='9'
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'validate' (Join-Path $root 'binding.json'))|Should Be 30
        $observed=Get-Content -Raw -Encoding UTF8 $outputPath|ConvertFrom-Json;$observed.allowed|Should Be '9';$observed.unlisted|Should BeNullOrEmpty
        $env:FIXTURE_EXIT_CODE='10';(Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'validate' (Join-Path $root 'binding.json'))|Should Be 10
        Remove-Item Env:FIXTURE_OUTPUT,Env:FIXTURE_EXIT_CODE,Env:UNLISTED_SENTINEL -ErrorAction SilentlyContinue
    }

    # Scenario: A prepare child receives the resolver token while the same child in validate does not.
    # Purpose: Exercise phase-scoped credential isolation at the actual child-process boundary.
    It 'UnitT57_passes_the_resolver_token_only_to_prepare' {
        $root=Join-Path $TestDrive 'phase-environment';[void][IO.Directory]::CreateDirectory($root)
        $interfacePath=Join-Path $script:RepositoryRoot 'consumer/consumer-gate-interface.json';$childPath=Join-Path $root 'child.ps1';$outputPath=Join-Path $root 'observed.json'
        $child=@'
param([string]$Interface,[string]$Phase,[string]$AuthorityBindingPath,[string]$BaseRoot,[string]$CandidateRoot,[string]$WorkRoot,[string]$Platform,[switch]$TransitionFromLegacy)
[IO.File]::WriteAllText($env:GITHUB_STEP_SUMMARY,(@{phase=$Phase;token=$env:STANDARD_VALIDATION_GITHUB_API_TOKEN;github=$env:GITHUB_TOKEN}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
exit 0
'@
        [IO.File]::WriteAllText($childPath,$child,(New-Object Text.UTF8Encoding($false)))
        $script:BaseRoot=$root;$script:CandidateRoot=$root;$script:WorkRoot=$root;$script:Platform='windows';$script:TransitionFromLegacy=$false
        $env:GITHUB_STEP_SUMMARY=$outputPath;$env:STANDARD_VALIDATION_GITHUB_API_TOKEN='phase-token-sentinel';$env:GITHUB_TOKEN='must-not-cross'
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'prepare' (Join-Path $root 'binding.json'))|Should Be 0
        $observed=Get-Content -Raw -Encoding UTF8 $outputPath|ConvertFrom-Json;$observed.phase|Should Be 'prepare';$observed.token|Should Be 'phase-token-sentinel';$observed.github|Should BeNullOrEmpty
        (Invoke-ConsumerGateProcess (Get-Process -Id $PID).Path $childPath $interfacePath 'validate' (Join-Path $root 'binding.json'))|Should Be 0
        $observed=Get-Content -Raw -Encoding UTF8 $outputPath|ConvertFrom-Json;$observed.phase|Should Be 'validate';$observed.token|Should BeNullOrEmpty;$observed.github|Should BeNullOrEmpty
        Remove-Item Env:GITHUB_STEP_SUMMARY,Env:STANDARD_VALIDATION_GITHUB_API_TOKEN,Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    }

    # Scenario: Revision and transition checks are changed in the bootstrap source.
    # Purpose: Preserve explicit merge-parent, push-ancestor, pin-byte, fresh-aggregate, and legacy-base barriers.
    It 'UnitT60_contains_all_event_and_transition_fail_closed_bindings' {
        $text = Get-Content -Raw -Encoding UTF8 $script:BootstrapPath
        foreach ($required in @('parents\[0\]','parents\[1\]','merge-base.*--is-ancestor','pinSha256','authority-binding\.json','Phase -in.*prepare.*aggregate','Transition base already contains','pull_request.*accepted only for transition')) { $text | Should Match $required }
    }

    # Scenario: Transition mode starts from a base that already contains either protected bootstrap artifact.
    # Purpose: The one-time candidate-controlled transition cannot be reused after adoption has begun.
    It 'InterT62_rejects_transition_bases_that_already_contain_bootstrap_or_pin' {
        $fixture=New-RevisionFixture (Join-Path $TestDrive 'transition-source') (Join-Path $TestDrive 'transition-base')
        $oldTestTemp=$env:CONSUMER_GATE_TEST_TEMP_ROOT;$env:CONSUMER_GATE_TEST_TEMP_ROOT=$TestDrive
        try {
            foreach($relative in @('scripts/Invoke-PinnedAuthority.ps1','config/authority-pin.json')) {
                foreach($cleanup in @('scripts/Invoke-PinnedAuthority.ps1','config/authority-pin.json')){Remove-Item -LiteralPath (Join-Path $fixture.BaseRoot $cleanup) -Force -ErrorAction SilentlyContinue}
                $path=Join-Path $fixture.BaseRoot $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,'fixture',[Text.UTF8Encoding]::new($false))
                $work=Join-Path $TestDrive ('transition-work-'+[IO.Path]::GetFileName($relative))
                $output=@(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $script:BootstrapPath -Phase prepare -BaseRoot $fixture.BaseRoot -CandidateRoot $fixture.CandidateRoot -WorkRoot $work -TriggerEvent pull_request -BaseRevision $fixture.Base -CandidateRevision $fixture.Candidate -HeadRevision $fixture.Head -WorkflowRunId 1 -WorkflowRunAttempt 1 -Platform windows -TransitionFromLegacy 2>&1)
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
        {Assert-Revisions 'pull_request_target' $fixture.Older $fixture.Candidate $fixture.Head $fixture.BaseRoot $fixture.CandidateRoot}|Should Throw 'base may have advanced'
        {Assert-Revisions 'pull_request_target' $fixture.Base $fixture.Head $fixture.Head $fixture.BaseRoot $fixture.CandidateRoot}|Should Throw 'Candidate checkout HEAD differs'
        {Assert-Revisions 'pull_request' $fixture.Base $fixture.Candidate $fixture.Base $fixture.BaseRoot $fixture.CandidateRoot}|Should Throw
        $unrelatedRoot=Join-Path $TestDrive 'revision-unrelated';[void](Invoke-FixtureGit $fixture.CandidateRoot @('worktree','add','-q','--detach',$unrelatedRoot,$fixture.Unrelated))
        {Assert-Revisions 'push' $fixture.Unrelated $fixture.Candidate $fixture.Candidate $unrelatedRoot $fixture.CandidateRoot}|Should Throw 'not an ancestor'
    }

    # Scenario: A local authority commit is on main, then a topic-only commit is requested.
    # Purpose: Exercise immutable acquisition and the official-main ancestry decision without network access.
    It 'InterT70_accepts_main_ancestry_and_rejects_branch_only_or_missing_pins' {
        $source=Join-Path $TestDrive 'authority-source';$mainCommit=New-AuthorityFixture $source
        $sourceUrl=([Uri](Resolve-Path $source).Path).AbsoluteUri
        $accepted=New-PinnedAuthority (Join-Path $TestDrive 'accepted') $mainCommit $sourceUrl -AllowFileProtocol
        (Test-Path -LiteralPath (Join-Path $accepted.Root 'authority.txt') -PathType Leaf)|Should Be $true
        [void](Invoke-FixtureGit $source @('checkout','-q','-b','topic'));[IO.File]::WriteAllText((Join-Path $source 'topic.txt'),'topic',[Text.UTF8Encoding]::new($false));[void](Invoke-FixtureGit $source @('add','topic.txt'));[void](Invoke-FixtureGit $source @('commit','-q','-m','topic only'))
        $topicCommit=Get-FixtureGitScalar $source @('rev-parse','HEAD');[void](Invoke-FixtureGit $source @('checkout','-q','main'))
        {New-PinnedAuthority (Join-Path $TestDrive 'topic-rejected') $topicCommit $sourceUrl -AllowFileProtocol}|Should Throw 'not on official AII main'
        {New-PinnedAuthority (Join-Path $TestDrive 'missing-rejected') ('f'*40) $sourceUrl -AllowFileProtocol}|Should Throw
    }

    # Scenario: An acquired authority worktree is modified, extended, or truncated after checkout.
    # Purpose: Revalidation rejects changed bytes, extra files, and missing files before another phase runs.
    It 'InterT80_rejects_authority_byte_extra_and_missing_file_drift' {
        $source=Join-Path $TestDrive 'tree-source';$commit=New-AuthorityFixture $source
        $acquired=New-PinnedAuthority (Join-Path $TestDrive 'tree-acquired') $commit ([Uri](Resolve-Path $source).Path).AbsoluteUri -AllowFileProtocol
        $path=Join-Path $acquired.Root 'authority.txt';[IO.File]::WriteAllText($path,'tampered',[Text.UTF8Encoding]::new($false));{Assert-AuthorityTree $acquired.GitRoot $acquired.Root $commit}|Should Throw
        [IO.File]::WriteAllText($path,'authority-v1',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $acquired.Root 'extra.txt'),'extra');{Assert-AuthorityTree $acquired.GitRoot $acquired.Root $commit}|Should Throw
        Remove-Item (Join-Path $acquired.Root 'extra.txt');Remove-Item $path;{Assert-AuthorityTree $acquired.GitRoot $acquired.Root $commit}|Should Throw
    }

    # Scenario: Authority trees carry Git link or gitlink modes.
    # Purpose: Symlinks and submodules never become executable authority bytes.
    It 'InterT90_rejects_symlink_and_submodule_tree_modes' {
        foreach($mode in @('120000','160000')){
            $source=Join-Path $TestDrive "unsafe-$mode";$base=New-AuthorityFixture $source
            $object=if($mode-eq'160000'){$base}else{[IO.File]::WriteAllText((Join-Path $source 'target.txt'),'authority.txt',[Text.UTF8Encoding]::new($false));Get-FixtureGitScalar $source @('hash-object','-w','target.txt')}
            $cacheInfo=[string]::Concat($mode,',',$object,',unsafe-entry')
            [void](Invoke-FixtureGit -Root $source -Arguments @('update-index','--add','--cacheinfo',$cacheInfo));[void](Invoke-FixtureGit $source @('commit','-q','-m',"unsafe $mode"))
            $commit=Get-FixtureGitScalar $source @('rev-parse','HEAD')
            {New-PinnedAuthority (Join-Path $TestDrive "unsafe-acquired-$mode") $commit ([Uri](Resolve-Path $source).Path).AbsoluteUri -AllowFileProtocol}|Should Throw 'unsupported entry'
        }
    }
}
