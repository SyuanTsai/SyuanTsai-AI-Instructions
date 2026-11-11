$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $script:RepositoryRoot 'scripts/Get-WindowsCorePlan.ps1') -DefineFunctionsOnly
. (Join-Path $script:RepositoryRoot 'scripts/Assert-WindowsCoreAggregate.ps1') -DefineFunctionsOnly

function Set-WindowsCoreTestText {
    param([Parameter(Mandatory = $true)][string] $Path,[Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Invoke-WindowsCoreTestGit {
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return ($output -join "`n").Trim()
}

function Invoke-WindowsCoreTestGitBytes {
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $startInfo=[Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName='git'
    $startInfo.WorkingDirectory=[IO.Path]::GetFullPath($Root)
    $startInfo.UseShellExecute=$false
    $startInfo.RedirectStandardOutput=$true
    $startInfo.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$startInfo.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$startInfo
    try{
        if(-not $process.Start()){throw 'git did not start.'}
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $stream=[IO.MemoryStream]::new()
        try{$process.StandardOutput.BaseStream.CopyTo($stream);$bytes=$stream.ToArray()}finally{$stream.Dispose()}
        $process.WaitForExit();$stderr=$stderrTask.GetAwaiter().GetResult()
        if($process.ExitCode-ne0){throw "git $($Arguments-join' ') failed: $stderr"}
        return ,$bytes
    }finally{$process.Dispose()}
}

function New-WindowsCoreTestLiteralTreeObject {
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][byte[]] $Bytes)
    $startInfo=[Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName='git';$startInfo.WorkingDirectory=[IO.Path]::GetFullPath($Root);$startInfo.UseShellExecute=$false
    $startInfo.RedirectStandardInput=$true;$startInfo.RedirectStandardOutput=$true;$startInfo.RedirectStandardError=$true
    foreach($argument in @('hash-object','--literally','-t','tree','-w','--stdin')){[void]$startInfo.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$startInfo
    try{
        if(-not $process.Start()){throw 'git hash-object did not start.'}
        $process.StandardInput.BaseStream.Write($Bytes,0,$Bytes.Length);$process.StandardInput.BaseStream.Flush();$process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();$process.WaitForExit()
        if($process.ExitCode-ne0){throw "git hash-object --literally failed: $stderr"}
        $hash=$stdout.Trim();if($hash-notmatch'^[0-9a-f]{40}$'){throw "Literal tree hash is invalid: '$hash'."}
        return $hash
    }finally{$process.Dispose()}
}

function Find-WindowsCoreTestByteSequence {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes,[Parameter(Mandatory = $true)][byte[]] $Needle)
    for($index=0;$index-le$Bytes.Length-$Needle.Length;$index++){
        $matches=$true
        for($offset=0;$offset-lt$Needle.Length;$offset++){if($Bytes[$index+$offset]-ne$Needle[$offset]){$matches=$false;break}}
        if($matches){return $index}
    }
    return -1
}

function New-WindowsCoreTestUnsafePathMerge {
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][string] $DocsLeaf)
    if($DocsLeaf.Contains('/')){throw 'Unsafe fixture leaf must be a single raw tree component.'}
    $blobSource=Join-Path $Root '.unsafe-path-blob';Set-WindowsCoreTestText $blobSource "changed`n"
    $blob=Invoke-WindowsCoreTestGit $Root @('hash-object','-w','--','.unsafe-path-blob');Remove-Item -LiteralPath $blobSource -Force
    if($blob-notmatch'^[0-9a-f]{40}$'){throw "Fixture blob hash is invalid: '$blob'."}
    $blobBytes=[Convert]::FromHexString($blob)
    $header=[Text.Encoding]::UTF8.GetBytes("100644 $DocsLeaf"+[char]0)
    $entry=[byte[]]::new($header.Length+$blobBytes.Length);[Array]::Copy($header,0,$entry,0,$header.Length);[Array]::Copy($blobBytes,0,$entry,$header.Length,$blobBytes.Length)
    $base=Invoke-WindowsCoreTestGit $Root @('rev-parse','HEAD')
    $docsBytes=Invoke-WindowsCoreTestGitBytes $Root @('cat-file','tree',"$base`:docs")
    $newDocs=[byte[]]::new($docsBytes.Length+$entry.Length)
    if([string]::CompareOrdinal($DocsLeaf,'standards')-lt0){[Array]::Copy($entry,0,$newDocs,0,$entry.Length);[Array]::Copy($docsBytes,0,$newDocs,$entry.Length,$docsBytes.Length)}
    else{[Array]::Copy($docsBytes,0,$newDocs,0,$docsBytes.Length);[Array]::Copy($entry,0,$newDocs,$docsBytes.Length,$entry.Length)}
    $docsTree=New-WindowsCoreTestLiteralTreeObject -Root $Root -Bytes $newDocs
    $rootBytes=Invoke-WindowsCoreTestGitBytes $Root @('cat-file','tree',"$base`^{tree}")
    $docsMarker=[Text.Encoding]::ASCII.GetBytes('40000 docs'+[char]0)
    $markerIndex=Find-WindowsCoreTestByteSequence -Bytes $rootBytes -Needle $docsMarker
    if($markerIndex-lt0){throw 'Fixture root tree did not contain docs.'}
    $docsHashOffset=$markerIndex+$docsMarker.Length
    [Array]::Copy([Convert]::FromHexString($docsTree),0,$rootBytes,$docsHashOffset,20)
    $topicTree=New-WindowsCoreTestLiteralTreeObject -Root $Root -Bytes $rootBytes
    $topic=Invoke-WindowsCoreTestGit $Root @('commit-tree',$topicTree,'-p',$base,'-m','topic')
    $merge=Invoke-WindowsCoreTestGit $Root @('commit-tree',$topicTree,'-p',$base,'-p',$topic,'-m','merge')
    Invoke-WindowsCoreTestGit $Root @('update-ref','refs/heads/main',$merge,$base)|Out-Null
    return $topic
}

function New-WindowsCoreTestRepository {
    param([Parameter(Mandatory = $true)][string] $Root)
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Invoke-WindowsCoreTestGit $Root @('init','-b','main') | Out-Null
    Invoke-WindowsCoreTestGit $Root @('config','user.email','ci@example.test') | Out-Null
    Invoke-WindowsCoreTestGit $Root @('config','user.name','CI Fixture') | Out-Null
    Invoke-WindowsCoreTestGit $Root @('config','core.autocrlf','false') | Out-Null
    Invoke-WindowsCoreTestGit $Root @('config','core.safecrlf','false') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'scripts'),(Join-Path $Root 'tests'),(Join-Path $Root 'docs/standards') | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Get-WindowsCorePlan.ps1') -Destination (Join-Path $Root 'scripts/Get-WindowsCorePlan.ps1')
    $authority = @(
        'internal-source-continuation.Tests.ps1','skill-repository-standard.Tests.ps1','skill-repository-workflows.Tests.ps1',
        'standard-authority-entry-preflight.Tests.ps1','standard-entry-point-binding.Tests.ps1','standard-core-pester-adapter.Tests.ps1'
    )
    $gate = "function Get-AuthorityTestPaths { param([string]`$Root) @(`n" + (($authority | ForEach-Object { "    Join-Path `$Root 'tests/$_'" }) -join "`n") + "`n) }`n"
    Set-WindowsCoreTestText (Join-Path $Root 'scripts/Invoke-StandardAuthorityGate.ps1') $gate
    foreach ($name in $authority) { Set-WindowsCoreTestText (Join-Path $Root "tests/$name") "Describe '$name' {}`n" }
    Set-WindowsCoreTestText (Join-Path $Root 'tests/licensing-scope.Tests.ps1') "Describe 'licensing' { It 'UnitT10_fixed' {} }`n"
    Set-WindowsCoreTestText (Join-Path $Root 'tests/ai-instructions-contract.Tests.ps1') "Describe 'instructions' { It 'UnitT10_fixed' {} }`n"
    Set-WindowsCoreTestText (Join-Path $Root 'tests/source.Tests.ps1') "Describe 'source' { It 'UnitT10_source' {} }`n"
    $skips = [ordered]@{schemaVersion=1;platforms=[ordered]@{windows=[ordered]@{expectedSkippedTests=@(
        'source.Tests.ps1::UnitT10_skip_1','source.Tests.ps1::UnitT10_skip_2','source.Tests.ps1::UnitT10_skip_3','source.Tests.ps1::UnitT10_skip_4','source.Tests.ps1::UnitT10_skip_5'
    );reason='fixture'}}}
    Set-WindowsCoreTestText (Join-Path $Root 'docs/standards/core-test-skip-inventory.json') (($skips | ConvertTo-Json -Depth 8) + "`n")
    $weights = [ordered]@{schemaVersion=1;partitionCount=8;weights=[ordered]@{'source.Tests.ps1'=5}}
    Set-WindowsCoreTestText (Join-Path $Root 'tests/windows-core-shard-weights.json') (($weights | ConvertTo-Json -Depth 5) + "`n")
    Set-WindowsCoreTestText (Join-Path $Root 'README.md') "fixture`n"
    Invoke-WindowsCoreTestGit $Root @('add','-A') | Out-Null
    Invoke-WindowsCoreTestGit $Root @('commit','-m','baseline') | Out-Null
    return $Root
}

function New-WindowsCoreTestMerge {
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][scriptblock] $Change)
    Invoke-WindowsCoreTestGit $Root @('checkout','-b','topic') | Out-Null
    & $Change $Root
    & git -C $Root diff --cached --quiet
    $cachedStatus = $LASTEXITCODE
    if ($cachedStatus -eq 0) { Invoke-WindowsCoreTestGit $Root @('add','-A') | Out-Null }
    elseif ($cachedStatus -ne 1) { throw "git cached-diff probe failed with exit code $cachedStatus." }
    Invoke-WindowsCoreTestGit $Root @('commit','-m','topic') | Out-Null
    $head = Invoke-WindowsCoreTestGit $Root @('rev-parse','HEAD')
    Invoke-WindowsCoreTestGit $Root @('checkout','main') | Out-Null
    Invoke-WindowsCoreTestGit $Root @('merge','--no-ff','topic','-m','merge') | Out-Null
    return $head
}

function Get-WindowsCoreTestPlan {
    param([Parameter(Mandatory = $true)][string] $Root,[Parameter(Mandatory = $true)][string] $Head)
    return Get-WindowsCorePlan -Root $Root -Event pull_request -ExpectedPullRequestHead $Head -ShardWeightsPath (Join-Path $Root 'tests/windows-core-shard-weights.json')
}

function New-WindowsCoreAggregateArtifacts {
    param(
        [Parameter(Mandatory = $true)] $PlanResult,
        [Parameter(Mandatory = $true)][string] $Root,
        [ValidateRange(1, 2147483647)][int] $SummaryRunAttempt = 1
    )
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Set-WindowsCoreTestText (Join-Path $Root 'plan.json') ($PlanResult.CanonicalJson + "`n")
    Set-WindowsCoreTestText (Join-Path $Root 'plan.sha256') ($PlanResult.PlanSha256 + "`n")
    foreach ($shard in $PlanResult.Plan.shards) {
        $skippedCount = @($shard.expectedSkippedTests).Count
        $totalCount = [Math]::Max(1, $skippedCount + 1)
        $summary = [ordered]@{
            schemaVersion=2;type='standard-pester-execution-summary';executed=$true;status='completed'
            runId=[string]$PlanResult.Plan.runId;runAttempt=$SummaryRunAttempt
            testFiles=@($shard.files | ForEach-Object { "C:/fixture/tests/$_" })
            skippedTests=@($shard.expectedSkippedTests)
            counts=[ordered]@{TotalCount=$totalCount;PassedCount=($totalCount-$skippedCount);FailedCount=0;SkippedCount=$skippedCount;PendingCount=0;InconclusiveCount=0}
        }
        Set-WindowsCoreTestText (Join-Path $Root "windows-core-shard-$($shard.id)-summary.json") (($summary | ConvertTo-Json -Depth 8) + "`n")
    }
}

Describe 'Windows Core planner and aggregate' {
    # Scenario: A PR changes only an unreferenced Markdown plan under docs.
    # Purpose: Keep the strict docs path to the two invariant contract tests.
    It 'InterT10_selects_the_two_fixed_tests_for_an_unreferenced_docs_change' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'docs-only')
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/plans/x.md') "plan`n" }
        $plan = Get-WindowsCoreTestPlan $root $head
        $plan.Plan.mode | Should Be 'docs'
        ($plan.Plan.selectedTestFiles -join '|') | Should Be 'ai-instructions-contract.Tests.ps1|licensing-scope.Tests.ps1'
    }

    # Scenario: README.md is changed and an ordinary test names that file.
    # Purpose: Include conservative content references while preserving docs mode.
    It 'InterT20_selects_non_authority_tests_that_reference_README' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'readme')
        Set-WindowsCoreTestText (Join-Path $root 'tests/readme-reference.Tests.ps1') "# README.md`nDescribe 'reference' { It 'UnitT10_reference' {} }`n"
        Invoke-WindowsCoreTestGit $root @('add','-A') | Out-Null
        Invoke-WindowsCoreTestGit $root @('commit','-m','reference') | Out-Null
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'README.md') "changed`n" }
        $plan = Get-WindowsCoreTestPlan $root $head
        $plan.Plan.mode | Should Be 'docs'
        $plan.Plan.selectedTestFiles | Should Contain 'readme-reference.Tests.ps1'
    }

    # Scenario: A PR changes a path outside the exact docs allowlist.
    # Purpose: Fail closed for every production, policy, example, data, and case-variant path family.
    It 'InterT30_upgrades_non_documentation_paths_to_full_<Path>' -TestCases @(
        @{Path='scripts/x.ps1'},@{Path='tests/x.txt'},@{Path='instructions/x.md'},@{Path='catalog/x.md'},
        @{Path='.github/workflows/x.yml'},@{Path='docs/standards/x.md'},@{Path='docs/examples/x.md'},@{Path='AGENTS.md'},
        @{Path='licensing-scope.json'},@{Path='delivery/x.md'},@{Path='docs/x.txt'},@{Path='Docs/x.md'},@{Path='README.MD'}
    ) {
        param($Path)
        $safe = $Path.Replace('/','-').Replace('.','-')
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive $safe)
        $head = New-WindowsCoreTestMerge $root {
            param($r)
            if ($Path -cin @('Docs/x.md','README.MD')) {
                $blobSource = Join-Path $r '.case-variant-blob'
                Set-WindowsCoreTestText $blobSource "changed`n"
                $blob = Invoke-WindowsCoreTestGit $r @('hash-object','-w','--','.case-variant-blob')
                if ($blob -notmatch '^[0-9a-f]{40}$') { throw "Fixture blob hash is invalid: '$blob'." }
                Remove-Item -LiteralPath $blobSource
                if ($Path -ceq 'README.MD') {
                    Invoke-WindowsCoreTestGit $r @('update-index','--force-remove','README.md') | Out-Null
                    Remove-Item -LiteralPath (Join-Path $r 'README.md') -Force
                }
                Invoke-WindowsCoreTestGit $r @('update-index','--add','--cacheinfo',"100644,$blob,$Path") | Out-Null
            } else {
                Set-WindowsCoreTestText (Join-Path $r $Path) "changed`n"
            }
        }
        (Get-WindowsCoreTestPlan $root $head).Plan.mode | Should Be 'full'
    }

    # Scenario: A Markdown path has executable, symlink, or type-change Git metadata.
    # Purpose: Permit docs mode only for regular 100644 blobs even when the path text is allowed.
    It 'InterT35_upgrades_non_regular_document_modes_to_full_<Variant>' -TestCases @(
        @{Variant='executable'},@{Variant='symlink'},@{Variant='type-change'}
    ) {
        param($Variant)
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive "mode-$Variant")
        if ($Variant -ceq 'type-change') {
            Set-WindowsCoreTestText (Join-Path $root 'docs/type.md') "regular`n"
            Invoke-WindowsCoreTestGit $root @('add','-A') | Out-Null
            Invoke-WindowsCoreTestGit $root @('commit','-m','regular-doc') | Out-Null
        }
        $head = New-WindowsCoreTestMerge $root {
            param($r)
            $relative = if ($Variant -ceq 'type-change') { 'docs/type.md' } else { "docs/$Variant.md" }
            Set-WindowsCoreTestText (Join-Path $r $relative) "target`n"
            Invoke-WindowsCoreTestGit $r @('add','--',$relative) | Out-Null
            if ($Variant -ceq 'executable') {
                Invoke-WindowsCoreTestGit $r @('update-index','--chmod=+x','--',$relative) | Out-Null
            } else {
                $blob = Invoke-WindowsCoreTestGit $r @('hash-object','-w','--',$relative)
                if ($blob -notmatch '^[0-9a-f]{40}$') { throw "Fixture blob hash is invalid: '$blob'." }
                Invoke-WindowsCoreTestGit $r @('update-index','--cacheinfo',"120000,$blob,$relative") | Out-Null
            }
        }
        (Get-WindowsCoreTestPlan $root $head).Plan.mode | Should Be 'full'
    }

    # Scenario: A docs change is mixed with executable source.
    # Purpose: Prevent documentation from masking a full validation trigger.
    It 'InterT40_upgrades_mixed_docs_and_source_changes_to_full' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'mixed')
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "doc`n"; Set-WindowsCoreTestText (Join-Path $r 'scripts/x.ps1') "source`n" }
        (Get-WindowsCoreTestPlan $root $head).Plan.mode | Should Be 'full'
    }

    # Scenario: A tracked source file references a changed or deleted document.
    # Purpose: Escalate documentation that can affect source behavior even when the doc path itself is allowed.
    It 'InterT50_upgrades_referenced_docs_to_full_<Delete>' -TestCases @(@{Delete=$false},@{Delete=$true}) {
        param($Delete)
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive "reference-$Delete")
        Set-WindowsCoreTestText (Join-Path $root 'docs/x.md') "old`n"
        Set-WindowsCoreTestText (Join-Path $root 'scripts/ref.ps1') "docs/x.md`n"
        Invoke-WindowsCoreTestGit $root @('add','-A') | Out-Null; Invoke-WindowsCoreTestGit $root @('commit','-m','reference') | Out-Null
        $head = New-WindowsCoreTestMerge $root { param($r) if ($Delete) { Remove-Item -LiteralPath (Join-Path $r 'docs/x.md') } else { Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "new`n" } }
        (Get-WindowsCoreTestPlan $root $head).Plan.mode | Should Be 'full'
    }

    # Scenario: A tracked source uses both slash styles in one reference to a changed document.
    # Purpose: Prevent mixed separators from bypassing conservative referrer discovery.
    It 'InterT52_upgrades_mixed_separator_document_references_to_full' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'mixed-separator-reference')
        Set-WindowsCoreTestText (Join-Path $root 'scripts/ref.ps1') "docs\plans/x.md`n"
        Invoke-WindowsCoreTestGit $root @('add','-A') | Out-Null
        Invoke-WindowsCoreTestGit $root @('commit','-m','mixed-reference') | Out-Null
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/plans/x.md') "changed`n" }
        $plan = Get-WindowsCoreTestPlan $root $head
        $plan.Plan.mode | Should Be 'full'
        ($plan.Plan.reasons -join "`n") | Should Match 'scripts/ref\.ps1'
    }

    # Scenario: A non-tests-directory source happens to end in .Tests.ps1 and references changed documentation.
    # Purpose: Exclude only files actually discovered by the tests/ Pester traversal.
    It 'InterT54_scans_test_suffix_sources_outside_the_tests_directory' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'runtime-tests-suffix')
        Set-WindowsCoreTestText (Join-Path $root 'scripts/runtime.Tests.ps1') "docs/x.md`n"
        Invoke-WindowsCoreTestGit $root @('add','-A') | Out-Null
        Invoke-WindowsCoreTestGit $root @('commit','-m','runtime-reference') | Out-Null
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "changed`n" }
        $plan = Get-WindowsCoreTestPlan $root $head
        $plan.Plan.mode | Should Be 'full'
        ($plan.Plan.reasons -join "`n") | Should Match 'scripts/runtime\.Tests\.ps1'
    }

    # Scenario: A tracked referrer disappears from the checkout before classification can inspect it.
    # Purpose: Fail closed instead of silently skipping unreadable or unverifiable tracked sources.
    It 'InterT56_fails_closed_when_a_tracked_referrer_cannot_be_read' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'missing-referrer')
        Set-WindowsCoreTestText (Join-Path $root 'scripts/ref.ps1') "docs/x.md`n"
        Invoke-WindowsCoreTestGit $root @('add','-A') | Out-Null
        Invoke-WindowsCoreTestGit $root @('commit','-m','tracked-referrer') | Out-Null
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "changed`n" }
        Remove-Item -LiteralPath (Join-Path $root 'scripts/ref.ps1') -Force
        $plan = Get-WindowsCoreTestPlan $root $head
        $plan.Plan.mode | Should Be 'full'
        ($plan.Plan.reasons -join "`n") | Should Match 'could not be inspected as a regular file'
    }

    # Scenario: A merge commit contains a quoted or newline-bearing Git path that Windows cannot materialize safely.
    # Purpose: Drive adversarial path bytes through full diff parsing and planner classification via Git plumbing.
    It 'InterT60_fails_closed_for_plumbed_adversarial_merge_path_<Variant>' -TestCases @(
        @{Variant='dotdot';Leaf='..'},@{Variant='quote';Leaf='"x.md'},@{Variant='newline';Leaf="x`n.md"}
    ) {
        param($Variant,$Leaf)
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive "plumbing-$Variant")
        $head = New-WindowsCoreTestUnsafePathMerge -Root $root -DocsLeaf $Leaf
        $plan = Get-WindowsCoreTestPlan $root $head
        $plan.Plan.mode | Should Be 'full'
        ($plan.Plan.reasons -join "`n") | Should Match 'unsafe changed path'
    }

    # Scenario: A repository-relative path reaches the standalone safety predicate.
    # Purpose: Retain traversal, backslash, and case-variant defense where Git itself refuses to construct the tree path.
    It 'UnitT62_rejects_unsafe_or_case_variant_document_paths_<Path>' -TestCases @(
        @{Path='../x.md'},@{Path='docs/../x.md'},@{Path='docs/"x.md'},@{Path="docs/x`n.md"},@{Path='docs\x.md'},@{Path='README.MD'}
    ) {
        param($Path)
        ((Test-WindowsCoreUnsafeChangedPath $Path) -or -not (Test-WindowsCoreDocumentationPath $Path)) | Should Be $true
    }

    # Scenario: A non-PR event has no merge metadata.
    # Purpose: Make push and workflow_dispatch unconditionally select the complete suite.
    It 'UnitT70_uses_full_mode_for_non_pull_request_events' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'push')
        $plan = Get-WindowsCorePlan -Root $root -Event push -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json')
        $plan.Plan.mode | Should Be 'full'
    }

    # Scenario: A push selects the complete fixture inventory and all five reviewed Windows skips are reported.
    # Purpose: Exercise the successful full-mode aggregate rather than validating only the docs fast path.
    It 'InterT75_accepts_a_complete_full_push_with_the_five_reviewed_skips' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'push-aggregate')
        $plan = Get-WindowsCorePlan -Root $root -Event push -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json')
        $plan.Plan.expectedSkippedTests.Count | Should Be 5
        $artifacts = Join-Path $TestDrive 'push-aggregate-artifacts'
        New-WindowsCoreAggregateArtifacts $plan $artifacts
        $result = Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event push -PlanSha256 $plan.PlanSha256 -PlanMode full -PlanJobResult success -AuthorityJobResult success -PesterJobResult success -FixturesJobResult success
        $result.status | Should Be 'passed'
        $result.skippedTestCount | Should Be 5
    }

    # Scenario: PR metadata does not bind to an exact two-parent merge checkout.
    # Purpose: Fail closed before trusting the PR diff.
    It 'InterT80_rejects_non_merge_or_wrong_head_PR_checkouts_<Variant>' -TestCases @(@{Variant='non-merge'},@{Variant='wrong-head'}) {
        param($Variant)
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive $Variant)
        if ($Variant -ceq 'non-merge') {
            { Get-WindowsCoreTestPlan $root ('0' * 40) } | Should Throw
        } else {
            $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "x`n" }
            { Get-WindowsCoreTestPlan $root ('0' * 40) } | Should Throw
        }
    }

    # Scenario: LPT receives more than eight weighted and unweighted test files plus a skip binding.
    # Purpose: Lock the exact deterministic placement, including the load change caused by default weight one.
    It 'UnitT90_partitions_more_than_eight_tests_with_exact_LPT_placement' {
        $weights = Join-Path $TestDrive 'weights.json'
        Set-WindowsCoreTestText $weights '{"schemaVersion":1,"partitionCount":8,"weights":{"a.Tests.ps1":9,"b.Tests.ps1":8,"c.Tests.ps1":7,"d.Tests.ps1":6,"e.Tests.ps1":5,"f.Tests.ps1":4,"g.Tests.ps1":3,"h.Tests.ps1":2}}'
        $files = @('a.Tests.ps1','b.Tests.ps1','c.Tests.ps1','d.Tests.ps1','e.Tests.ps1','f.Tests.ps1','g.Tests.ps1','h.Tests.ps1','i.Tests.ps1','j.Tests.ps1')
        $skips = @('c.Tests.ps1::UnitT10_skip')
        $first = @(New-WindowsCoreShards -SelectedTestFiles $files -ExpectedSkippedTests $skips -ConfigurationPath $weights)
        $second = @(New-WindowsCoreShards -SelectedTestFiles $files -ExpectedSkippedTests $skips -ConfigurationPath $weights)
        (ConvertTo-Json $first -Depth 6 -Compress) | Should Be (ConvertTo-Json $second -Depth 6 -Compress)
        (@($first | ForEach-Object { "$($_.id):$($_.files -join ',')" }) -join '|') | Should Be '01:a.Tests.ps1|02:b.Tests.ps1|03:c.Tests.ps1|04:d.Tests.ps1|05:e.Tests.ps1|06:f.Tests.ps1|07:g.Tests.ps1,j.Tests.ps1|08:h.Tests.ps1,i.Tests.ps1'
        (@($first.files) | Sort-Object) -join '|' | Should Be (($files | Sort-Object) -join '|')
        @($first.files | Group-Object | Where-Object Count -ne 1).Count | Should Be 0
        (@($first | Where-Object id -ceq '03').expectedSkippedTests -join '|') | Should Be 'c.Tests.ps1::UnitT10_skip'
    }

    # Scenario: All upstream jobs and downloaded receipts agree with an independently recalculated docs plan.
    # Purpose: Allow the required Windows Core context to pass only after complete receipt verification.
    It 'InterT100_accepts_a_complete_consistent_aggregate' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'aggregate-ok')
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "x`n" }
        $plan = Get-WindowsCoreTestPlan $root $head
        $artifacts = Join-Path $TestDrive 'artifacts-ok'; New-WindowsCoreAggregateArtifacts $plan $artifacts
        $result = Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event pull_request -ExpectedPullRequestHead $head -PlanSha256 $plan.PlanSha256 -PlanMode docs -PlanJobResult success -AuthorityJobResult success -PesterJobResult success -FixturesJobResult skipped
        $result.status | Should Be 'passed'
    }

    # Scenario: Successful plan and shard artifacts were produced in attempt 1, then only the failed aggregate is rerun in attempt 2.
    # Purpose: Preserve fail-closed run identity while allowing receipts from an earlier attempt of the same workflow run.
    It 'InterT105_accepts_attempt_one_receipts_during_attempt_two_aggregate' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'aggregate-rerun')
        $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "x`n" }
        $plan = Get-WindowsCorePlan -Root $root -Event pull_request -ExpectedPullRequestHead $head -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -WorkflowRunId 'run-42' -WorkflowRunAttempt 1
        $artifacts = Join-Path $TestDrive 'artifacts-rerun'
        New-WindowsCoreAggregateArtifacts $plan $artifacts -SummaryRunAttempt 1
        $result = Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event pull_request -ExpectedPullRequestHead $head -PlanSha256 $plan.PlanSha256 -PlanMode docs -PlanJobResult success -AuthorityJobResult success -PesterJobResult success -FixturesJobResult skipped -CurrentRunId 'run-42' -CurrentRunAttempt 2
        $result.status | Should Be 'passed'
        $result.runAttempt | Should Be 2
    }

    # Scenario: An upstream job result is skipped, cancelled, or failed.
    # Purpose: Ensure the always-running aggregate cannot turn an incomplete lane into a passing required check.
    It 'InterT110_rejects_non_success_upstream_results_<Job>_<Result>' -TestCases @(
        @{Job='plan';Result='skipped'},@{Job='plan';Result='cancelled'},@{Job='plan';Result='failure'},
        @{Job='authority';Result='skipped'},@{Job='authority';Result='cancelled'},@{Job='authority';Result='failure'},
        @{Job='pester';Result='skipped'},@{Job='pester';Result='cancelled'},@{Job='pester';Result='failure'},
        @{Job='fixtures';Result='skipped'},@{Job='fixtures';Result='cancelled'},@{Job='fixtures';Result='failure'}
    ) {
        param($Job,$Result)
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive "upstream-$Job-$Result")
        $plan = Get-WindowsCorePlan -Root $root -Event push -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json')
        $artifacts = Join-Path $TestDrive "artifacts-$Job-$Result"; New-WindowsCoreAggregateArtifacts $plan $artifacts
        $values = @{plan='success';authority='success';pester='success';fixtures='success'}; $values[$Job]=$Result
        { Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event push -PlanSha256 $plan.PlanSha256 -PlanMode full -PlanJobResult $values.plan -AuthorityJobResult $values.authority -PesterJobResult $values.pester -FixturesJobResult $values.fixtures } | Should Throw
    }

    # Scenario: The fixtures result contradicts the independently recalculated plan mode.
    # Purpose: Accept skipped fixtures only for docs mode and require success for full mode.
    It 'InterT120_rejects_a_fixture_result_that_contradicts_mode_<Event>_<Result>' -TestCases @(
        @{Event='pull_request';Result='success'},@{Event='push';Result='skipped'}
    ) {
        param($Event,$Result)
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive "fixture-$Event-$Result")
        if ($Event -ceq 'pull_request') { $head = New-WindowsCoreTestMerge $root { param($r) Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "x`n" }; $plan=Get-WindowsCoreTestPlan $root $head }
        else { $head=''; $plan=Get-WindowsCorePlan -Root $root -Event push -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') }
        $artifacts=Join-Path $TestDrive "artifacts-fixture-$Event";New-WindowsCoreAggregateArtifacts $plan $artifacts
        { Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event $Event -ExpectedPullRequestHead $head -PlanSha256 $plan.PlanSha256 -PlanMode $plan.Plan.mode -PlanJobResult success -AuthorityJobResult success -PesterJobResult success -FixturesJobResult $Result } | Should Throw
    }

    # Scenario: The plan job claims docs mode while the aggregate independently derives full mode.
    # Purpose: Prevent a forged output from skipping fixtures or the complete Pester inventory.
    It 'InterT125_rejects_a_docs_output_when_independent_recalculation_is_full' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'mode-forgery')
        $plan = Get-WindowsCorePlan -Root $root -Event push -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json')
        $artifacts = Join-Path $TestDrive 'artifacts-mode-forgery'; New-WindowsCoreAggregateArtifacts $plan $artifacts
        { Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event push -PlanSha256 $plan.PlanSha256 -PlanMode docs -PlanJobResult success -AuthorityJobResult success -PesterJobResult success -FixturesJobResult success } | Should Throw
    }

    # Scenario: Downloaded plan or shard evidence is missing, duplicated, failing, or tampered.
    # Purpose: Fail closed on every receipt-integrity boundary owned by the aggregate.
    It 'InterT130_rejects_invalid_aggregate_evidence_<Variant>' -TestCases @(
        @{Variant='missing-summary'},@{Variant='duplicate-file'},@{Variant='extra-file'},@{Variant='failed-count'},@{Variant='skip-mismatch'},@{Variant='plan-hash'}
    ) {
        param($Variant)
        $root=New-WindowsCoreTestRepository (Join-Path $TestDrive "evidence-$Variant")
        $head=New-WindowsCoreTestMerge $root {param($r)Set-WindowsCoreTestText (Join-Path $r 'docs/x.md') "x`n"}
        $plan=Get-WindowsCoreTestPlan $root $head;$artifacts=Join-Path $TestDrive "artifacts-$Variant";New-WindowsCoreAggregateArtifacts $plan $artifacts
        $summary=@(Get-ChildItem -LiteralPath $artifacts -Filter 'windows-core-shard-*-summary.json'|Sort-Object Name)[0]
        if($Variant-ceq'missing-summary'){Remove-Item -LiteralPath $summary.FullName}
        elseif($Variant-ceq'plan-hash'){Set-WindowsCoreTestText (Join-Path $artifacts 'plan.sha256') (('0'*64)+"`n")}
        else{$json=Get-Content -Raw -Encoding UTF8 $summary.FullName|ConvertFrom-Json;if($Variant-ceq'duplicate-file'){$json.testFiles=@($json.testFiles)+@($json.testFiles[0])}elseif($Variant-ceq'extra-file'){$json.testFiles=@($json.testFiles)+@('C:/fixture/tests/extra.Tests.ps1')}elseif($Variant-ceq'failed-count'){$json.counts.FailedCount=1}elseif($Variant-ceq'skip-mismatch'){$json.skippedTests=@('x.Tests.ps1::UnitT10_x')}Set-WindowsCoreTestText $summary.FullName (($json|ConvertTo-Json -Depth 8)+"`n")}
        {Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event pull_request -ExpectedPullRequestHead $head -PlanSha256 $plan.PlanSha256 -PlanMode docs -PlanJobResult success -AuthorityJobResult success -PesterJobResult success -FixturesJobResult skipped}|Should Throw
    }

    # Scenario: A full-mode summary reports five skips, but one reviewed identifier is replaced by another string.
    # Purpose: Prove aggregate validation compares the exact identifier set instead of only the count.
    It 'InterT135_rejects_a_same_count_replacement_in_the_skip_identifier_set' {
        $root = New-WindowsCoreTestRepository (Join-Path $TestDrive 'skip-set-replacement')
        $plan = Get-WindowsCorePlan -Root $root -Event push -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json')
        $artifacts = Join-Path $TestDrive 'artifacts-skip-set-replacement'
        New-WindowsCoreAggregateArtifacts $plan $artifacts
        $summary = @(Get-ChildItem -LiteralPath $artifacts -Filter 'windows-core-shard-*-summary.json' | ForEach-Object {
            $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $_.FullName | ConvertFrom-Json
            if (@($document.skippedTests).Count -gt 0) { [pscustomobject]@{ File=$_; Document=$document } }
        })[0]
        $summary.Document.skippedTests[0] = 'source.Tests.ps1::UnitT10_replaced'
        Set-WindowsCoreTestText $summary.File.FullName (($summary.Document | ConvertTo-Json -Depth 8) + "`n")
        { Assert-WindowsCoreAggregate -Root $root -Artifacts $artifacts -ShardWeightsPath (Join-Path $root 'tests/windows-core-shard-weights.json') -Event push -PlanSha256 $plan.PlanSha256 -PlanMode full -PlanJobResult success -AuthorityJobResult success -PesterJobResult success -FixturesJobResult success } | Should Throw
    }
}
