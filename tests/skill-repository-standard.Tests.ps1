Describe 'SYP280 runner inventory performance and compatibility' -Tag 'SYP280' {
    BeforeAll {
        $script:Syp280Runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-StandardValidation.ps1'
        . $script:Syp280Runner -CandidateRoot $TestDrive -AdapterPath (Join-Path $TestDrive 'unused.json') -ArtifactsRoot (Join-Path $TestDrive 'results') -SourceRepository 'https://example.test/source.git' -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly
        function New-Syp280BoundaryFixture {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $paths = @{}
            foreach ($name in @('tool','candidate','snapshot','authority')) {
                $paths[$name] = Join-Path $root $name
                [void][IO.Directory]::CreateDirectory($paths[$name])
            }
            foreach ($binding in @(@{name='command';relative='tool/command.bin'},@{name='dependency';relative='tool/dependency.bin'},@{name='candidateFile';relative='candidate/SKILL.md'},@{name='snapshotFile';relative='snapshot/SKILL.md'},@{name='receipt';relative='receipt.json'},@{name='adapter';relative='adapter.json'},@{name='archive';relative='archive.zip'},@{name='acquisition';relative='acquisition.json'},@{name='launch';relative='launch.json'},@{name='evidence';relative='evidence.json'})) {
                $paths[$binding.name] = Join-Path $root $binding.relative
                [IO.File]::WriteAllText($paths[$binding.name],'0000',[Text.UTF8Encoding]::new($false))
            }
            $authority = [ordered]@{}
            foreach ($field in @('runner','contract','policy','authorityGate','resolver','semanticBridgeModule','semanticBridgeSchema')) {
                $relative = $field + '.bin'
                [IO.File]::WriteAllText((Join-Path $paths.authority $relative),'0000',[Text.UTF8Encoding]::new($false))
                $authority[$field+'Path'] = $relative
                $authority[$field+'Sha256'] = Get-StandardValidationFileSha256 -Path (Join-Path $paths.authority $relative) -Context 'fixture'
            }
            $launcher = [pscustomobject]@{kind='direct-executable';shimPath=$null;shimSha256=$null;payloadPath=$null;payloadSha256=$null;runtimePath=$null;runtimeSha256=$null}
            $receipt = [pscustomobject]@{path=$paths.receipt;sha256=(Get-StandardValidationFileSha256 $paths.receipt 'fixture');installRoot=$paths.tool;executableSha256=(Get-StandardValidationFileSha256 $paths.command 'fixture');installedClosureSha256=(Get-StandardValidationDirectoryClosureSha256 $paths.tool 'fixture');launcher=$launcher}
            $arguments = @{
                CommandSpec=[pscustomobject]@{command=$paths.command;arguments=@('fixture');commandSha256=$receipt.executableSha256;toolReceipt=$receipt}
                RunRoot=(Join-Path $root 'run');ChildWorkingRoot=(Join-Path $root 'children');StageId='fixture';ToolId='fixture';CandidateId='fixture-candidate'
                SnapshotRoot=$paths.snapshot;ExpectedSnapshotContentSha256=(Get-StandardValidationInventorySha256 (Get-StandardValidationInventory $paths.snapshot 'fixture'))
                SkillsRoot=$paths.snapshot;ActiveSkillsText='fixture';OriginalCandidateRoot=$paths.candidate
                ExpectedCandidateContentSha256=(Get-StandardValidationInventorySha256 (Get-StandardValidationInventory $paths.candidate 'fixture'))
                CandidateArchivePath=$paths.archive;ExpectedCandidateArchiveSha256=(Get-StandardValidationFileSha256 $paths.archive 'fixture')
                CandidateAcquisitionEvidencePath=$paths.acquisition;ExpectedCandidateAcquisitionEvidenceSha256=(Get-StandardValidationFileSha256 $paths.acquisition 'fixture')
                AdapterPath=$paths.adapter;ExpectedAdapterSha256=(Get-StandardValidationFileSha256 $paths.adapter 'fixture');TimeoutSeconds=10
            }
            [pscustomobject]@{paths=$paths;authority=[pscustomobject]$authority;arguments=$arguments;launch=[pscustomobject]@{verified=$true;path=$paths.launch;sha256=(Get-StandardValidationFileSha256 $paths.launch 'fixture')};evidence=[pscustomobject]@{path=$paths.evidence;context='fixture';sha256=(Get-StandardValidationFileSha256 $paths.evidence 'fixture')}}
        }
        function Invoke-Syp280Mutation {
            param($Fixture,[string]$Mutation)
            $paths=$Fixture.paths
            switch ($Mutation) {
                'add' { [IO.File]::WriteAllText((Join-Path $paths.tool 'added.bin'),'0000') }
                'delete' { Remove-Item -LiteralPath $paths.dependency }
                'rename' { Move-Item -LiteralPath $paths.dependency -Destination (Join-Path $paths.tool 'renamed.bin') }
                default {
                    $path=switch($Mutation){'same-size-mtime'{$paths.dependency};'receipt'{$paths.receipt};'authority'{Join-Path $paths.authority 'runner.bin'};'candidate'{$paths.candidateFile};'snapshot'{$paths.snapshotFile};'archive'{$paths.archive};'acquisition'{$paths.acquisition};'launch'{$paths.launch};'evidence'{$paths.evidence};'adapter'{$paths.adapter}}
                    $stamp=[IO.File]::GetLastWriteTimeUtc($path)
                    [IO.File]::WriteAllText($path,'1111',[Text.UTF8Encoding]::new($false))
                    [IO.File]::SetLastWriteTimeUtc($path,$stamp)
                    if ((Get-Item -LiteralPath $path).Length -ne 4 -or [IO.File]::GetLastWriteTimeUtc($path) -ne $stamp) { throw 'Mutation must preserve size and mtime.' }
                }
            }
        }
    }

    # Scenario: The measured installed inventory contains thousands of entries, mostly already ordered.
    # Purpose: Prevent a quadratic growing-list scan without relying on a fragile stopwatch threshold.
    It 'UnitT10_bounds_inventory_sort_complexity' {
        $definition = (Get-Command Sort-StandardValidationInventory).Definition
        if ($definition -match '\.Insert\s*\(' -or $definition -match 'while\s*\([^)]*\$ordered\.Count') {
            throw 'Inventory sorting must eliminate the measured quadratic insertion scan.'
        }
        if ($definition -notmatch 'SortedDictionary\[string,object\]' -or $definition -notmatch '\[StringComparer\]::Ordinal') {
            throw 'The runner inventory must use logarithmic insertion with an explicit ordinal comparer.'
        }
    }

    # Scenario: A timed diagnostic action succeeds, throws, or reports cancellation.
    # Purpose: Preserve start/terminal diagnostics and the original failure while excluding host paths from log labels.
    It 'UnitT15_reports_success_failure_and_cancellation_without_changing_results' {
        $previousError = [Console]::Error
        $capture = New-Object IO.StringWriter
        try {
            [Console]::SetError($capture)
            $value = Invoke-StandardValidationTimedPhase -Stage 'fixture' -Phase 'success' -Action { 42 }
            if ($value -ne 42) { throw 'Timing must preserve the action result.' }
            foreach ($state in @('FAILED','CANCELLED')) {
                $failure = $null
                try { Invoke-StandardValidationTimedPhase -Stage 'fixture' -Phase $state.ToLowerInvariant() -Action { throw "$state|original fixture" } }
                catch { $failure = $_.Exception.Message }
                if ($failure -cne "$state|original fixture") { throw 'Timing must retain the original exception.' }
            }
            $records = @($capture.ToString().Trim().Split([char]10) | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            if ($records.Count -ne 6) { throw 'Each action needs exactly one start and one terminal diagnostic.' }
            if (($records.state -join ',') -cne 'started,completed,started,failed,started,cancelled') { throw 'Diagnostic terminal states differ.' }
            foreach ($record in $records) {
                if ($record.stage -cne 'fixture' -or $record.elapsedSeconds -lt 0) { throw 'Diagnostic stage/timing is invalid.' }
            }
        }
        finally { [Console]::SetError($previousError); $capture.Dispose() }
    }

    # Scenario: Entries arrive out of order with mixed case, Unicode, identical paths, and distinct hashes.
    # Purpose: Preserve the old exact ordinal bytes and reverse arrival order for equal-path entries across cultures.
    It 'UnitT20_preserves_ordinal_canonical_bytes_and_equal_path_order' {
        $entries = @('z','A','a',"$([char]0xE9)","e$([char]0x301)",'A',"$([char]0x4E2D)",'z') | ForEach-Object -Begin { $index=0 } -Process {
            [pscustomobject]@{path=$_;sha256=('{0:x64}' -f $index)}; $index++
        }
        $old = New-Object 'Collections.Generic.List[object]'
        foreach ($entry in $entries) {
            $at=0
            while ($at -lt $old.Count -and [string]::Compare([string]$old[$at].path,[string]$entry.path,[StringComparison]::Ordinal) -lt 0) { $at++ }
            $old.Insert($at,$entry)
        }
        $expected = ($old | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
        $previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach ($culture in @('en-US','tr-TR','zh-TW')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
                $actual = Sort-StandardValidationInventory -Inventory $entries
                $canonical = ($actual | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
                if (-not [string]::Equals($canonical,$expected,[StringComparison]::Ordinal)) { throw "Ordinal canonical bytes differ in $culture." }
                if ((Get-StandardValidationInventorySha256 -Inventory $entries) -cne (Get-StandardValidationTextSha256 -Value $expected)) { throw 'Canonical inventory SHA-256 changed.' }
            }
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture }
    }

    # Scenario: A 16k+ inventory arrives in reverse order with mixed case, Unicode, and duplicate paths.
    # Purpose: Compare every canonical byte with an independent ordinal string-sort oracle at representative scale.
    It 'UnitT25_preserves_representative_inventory_bytes' {
        if ((Get-Command Sort-StandardValidationInventory).Definition -match '\.Insert\s*\(') {
            throw 'The large regression requires the measured quadratic insertion scan to be removed first.'
        }
        $entries = New-Object 'Collections.Generic.List[object]'
        $byOracleKey = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        $keys = New-Object 'Collections.Generic.List[string]'
        for ($index = 16559; $index -ge 0; $index--) {
            $prefix = @('A','a',"$([char]0xE9)","e$([char]0x301)","$([char]0x4E2D)")[$index % 5]
            $entry = [pscustomobject]@{path=('{0}/{1:d5}.bin' -f $prefix,[int][Math]::Floor($index / 2));sha256=('{0:x64}' -f $index)}
            # Index descends on arrival. Its fixed-width ascending suffix therefore
            # represents the old reverse-arrival rule when primary paths are equal.
            $key = $entry.path + "`t" + ('{0:d5}' -f $index)
            $entries.Add($entry)
            $keys.Add($key)
            $byOracleKey.Add($key,$entry)
        }
        # Add a true duplicate path with a different digest after the full inventory.
        $duplicate = [pscustomobject]@{path=$entries[0].path;sha256=('f' * 64)}
        $entries.Add($duplicate)
        $duplicateKey = $duplicate.path + "`t-0001"
        $keys.Add($duplicateKey)
        $byOracleKey.Add($duplicateKey,$duplicate)
        [string[]]$oracleKeys = $keys.ToArray()
        [Array]::Sort($oracleKeys,[StringComparer]::Ordinal)
        $expected = ($oracleKeys | ForEach-Object { $entry=$byOracleKey[$_]; "$($entry.path)`t$($entry.sha256)`n" }) -join ''
        $actual = Sort-StandardValidationInventory -Inventory $entries
        $canonical = ($actual | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
        if ($actual.Count -ne 16561 -or -not [string]::Equals($expected,$canonical,[StringComparison]::Ordinal)) {
            throw 'Representative inventory lost entries or changed canonical bytes.'
        }
        if ((Get-StandardValidationInventorySha256 -Inventory $entries) -cne (Get-StandardValidationTextSha256 -Value $expected)) {
            throw 'Representative canonical SHA-256 changed.'
        }
    }

    # Scenario: A long phase receives repeated progress updates beyond the diagnostic quota.
    # Purpose: Keep heartbeat output bounded and free of caller-provided host paths, while retaining its terminal state.
    It 'UnitT27_bounds_phase_heartbeat_and_redacts_unsafe_labels' {
        $previousError = [Console]::Error
        $capture = New-Object IO.StringWriter
        try {
            [Console]::SetError($capture)
            $timing = New-StandardValidationPhase -Stage 'C:/private/fixture' -Phase 'closure'
            for ($index = 1; $index -le 1000; $index++) {
                $timing.watch = [pscustomobject]@{Elapsed=[TimeSpan]::FromSeconds($index * 30)}
                Update-StandardValidationPhase -Timing $timing -Files 1 -Bytes 4
            }
            Complete-StandardValidationPhase -Timing $timing -State 'completed'
            $records = @($capture.ToString().Trim().Split([char]10) | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            if (@($records | Where-Object state -eq 'heartbeat').Count -ne 120 -or $records.Count -ne 122) {
                throw 'Heartbeat must be rate limited and capped at 120 per phase.'
            }
            if ($records[-1].state -cne 'completed' -or $records[-1].files -ne 1000 -or $records[-1].bytes -ne 4000) {
                throw 'The terminal diagnostic must retain all work counts after the heartbeat cap.'
            }
            if ($capture.ToString().Contains('C:/private') -or $records[0].stage -cne 'validation') {
                throw 'Unsafe stage labels must be redacted.'
            }
        }
        finally { [Console]::SetError($previousError); $capture.Dispose() }
    }

    # Scenario: A complete closure succeeds, then an empty closure fails with automatic timing enabled.
    # Purpose: Bind real enumeration/path/hash/sort costs to unchanged closure hashes and preserve failure diagnostics.
    It 'UnitT28_reports_real_closure_phases_without_changing_hash' {
        $fixture=New-Syp280BoundaryFixture
        $empty=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($empty)
        $previousError=[Console]::Error
        $capture=New-Object IO.StringWriter
        $script:StandardValidationTimingEnabled=$true
        try {
            [Console]::SetError($capture)
            $actual=Get-StandardValidationDirectoryClosureSha256 -Root $fixture.paths.tool -Context 'fixture'
            if($actual -cne $fixture.arguments.CommandSpec.toolReceipt.installedClosureSha256){throw 'Timing changed the closure SHA.'}
            if([string]::IsNullOrWhiteSpace($capture.ToString())){throw 'Missing automatic closure phase diagnostics.'}
            $records=@($capture.ToString().Trim().Split([char]10) | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            foreach($phase in @('installed-closure','closure-enumeration','closure-safe-path','closure-path-collision','closure-content-hash','inventory-sort')) {
                $rows=@($records | Where-Object phase -eq $phase)
                if($rows.Count -ne 2 -or $rows[0].state -cne 'started' -or $rows[1].state -cne 'completed'){throw "Missing real phase diagnostics: $phase"}
            }
            $hashPhase=@($records | Where-Object { $_.phase -ceq 'closure-content-hash' -and $_.state -ceq 'completed' })[0]
            if($hashPhase.calls -ne 2 -or $hashPhase.files -ne 2 -or $hashPhase.bytes -ne 8){throw 'Hash phase work counts differ.'}
            if($capture.ToString().Contains($fixture.paths.tool)){throw 'Diagnostics exposed a host path.'}
            $capture.GetStringBuilder().Clear() | Out-Null
            $failure=$null
            try { Get-StandardValidationDirectoryClosureSha256 -Root $empty -Context 'fixture' }
            catch { $failure=$_.Exception.Message }
            if($failure -cne 'INVALID|fixture must contain at least one file or approved Unix symlink.'){throw 'Closure timing changed the failure.'}
            $failedRecords=@($capture.ToString().Trim().Split([char]10) | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            if($failedRecords[-1].phase -cne 'installed-closure' -or $failedRecords[-1].state -cne 'failed'){throw 'Failure needs its terminal diagnostic.'}
        }
        finally { $script:StandardValidationTimingEnabled=$false; [Console]::SetError($previousError); $capture.Dispose() }
    }

    # Scenario: Cancellation is requested before any child process can start.
    # Purpose: Keep the original cancellation result and label its phase terminal correctly.
    It 'UnitT29_retains_pre_start_cancellation_result_and_timing' {
        $cancellation = Join-Path $TestDrive 'syp280-pre-start-cancellation.txt'
        [IO.File]::WriteAllText($cancellation, 'cancel', [Text.UTF8Encoding]::new($false))
        $capture = [IO.StringWriter]::new()
        $previousError = [Console]::Error
        $previousTiming = $script:StandardValidationTimingEnabled
        try {
            [Console]::SetError($capture)
            $script:StandardValidationTimingEnabled = $true
            $result = Invoke-StandardValidationProcess -Command 'fixture-never-launch' -Arguments @('fixture') -WorkingDirectory $TestDrive -Environment @{} -TimeoutSeconds 1 -CancellationPath $cancellation
            if ($result.status -cne 'cancelled' -or $result.exitCode -ne -1 -or $null -ne $result.processId -or -not $result.cleanedUp) {
                throw 'Pre-start cancellation must retain its original result without launching a child.'
            }
            $records = @($capture.ToString().Trim().Split([char]10) | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            if ($records.Count -ne 2 -or $records[0].state -cne 'started' -or $records[-1].phase -cne 'child-process' -or $records[-1].state -cne 'cancelled') {
                throw 'Pre-start cancellation needs a cancelled timing terminal.'
            }
        }
        finally {
            $script:StandardValidationTimingEnabled = $previousTiming
            [Console]::SetError($previousError)
            $capture.Dispose()
        }
    }

    # Scenario: A child changes one protected input, including equal-length bytes with the original mtime.
    # Purpose: Exercise the actual command wrapper's next integrity boundary; a malformed envelope cannot produce a false-positive rejection.
    It 'InterT30_rejects_child_mutation_of_<Mutation>' -TestCases @(
        @{Mutation='none';Pattern=''},@{Mutation='add';Pattern='dependency closure changed'},@{Mutation='delete';Pattern='dependency closure changed'},@{Mutation='rename';Pattern='dependency closure changed'},@{Mutation='same-size-mtime';Pattern='dependency closure changed'},@{Mutation='receipt';Pattern='resolver receipt changed'},@{Mutation='authority';Pattern='central runner changed'},@{Mutation='candidate';Pattern='Candidate content changed'},@{Mutation='snapshot';Pattern='Candidate snapshot changed'},@{Mutation='archive';Pattern='archive changed'},@{Mutation='acquisition';Pattern='candidate acquisition receipt changed'},@{Mutation='launch';Pattern='launch binding changed'},@{Mutation='evidence';Pattern='evidence artifact.*changed'},@{Mutation='adapter';Pattern='Adapter configuration changed'}
    ) {
        param($Mutation,$Pattern)
        $fixture=New-Syp280BoundaryFixture
        $previousRoot=$script:StandardValidationRepositoryRoot
        $script:StandardValidationRepositoryRoot=$fixture.paths.authority
        $script:StandardValidationAuthorityEvidence=$fixture.authority
        $script:StandardValidationLaunchBinding=$fixture.launch
        $script:StandardValidationEvidenceArtifactLedger=New-Object 'Collections.Generic.List[object]'
        $script:StandardValidationEvidenceArtifactLedger.Add($fixture.evidence)
        $script:Syp280Fixture=$fixture
        $script:Syp280Mutation=$Mutation
        Mock Invoke-StandardValidationProcess {
            if($script:Syp280Mutation -cne 'none'){Invoke-Syp280Mutation -Fixture $script:Syp280Fixture -Mutation $script:Syp280Mutation}
            [pscustomobject]@{startedAt='2026-01-01T00:00:00Z';endedAt='2026-01-01T00:00:01Z';exitCode=0;status='passed';stdout='{"schemaVersion":1,"status":"passed","decision":"PASS","candidateIdentity":"fixture-candidate"}';stderr='';cleanedUp=$true}
        }
        try {
            $failure=$null
            $result=$null
            $boundaryArguments=$fixture.arguments
            try { $result=Invoke-StandardValidationCommandAndRecord @boundaryArguments }
            catch { $failure=$_.Exception.Message }
            if($Mutation -ceq 'none' -and $null -ne $failure){throw "Unmodified fixture must pass: $failure"}
            Assert-MockCalled Invoke-StandardValidationProcess -Times 1 -Exactly -Scope It
            if($Mutation -ceq 'none') {
                if($null -ne $failure -or $result.event.exitCode -ne 0 -or $result.envelope.decision -cne 'PASS'){throw "Unmodified fixture must pass: $failure"}
            }
            elseif($null -eq $failure -or $failure -notmatch $Pattern){throw "Expected '$Pattern' for $Mutation; actual '$failure'."}
        }
        finally {
            $script:StandardValidationRepositoryRoot=$previousRoot
            $script:StandardValidationAuthorityEvidence=$null
            $script:StandardValidationLaunchBinding=$null
            $script:StandardValidationEvidenceArtifactLedger=New-Object 'Collections.Generic.List[object]'
        }
    }

    # Scenario: A protected artifact changes between capture and the next child invocation.
    # Purpose: Ensure the pre-child integrity boundary refuses the mutation before launching any process.
    It 'InterT35_refuses_pre_child_mutation_of_<Mutation>' -TestCases @(
        @{Mutation='add';Pattern='dependency closure changed'},@{Mutation='delete';Pattern='dependency closure changed'},@{Mutation='rename';Pattern='dependency closure changed'},@{Mutation='same-size-mtime';Pattern='dependency closure changed'},@{Mutation='receipt';Pattern='resolver receipt changed'},@{Mutation='authority';Pattern='central runner changed'},@{Mutation='snapshot';Pattern='Candidate snapshot changed'},@{Mutation='archive';Pattern='archive changed'},@{Mutation='acquisition';Pattern='candidate acquisition receipt changed'},@{Mutation='launch';Pattern='launch binding changed'},@{Mutation='evidence';Pattern='evidence artifact.*changed'}
    ) {
        param($Mutation,$Pattern)
        $fixture=New-Syp280BoundaryFixture
        $previousRoot=$script:StandardValidationRepositoryRoot
        $script:StandardValidationRepositoryRoot=$fixture.paths.authority
        $script:StandardValidationAuthorityEvidence=$fixture.authority
        $script:StandardValidationLaunchBinding=$fixture.launch
        $script:StandardValidationEvidenceArtifactLedger=New-Object 'Collections.Generic.List[object]'
        $script:StandardValidationEvidenceArtifactLedger.Add($fixture.evidence)
        Mock Invoke-StandardValidationProcess { throw 'A mutated pre-child fixture must never launch.' }
        try {
            Invoke-Syp280Mutation -Fixture $fixture -Mutation $Mutation
            $failure=$null
            $boundaryArguments=$fixture.arguments
            try { Invoke-StandardValidationCommandAndRecord @boundaryArguments }
            catch { $failure=$_.Exception.Message }
            Assert-MockCalled Invoke-StandardValidationProcess -Times 0 -Exactly -Scope It
            if($null -eq $failure -or $failure -notmatch $Pattern){throw "Expected '$Pattern' for $Mutation; actual '$failure'."}
        }
        finally {
            $script:StandardValidationRepositoryRoot=$previousRoot
            $script:StandardValidationAuthorityEvidence=$null
            $script:StandardValidationLaunchBinding=$null
            $script:StandardValidationEvidenceArtifactLedger=New-Object 'Collections.Generic.List[object]'
        }
    }

    # Scenario: The child exits unsuccessfully or is cancelled while emitting a superficially passing envelope.
    # Purpose: Retain the actual child exit code and status in raw evidence and refuse a forged success.
    It 'InterT40_retains_real_child_exit_code_for_<Status>' -TestCases @(
        @{Status='failed';ExitCode=23;Pattern='FAILED'},@{Status='cancelled';ExitCode=130;Pattern='CANCELLED'}
    ) {
        param($Status,$ExitCode,$Pattern)
        $fixture=New-Syp280BoundaryFixture
        $script:Syp280Status=$Status
        $script:Syp280ExitCode=$ExitCode
        Mock Invoke-StandardValidationProcess {
            [pscustomobject]@{startedAt='2026-01-01T00:00:00Z';endedAt='2026-01-01T00:00:01Z';exitCode=$script:Syp280ExitCode;status=$script:Syp280Status;stdout='{"schemaVersion":1,"status":"passed","decision":"PASS","candidateIdentity":"fixture-candidate"}';stderr='';cleanedUp=$true}
        }
        $failure=$null
        $boundaryArguments=$fixture.arguments
        try { Invoke-StandardValidationCommandAndRecord @boundaryArguments }
        catch { $failure=$_.Exception.Message }
        if ($null -eq $failure -or $failure -notmatch ('^'+$Pattern+'\|')) { throw 'Non-success child must be refused.' }
        $event=$script:StandardValidationLastEvent
        $raw=Get-Content -Raw -LiteralPath $event.outputPath | ConvertFrom-Json
        if ($event.exitCode -ne $ExitCode -or $raw.process.exitCode -ne $ExitCode -or $raw.process.status -cne $Status) {
            throw 'Timing or evidence must not replace the real child result.'
        }
    }
}

Describe 'SYP280 P2 inventory diagnostics real loops' {
    BeforeAll {
        $script:Syp280P2Runner=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-StandardValidation.ps1'
        . $script:Syp280P2Runner -CandidateRoot $TestDrive -AdapterPath (Join-Path $TestDrive 'p2-unused-adapter.json') -ArtifactsRoot (Join-Path $TestDrive 'p2-results') -SourceRepository 'https://example.test/source.git' -SourceRevision ('a' * 40) -BaseRevision ('b' * 40) -DefineFunctionsOnly
        function New-Syp280P2TwoFileFixture {
            $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($root)
            [IO.File]::WriteAllText((Join-Path $root 'command.bin'),'0000',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $root 'dependency.bin'),'0000',[Text.UTF8Encoding]::new($false))
            return $root
        }
    }

    Context 'Ordinary inventory real hash success' {
    # Scenario: The ordinary inventory hashes multiple real files while its clock advances deterministically.
    # Purpose: Require bounded progress from the real hashing loop without changing canonical inventory bytes.
    It 'UnitT30_reports_progress_during_real_file_inventory_hashing' {
        $root=New-Syp280P2TwoFileFixture
        $previousError=[Console]::Error
        $previousTiming=$script:StandardValidationTimingEnabled
        $capture=[IO.StringWriter]::new()
        $script:StandardValidationTimingEnabled=$true
        try {
            [Console]::SetError($capture)
            Mock New-StandardValidationPhase {
                param([string]$Stage,[string]$Phase,[switch]$Aggregate,[switch]$Silent)
                $clock=[pscustomobject]@{seconds=[double]0}
                $clock | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { $this.seconds += 31.0; [TimeSpan]::FromSeconds($this.seconds) } -Force
                $phaseTiming=[pscustomobject]@{stage=$Stage;phase=$Phase;watch=$clock;calls=[long]0;files=[long]0;bytes=[long]0;nextHeartbeat=[double]30;heartbeats=0;aggregate=[bool]$Aggregate;ticks=[long]0;silent=[bool]$Silent}
                Write-StandardValidationPhaseDiagnostic -Timing $phaseTiming -State 'started'
                $phaseTiming
            }
            $actual=Get-StandardValidationInventory -Root $root -Context 'fixture'
            $expectedRows=@(
                [pscustomobject]@{path='command.bin';sha256=(Get-StandardValidationFileSha256 -Path (Join-Path $root 'command.bin') -Context 'expected');length=4L},
                [pscustomobject]@{path='dependency.bin';sha256=(Get-StandardValidationFileSha256 -Path (Join-Path $root 'dependency.bin') -Context 'expected');length=4L}
            )
            $expectedCanonical=($expectedRows | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
            $expectedSha=Get-StandardValidationTextSha256 -Value $expectedCanonical
            if((Get-StandardValidationInventorySha256 -Inventory $actual) -cne $expectedSha){throw 'Real file inventory canonical SHA-256 changed.'}
            $records=@($capture.ToString().Trim().Split([char]10) | Where-Object { $_.IndexOf('{') -ge 0 } | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            $rows=@($records | Where-Object { $_.phase -ceq 'file-inventory' })
            if($rows.Count -lt 3 -or $rows[0].state -cne 'started' -or $rows[-1].state -cne 'completed') { throw "Real inventory needs a heartbeat before its successful terminal record; states=$($rows.state -join ',')." }
            if(@($rows | Where-Object { $_.state -ceq 'heartbeat' }).Count -lt 1) { throw 'Real inventory hashing did not emit a heartbeat.' }
            if($rows[-1].calls -ne 1 -or $rows[-1].files -ne 2 -or $rows[-1].bytes -ne 8 -or $rows[-1].elapsedSeconds -le 0) { throw 'Successful inventory phase counts or elapsed time differ.' }
        }
        finally {
            $script:StandardValidationTimingEnabled=$previousTiming
            [Console]::SetError($previousError)
            $capture.Dispose()
        }
    }
    }

    Context 'Ordinary inventory interrupted hash' {
    # Scenario: A real inventory hashes one file, then the next read fails or is cancelled.
    # Purpose: Preserve attempted-file counts and report the original terminal state after mid-loop interruption.
    It 'UnitT31_preserves_attempted_file_counts_before_hash_failure_or_cancellation' {
        $root=New-Syp280P2TwoFileFixture
        $previousError=[Console]::Error
        $previousTiming=$script:StandardValidationTimingEnabled
        $capture=[IO.StringWriter]::new()
        $script:StandardValidationTimingEnabled=$true
        $global:Syp280InventoryRoot=[IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $global:Syp280OriginalFileSha256=(Get-Command Get-StandardValidationFileSha256 -CommandType Function).ScriptBlock
        $global:Syp280HashCallCount=0
        $global:Syp280HashFailure='FAILED|controlled inventory hash failure'
        try {
            [Console]::SetError($capture)
            Mock New-StandardValidationPhase {
                param([string]$Stage,[string]$Phase,[switch]$Aggregate,[switch]$Silent)
                $clock=[pscustomobject]@{seconds=[double]0}
                $clock | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { $this.seconds += 31.0; [TimeSpan]::FromSeconds($this.seconds) } -Force
                $phaseTiming=[pscustomobject]@{stage=$Stage;phase=$Phase;watch=$clock;calls=[long]0;files=[long]0;bytes=[long]0;nextHeartbeat=[double]30;heartbeats=0;aggregate=[bool]$Aggregate;ticks=[long]0;silent=[bool]$Silent}
                Write-StandardValidationPhaseDiagnostic -Timing $phaseTiming -State 'started'
                $phaseTiming
            }
            Mock Get-StandardValidationFileSha256 {
                param([string]$Path,[string]$Context)
                if($Context -ceq 'fixture' -and [IO.Path]::GetFullPath($Path).StartsWith($global:Syp280InventoryRoot,[StringComparison]::Ordinal)) {
                    $global:Syp280HashCallCount++
                    if($global:Syp280HashCallCount -eq 2) { throw $global:Syp280HashFailure }
                }
                & $global:Syp280OriginalFileSha256 -Path $Path -Context $Context
            }
            $failure=$null
            try { Get-StandardValidationInventory -Root $root -Context 'fixture' | Out-Null }
            catch { $failure=$_.Exception.Message }
            if($failure -cne 'FAILED|controlled inventory hash failure') { throw "The real inventory must retain its mid-hash failure: '$failure'." }
            $failedRecords=@($capture.ToString().Trim().Split([char]10) | Where-Object { $_.IndexOf('{') -ge 0 } | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            $failedRows=@($failedRecords | Where-Object { $_.phase -ceq 'file-inventory' })
            $failedHeartbeatCount=@($failedRows | Where-Object state -eq 'heartbeat').Count
            if($failedRows[-1].state -cne 'failed' -or $failedRows[-1].files -ne 2 -or $failedRows[-1].bytes -ne 8 -or $failedHeartbeatCount -lt 1) { throw "Failed inventory must preserve attempted-file accounting and heartbeat before termination; state=$($failedRows[-1].state) files=$($failedRows[-1].files) bytes=$($failedRows[-1].bytes) heartbeats=$failedHeartbeatCount." }

            $capture.GetStringBuilder().Clear() | Out-Null
            $global:Syp280HashCallCount=0
            $global:Syp280HashFailure='CANCELLED|controlled inventory cancellation'
            $failure=$null
            try { Get-StandardValidationInventory -Root $root -Context 'fixture' | Out-Null }
            catch { $failure=$_.Exception.Message }
            if($failure -cne 'CANCELLED|controlled inventory cancellation') { throw "The real inventory must retain its mid-hash cancellation: '$failure'." }
            $cancelledRecords=@($capture.ToString().Trim().Split([char]10) | Where-Object { $_.IndexOf('{') -ge 0 } | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            $cancelledRows=@($cancelledRecords | Where-Object { $_.phase -ceq 'file-inventory' })
            if($cancelledRows[-1].state -cne 'cancelled' -or $cancelledRows[-1].files -ne 2 -or $cancelledRows[-1].bytes -ne 8 -or @($cancelledRows | Where-Object state -eq 'heartbeat').Count -lt 1) { throw 'Cancelled inventory must preserve attempted-file accounting and heartbeat before termination.' }
        }
        finally {
            $script:StandardValidationTimingEnabled=$previousTiming
            [Console]::SetError($previousError)
            $capture.Dispose()
            Remove-Variable -Name Syp280InventoryRoot,Syp280OriginalFileSha256,Syp280HashCallCount,Syp280HashFailure -Scope Global -ErrorAction SilentlyContinue
        }
    }
    }

    Context 'Closure real enumeration success' {
    # Scenario: The installed-directory closure is enumerated and hashed under a deterministic clock.
    # Purpose: Require a real enumeration heartbeat while retaining its canonical closure hash and work counts.
    It 'UnitT32_reports_progress_during_real_closure_enumeration' {
        $root=New-Syp280P2TwoFileFixture
        $expectedSha=Get-StandardValidationDirectoryClosureSha256 -Root $root -Context 'fixture'
        $previousError=[Console]::Error
        $previousTiming=$script:StandardValidationTimingEnabled
        $capture=[IO.StringWriter]::new()
        $script:StandardValidationTimingEnabled=$true
        try {
            [Console]::SetError($capture)
            Mock New-StandardValidationPhase {
                param([string]$Stage,[string]$Phase,[switch]$Aggregate,[switch]$Silent)
                $clock=[pscustomobject]@{seconds=[double]0}
                $clock | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { $this.seconds += 31.0; [TimeSpan]::FromSeconds($this.seconds) } -Force
                $phaseTiming=[pscustomobject]@{stage=$Stage;phase=$Phase;watch=$clock;calls=[long]0;files=[long]0;bytes=[long]0;nextHeartbeat=[double]30;heartbeats=0;aggregate=[bool]$Aggregate;ticks=[long]0;silent=[bool]$Silent}
                Write-StandardValidationPhaseDiagnostic -Timing $phaseTiming -State 'started'
                $phaseTiming
            }
            $actualSha=Get-StandardValidationDirectoryClosureSha256 -Root $root -Context 'fixture'
            if($actualSha -cne $expectedSha){throw 'Real closure enumeration changed the canonical closure SHA-256.'}
            $records=@($capture.ToString().Trim().Split([char]10) | Where-Object { $_.IndexOf('{') -ge 0 } | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            $rows=@($records | Where-Object { $_.phase -ceq 'closure-enumeration' })
            if($rows.Count -lt 3 -or $rows[0].state -cne 'started' -or $rows[-1].state -cne 'completed') { throw "Real closure enumeration needs a heartbeat before completion; states=$($rows.state -join ',')." }
            if(@($rows | Where-Object { $_.state -ceq 'heartbeat' }).Count -lt 1) { throw 'Real closure enumeration did not emit a heartbeat.' }
            if($rows[-1].calls -ne 1 -or $rows[-1].files -ne 2 -or $rows[-1].bytes -ne 8 -or $rows[-1].elapsedSeconds -le 0) { throw 'Successful closure enumeration counts or elapsed time differ.' }
        }
        finally {
            $script:StandardValidationTimingEnabled=$previousTiming
            [Console]::SetError($previousError)
            $capture.Dispose()
        }
    }
    }

    Context 'Closure interrupted enumeration' {
    # Scenario: Actual directory enumeration yields one real file, then reports failure or cancellation.
    # Purpose: Heartbeat inside the enumeration stream and retain its terminal state without changing files/bytes semantics.
    It 'UnitT33_reports_mid_enumeration_failure_and_cancellation' {
        $root=New-Syp280P2TwoFileFixture
        $previousError=[Console]::Error
        $previousTiming=$script:StandardValidationTimingEnabled
        $capture=[IO.StringWriter]::new()
        $script:StandardValidationTimingEnabled=$true
        $global:Syp280P2ClosureRoot=[IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $global:Syp280P2OriginalGetChildItem=Get-Command Get-ChildItem -CommandType Cmdlet
        $global:Syp280P2OriginalTimedPhase=(Get-Command Invoke-StandardValidationTimedPhase -CommandType Function).ScriptBlock
        $global:Syp280P2TimedEnumerationActive=$false
        $global:Syp280P2EnumerationCount=0
        $global:Syp280P2EnumerationFailure='FAILED|controlled closure enumeration failure'
        try {
            [Console]::SetError($capture)
            Mock New-StandardValidationPhase {
                param([string]$Stage,[string]$Phase,[switch]$Aggregate,[switch]$Silent)
                $clock=[pscustomobject]@{seconds=[double]0}
                $clock | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { $this.seconds += 31.0; [TimeSpan]::FromSeconds($this.seconds) } -Force
                $phaseTiming=[pscustomobject]@{stage=$Stage;phase=$Phase;watch=$clock;calls=[long]0;files=[long]0;bytes=[long]0;nextHeartbeat=[double]30;heartbeats=0;aggregate=[bool]$Aggregate;ticks=[long]0;silent=[bool]$Silent}
                Write-StandardValidationPhaseDiagnostic -Timing $phaseTiming -State 'started'
                $phaseTiming
            }
            Mock Invoke-StandardValidationTimedPhase {
                param([string]$Stage='validation',[string]$Phase,[scriptblock]$Action,[switch]$Silent)
                if($Phase -ceq 'closure-enumeration') {
                    $global:Syp280P2OriginalClosureAction=$Action
                    $scopedAction={
                        param($Timing)
                        $global:Syp280P2TimedEnumerationActive=$true
                        try { & $global:Syp280P2OriginalClosureAction $Timing }
                        finally { $global:Syp280P2TimedEnumerationActive=$false }
                    }.GetNewClosure()
                    & $global:Syp280P2OriginalTimedPhase -Stage $Stage -Phase $Phase -Action $scopedAction -Silent:$Silent
                }
                else {
                    & $global:Syp280P2OriginalTimedPhase -Stage $Stage -Phase $Phase -Action $Action -Silent:$Silent
                }
            }
            Mock Get-ChildItem {
                param([string]$LiteralPath,[switch]$Recurse,[switch]$Force)
                $actualRoot=[IO.Path]::GetFullPath($LiteralPath).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
                if($global:Syp280P2TimedEnumerationActive -and $actualRoot -ceq $global:Syp280P2ClosureRoot) {
                    & $global:Syp280P2OriginalGetChildItem -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop | ForEach-Object {
                        $global:Syp280P2EnumerationCount++
                        if($global:Syp280P2EnumerationCount -gt 1) { throw $global:Syp280P2EnumerationFailure }
                        $_
                    }
                }
                else { & $global:Syp280P2OriginalGetChildItem -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop }
            }
            $failure=$null
            try { Get-StandardValidationDirectoryClosureSha256 -Root $root -Context 'fixture' | Out-Null }
            catch { $failure=$_.Exception.Message }
            if($failure -cne 'FAILED|controlled closure enumeration failure') { throw "The real closure enumerator must retain its failure: '$failure'." }
            $failedRecords=@($capture.ToString().Trim().Split([char]10) | Where-Object { $_.IndexOf('{') -ge 0 } | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            $failedRows=@($failedRecords | Where-Object { $_.phase -ceq 'closure-enumeration' })
            $failedHeartbeatCount=@($failedRows | Where-Object state -eq 'heartbeat').Count
            if($failedRows[-1].state -cne 'failed' -or $failedRows[-1].files -ne 1 -or $failedRows[-1].bytes -ne 4 -or $failedHeartbeatCount -lt 1) { throw "Failed enumeration must report its yielded first file and heartbeat before termination; state=$($failedRows[-1].state) files=$($failedRows[-1].files) bytes=$($failedRows[-1].bytes) heartbeats=$failedHeartbeatCount." }

            $capture.GetStringBuilder().Clear() | Out-Null
            $global:Syp280P2EnumerationCount=0
            $global:Syp280P2EnumerationFailure='CANCELLED|controlled closure enumeration cancellation'
            $failure=$null
            try { Get-StandardValidationDirectoryClosureSha256 -Root $root -Context 'fixture' | Out-Null }
            catch { $failure=$_.Exception.Message }
            if($failure -cne 'CANCELLED|controlled closure enumeration cancellation') { throw "The real closure enumerator must retain its cancellation: '$failure'." }
            $cancelledRecords=@($capture.ToString().Trim().Split([char]10) | Where-Object { $_.IndexOf('{') -ge 0 } | ForEach-Object { $_.Substring($_.IndexOf('{')) | ConvertFrom-Json })
            $cancelledRows=@($cancelledRecords | Where-Object { $_.phase -ceq 'closure-enumeration' })
            if($cancelledRows[-1].state -cne 'cancelled' -or $cancelledRows[-1].files -ne 1 -or $cancelledRows[-1].bytes -ne 4 -or @($cancelledRows | Where-Object state -eq 'heartbeat').Count -lt 1) { throw 'Cancelled enumeration must report its yielded first file and heartbeat before termination.' }
        }
        finally {
            $script:StandardValidationTimingEnabled=$previousTiming
            [Console]::SetError($previousError)
            $capture.Dispose()
            Remove-Variable -Name Syp280P2ClosureRoot,Syp280P2OriginalGetChildItem,Syp280P2OriginalTimedPhase,Syp280P2OriginalClosureAction,Syp280P2TimedEnumerationActive,Syp280P2EnumerationCount,Syp280P2EnumerationFailure -Scope Global -ErrorAction SilentlyContinue
        }
    }
    }
}

Describe 'SYP258 source validation result gate' {
    BeforeAll { . (Join-Path $PSScriptRoot 'Initialize-SourceGateFixture.ps1') }

    # Scenario: Ordinary Core returns PASS without package-tool or complete Static evidence.
    # Purpose: V2 prevents repository-only success from satisfying the three source required contexts.
    It 'UnitT10_rejects_Core_only_PASS_as_source_validation_success' {
        $gate = Get-Command Assert-StandardCoreSourceCheckReport -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $gate) { throw 'The source report gate must exist before rejection can be verified.' }
        $report = New-SourceGateFixture
        if ((Invoke-SourceGateFixture -Report $report) -ne $true) { throw 'Complete baseline must pass before removal of source evidence.' }
        $report.PSObject.Properties.Remove('sourceValidation')
        $rejected = $false
        try { Invoke-SourceGateFixture -Report $report | Out-Null }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Core-only PASS must be rejected by source required-context projection.' }
    }

    # Scenario: One run contains both package tools for every discovered package, complete Static and passed repository tests.
    # Purpose: V1/V2 proves the rejection fixtures begin from a complete accepted report, rather than an unrelated invalid envelope.
    It 'UnitT20_accepts_one_complete_two_package_candidate_run' {
        $report=New-SourceGateFixture
        if ((Invoke-SourceGateFixture -Report $report) -ne $true) { throw 'Complete candidate-bound source evidence must pass.' }
    }

    Context 'Centrally owned raw source tests' {
    BeforeEach {
        # Unit fixtures mock only the authority Git transport. Actual test bytes and frozen hash checks remain real.
        $script:RawFixtureRevision=(git -C (Split-Path -Parent $PSScriptRoot) rev-parse HEAD).Trim()
        Mock Invoke-StandardCoreGit {
            param($RepositoryRoot,$WorkingDirectory,$Arguments)
            switch ($Arguments[0]) {
                'rev-parse' {return [pscustomobject]@{stdout=$script:RawFixtureRevision;exitCode=0}}
                'ls-files' {return [pscustomobject]@{stdout="tests/third-party-skill-source.Tests.ps1`ntests/third-party-source-envelope.Tests.ps1`n";exitCode=0}}
                'diff' {return [pscustomobject]@{stdout='';exitCode=0}}
                default {throw 'Unexpected authority Git fixture command.'}
            }
        }
    }
    # Scenario: The unmodified raw source has no upstream Pester files and its package stage binds the full frozen central suite.
    # Purpose: Keep candidate bytes intact while proving centrally owned tests under the same reviewed authority.
    It 'UnitT25_accepts_complete_frozen_central_raw_tests_without_upstream_test_files' {
        $report=New-SourceGateFixture -CentralRawTests
        if (Test-Path (Join-Path $report.artifacts.snapshotRoot 'tests')) { throw 'The raw fixture must contain no invented source tests.' }
        if ((Invoke-SourceGateFixture $report -ExpectedAuthorityRevision $report.authority.revision) -ne $true) { throw 'Complete central raw ownership evidence must pass.' }
    }

    # Scenario: One binding of an otherwise complete central raw suite is replaced or a required case is omitted.
    # Purpose: Prevent the ownership selector from becoming a test-filter, foreign-authority or raw-package bypass.
    It 'UnitT27_rejects_<Name>_from_central_raw_test_ownership' -TestCases @(
        @{Name='wrong_test_authority';Change={param($r) Set-SourceGateCases $r {param($c) $c.testSourceIdentity.authorityRevision='0'*40}}},
        @{Name='foreign_test_root';Change={param($r) Set-SourceGateCases $r {param($c) $c.testSourceIdentity.root='foreign-root'}}},
        @{Name='changed_test_hash';Change={param($r) Set-SourceGateCases $r {param($c) $c.testSourceIdentity.files[0].sha256='0'*64}}},
        @{Name='missing_test_file';Change={param($r) Set-SourceGateCases $r {param($c) $c.testFileInventory=@($c.testFileInventory[0])}}},
        @{Name='missing_discovered_case';Change={param($r) Set-SourceGateCases $r {param($c) $c.discoveryCases=@($c.discoveryCases[0])}}},
        @{Name='unfrozen_central_test';Change={param($r) $r.sourceValidation.frozenFiles=@($r.sourceValidation.frozenFiles | Where-Object {$_.path -notmatch 'third-party-skill-source.Tests.ps1$'})}},
        @{Name='not_raw_package';Change={param($r) Set-SourceGateEnvelope $r 0 {param($e) $e.PSObject.Properties.Remove('rawSourceEvidence')}}},
        @{Name='wrong_raw_candidate';Change={param($r) Set-SourceGateEnvelope $r 0 {param($e) $e.rawSourceEvidence.candidateIdentity.resolvedCommit='0'*40}}},
        @{Name='wrong_raw_repository';Change={param($r) Set-SourceGateEnvelope $r 0 {param($e) $e.rawSourceEvidence.candidateIdentity.repository='https://example.com/example/other.git'}}},
        @{Name='ordinary_source_substitution';Change={param($r) $r.sourceValidation.PSObject.Properties.Remove('testOwnership')}}
    ) {
        param($Name,$Change)
        $report=New-SourceGateFixture -CentralRawTests
        $revision=$report.authority.revision
        if ((Invoke-SourceGateFixture $report -ExpectedAuthorityRevision $revision) -ne $true) { throw 'Complete raw baseline must pass before mutation.' }
        & $Change $report
        $rejected=$false
        try { Invoke-SourceGateFixture $report -ExpectedAuthorityRevision $revision | Out-Null } catch {$rejected=$true}
        if (-not $rejected) { throw ('Central raw test substitution was accepted: '+$Name) }
    }
    }

    # Scenario: A complete report is altered in one required binding, process, package coverage or repository result.
    # Purpose: V2/V3 rejects incomplete or replaced evidence and preserves every real tool/Pester failure.
    It 'UnitT30_rejects_<Name>_from_source_required_contexts' -TestCases @(
        @{ Name='wrong_candidate_SHA'; Change={param($r) $r.candidate.sourceRevision='b' * 40} },
        @{ Name='wrong_base_SHA'; Change={param($r) $r.candidate.baseRevision='a' * 40} },
        @{ Name='wrong_authority_SHA'; Change={param($r) $r.sourceValidation.authorityRevision='a' * 40} },
        @{ Name='wrong_run'; Change={param($r) $r.sourceValidation.runId='d' * 32} },
        @{ Name='wrong_content'; Change={param($r) $r.sourceValidation.contentSha256='0' * 64} },
        @{ Name='wrong_derived_candidate'; Change={param($r) $r.adapter.sha256='0' * 64} },
        @{ Name='missing_tool_receipt'; Change={param($r) $r.sourceValidation.toolReceipts=@($r.sourceValidation.toolReceipts | Select-Object -Skip 1)} },
        @{ Name='wrong_receipt_run'; Change={param($r) Set-SourceGateReceipt $r {param($e) $e.resolutionRunId='0' * 32}} },
        @{ Name='wrong_receipt_source'; Change={param($r) Set-SourceGateReceipt $r {param($e) $e.source='https://example.test/untrusted'}} },
        @{ Name='empty_receipt_identity'; Change={param($r) Set-SourceGateReceipt $r {param($e) $e.resolvedIdentity=''}} },
        @{ Name='missing_installed_closure'; Change={param($r) Set-SourceGateReceipt $r {param($e) $e.PSObject.Properties.Remove('installedClosureSha256')}} },
        @{ Name='empty_install_root'; Change={param($r) Set-SourceGateReceipt $r {param($e) $e.installRoot=''}} },
        @{ Name='added_unfrozen_dependency'; Change={param($r) $receipt=Get-Content -Raw $r.sourceValidation.toolReceipts[0].path | ConvertFrom-Json; [IO.File]::WriteAllText((Join-Path $receipt.installRoot 'injected-dependency.bin'), 'unfrozen replacement dependency', (New-Object Text.UTF8Encoding($false)))} },
        @{ Name='event_command_receipt_hash'; Change={param($r) $r.sourceValidation.events[0].commandSha256=$r.sourceValidation.toolReceipts[0].sha256} },
        @{ Name='retained_adapter_replacement'; Change={param($r) [IO.File]::WriteAllText($r.sourceValidation.adapterSnapshot.path, '{}')} },
        @{ Name='native_report_replacement'; Change={param($r) $raw=Get-Content -Raw $r.sourceValidation.events[1].outputPath | ConvertFrom-Json; $envelope=$raw.stdout | ConvertFrom-Json; [IO.File]::WriteAllText($envelope.nativeReports[0].path, '{"fixture":"replaced"}')} },
        @{ Name='native_tools_payload_argument_substitution'; Change={param($r) Set-SourceGateEnvelope $r 2 {param($e) $e.nativeReports[0].arguments[0]='substituted-payload.js'}} },
        @{ Name='empty_inventory'; Change={param($r) $r.sourceValidation.activeSkills=@(); $r.candidate.activeSkills=@()} },
        @{ Name='duplicate_inventory'; Change={param($r) $r.sourceValidation.activeSkills=@('alpha','alpha'); $r.candidate.activeSkills=@('alpha','alpha')} },
        @{ Name='missing_package_event'; Change={param($r) $r.sourceValidation.events=@($r.sourceValidation.events | Select-Object -Skip 1)} },
        @{ Name='duplicate_event'; Change={param($r) $r.sourceValidation.events[1]=$r.sourceValidation.events[0]} },
        @{ Name='wrong_tool_identity'; Change={param($r) $r.sourceValidation.events[1].toolId='skill-tools'} },
        @{ Name='tool_exit_failure'; Change={param($r) $r.sourceValidation.events[1].exitCode=1} },
        @{ Name='tool_timeout'; Change={param($r) $r.sourceValidation.events[1].status='timed-out'} },
        @{ Name='tool_cleanup_failure'; Change={param($r) $r.sourceValidation.events[1].cleanedUp=$false} },
        @{ Name='wrong_envelope_candidate'; Change={param($r) Set-SourceGateEnvelope $r 1 {param($e) $e.candidateIdentity='0' * 64}} },
        @{ Name='wrong_envelope_package'; Change={param($r) Set-SourceGateEnvelope $r 1 {param($e) $e.skillId='beta'}} },
        @{ Name='incomplete_Static'; Change={param($r) Set-SourceGateEnvelope $r 5 {param($e) $e.analyzerCompleteness='partial'}} },
        @{ Name='Static_high_finding'; Change={param($r) Set-SourceGateEnvelope $r 5 {param($e) $e.findings=@([pscustomobject]@{severity='high'})}} },
        @{ Name='Static_medium_review'; Change={param($r) Set-SourceGateEnvelope $r 5 {param($e) $e.findings=@([pscustomobject]@{severity='medium'})}} },
        @{ Name='Static_unknown_severity'; Change={param($r) Set-SourceGateEnvelope $r 5 {param($e) $e.findings=@([pscustomobject]@{severity='unknown'})}} },
        @{ Name='Static_missing_package'; Change={param($r) Set-SourceGateEnvelope $r 5 {param($e) $e.activeSkills=@('alpha')}} },
        @{ Name='raw_replacement'; Change={param($r) [IO.File]::WriteAllText($r.sourceValidation.events[0].outputPath, '{}')} },
        @{ Name='version_only_output'; Change={param($r) $event=$r.sourceValidation.events[0]; $raw=Get-Content -Raw $event.outputPath | ConvertFrom-Json; $raw.stdout='tool v1.0.0'; $raw.process.stdout=$raw.stdout; $event.outputSha256=Get-StandardValidationOutputHash -Stdout $raw.stdout -Stderr ''; Write-SourceGateFixtureJson $event.outputPath $raw} },
        @{ Name='raw_cleanup_failure'; Change={param($r) $event=$r.sourceValidation.events[0]; $raw=Get-Content -Raw $event.outputPath | ConvertFrom-Json; $raw.process.cleanedUp=$false; Write-SourceGateFixtureJson $event.outputPath $raw} },
        @{ Name='raw_process_stream_mismatch'; Change={param($r) $event=$r.sourceValidation.events[0]; $raw=Get-Content -Raw $event.outputPath | ConvertFrom-Json; $raw.process.stdout='different stream'; Write-SourceGateFixtureJson $event.outputPath $raw} },
        @{ Name='Pester_zero_discovery'; Change={param($r) $r.checks[1].testCounts.total=0; $r.checks[1].testCounts.passed=0} },
        @{ Name='Pester_case_failure'; Change={param($r) $r.checks[1].testCounts.failed=1; $r.checks[1].testCounts.passed=1} },
        @{ Name='Pester_skip'; Change={param($r) $r.checks[1].testCounts.skipped=1; $r.checks[1].testCounts.passed=1} },
        @{ Name='repository_cleanup_failure'; Change={param($r) $r.checks[1].cleanedUp=$false} },
        @{ Name='repository_output_replacement'; Change={param($r) [IO.File]::WriteAllText($r.checks[1].stdoutPath, 'replaced output')} },
        @{ Name='Pester_raw_counts_mismatch'; Change={param($r) $check=$r.checks[1]; $raw=Get-Content -Raw $check.stdoutPath | ConvertFrom-Json; $raw.total=3; Write-SourceGateFixtureJson $check.stdoutPath $raw; $check.stdoutSha256=Get-StandardValidationFileSha256 -Path $check.stdoutPath -Context 'mutated Pester raw'} },
        @{ Name='Pester_block_failure'; Change={param($r) Set-SourceGateCases $r {param($e) $e.failedBlockCount=1}} },
        @{ Name='Pester_container_failure'; Change={param($r) Set-SourceGateCases $r {param($e) $e.failedContainerCount=1}} },
        @{ Name='Pester_discovery_error'; Change={param($r) Set-SourceGateCases $r {param($e) $e.errors=@('discovery failed')}} },
        @{ Name='Pester_partial_scope'; Change={param($r) Set-SourceGateCases $r {param($e) $e.runScope='focused'}} },
        @{ Name='Pester_incomplete_ledger'; Change={param($r) Set-SourceGateCases $r {param($e) $e.complete=$false}} },
        @{ Name='Pester_wrong_ledger_run'; Change={param($r) Set-SourceGateCases $r {param($e) $e.coreRunId='0' * 32}} },
        @{ Name='Pester_missing_executed_case'; Change={param($r) Set-SourceGateCases $r {param($e) $e.executionCases=@($e.executionCases | Select-Object -First 1)}} },
        @{ Name='Pester_failed_case_ledger'; Change={param($r) Set-SourceGateCases $r {param($e) $e.executionCases[0].result='Failed'}} },
        @{ Name='Pester_reported_failure_ledger'; Change={param($r) Set-SourceGateCases $r {param($e) $e.reportedCounts.Failed=1}} },
        @{ Name='Pester_incomplete_shard_union'; Change={param($r) Set-SourceGateCases $r {param($e) $e.shardUnion.complete=$false}} },
        @{ Name='Pester_duplicate_case_identity'; Change={param($r) Set-SourceGateCases $r {param($e) $e.executionCases[1]=$e.executionCases[0]}} },
        @{ Name='Pester_mismatched_case_set'; Change={param($r) Set-SourceGateCases $r {param($e) $e.executionCases[0].expandedPath='Another.UnitT10'; $tuple=ConvertTo-Json -InputObject ([object[]]@('FIXTURE.TESTS.PS1', 1, 'Another.UnitT10')) -Compress -Depth 3; $e.executionCases[0].identity=[Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($tuple))}} },
        @{ Name='Pester_wrong_snapshot_hash'; Change={param($r) Set-SourceGateCases $r {param($e) $e.candidateSnapshotSha256='0' * 64}} }
    ) {
        param([string] $Name, [scriptblock] $Change)
        $report=New-SourceGateFixture
        if ((Invoke-SourceGateFixture -Report $report) -ne $true) { throw "Baseline must pass before mutation '$Name'." }
        & $Change $report
        $rejected=$false
        try { Invoke-SourceGateFixture -Report $report | Out-Null } catch { $rejected=$true }
        if (-not $rejected) { throw "Source required-context gate accepted '$Name'." }
    }

    # Scenario: A frozen unsigned resolver receipt omits its executable, has an unsupported schema or substitutes the package launcher payload.
    # Purpose: V2 rejects malformed tool identities directly, before retained-adapter comparison can mask missing receipt validation.
    It 'UnitT40_rejects_unsigned_receipt_<Name>' -TestCases @(
        @{Name='missingExecutable';Index=0;Change={param($r) $r.PSObject.Properties.Remove('executablePath');$r.PSObject.Properties.Remove('executableSha256')}},
        @{Name='malformedResolver';Index=0;Change={param($r) $r.schemaVersion=9}},
        @{Name='launcherSubstitution';Index=1;Change={param($r) $r.launcher.payloadPath=$r.executablePath;$r.launcher.payloadSha256=$r.executableSha256;$r.launcherDigestSha256=Get-StandardValidationLauncherDigest -Launcher $r.launcher -Context 'substituted fixture launcher'}}
    ) {
        param([string]$Name,[int]$Index,[scriptblock]$Change)
        $report=New-SourceGateFixture
        Assert-StandardCoreSourceToolReceipts -Bindings $report.sourceValidation.toolReceipts -FrozenFiles $report.sourceValidation.frozenFiles -RunId $report.runId
        Set-SourceGateReceipt -Report $report -Mutate $Change -Index $Index
        $rejected=$false
        try { Assert-StandardCoreSourceToolReceipts -Bindings $report.sourceValidation.toolReceipts -FrozenFiles $report.sourceValidation.frozenFiles -RunId $report.runId } catch {$rejected=$true}
        if(-not $rejected){throw "Unsigned resolver receipt '$Name' was accepted."}
    }

    # Scenario: Source tools complete, then the general or Pester repository check fails before it can publish a case sidecar.
    # Purpose: V3 retains schema-valid source evidence on failure while requiring the complete case sidecar for source PASS.
    It 'UnitT50_requires_case_sidecar_only_for_top_level_source_PASS_<Kind>' -TestCases @(
        @{Kind='general';Expected=$true},@{Kind='pester';Expected=$true},@{Kind='pass';Expected=$false}
    ) {
        param([string]$Kind,[bool]$Expected)
        $report=New-SourceGateFixture
        $schemaPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/schemas/standard-core-evidence-v2.schema.json'
        $baselineJson=$report | ConvertTo-Json -Depth 100
        if(-not(Test-Json -Json $baselineJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue)){throw 'Complete source fixture must be schema-valid before removing the case sidecar.'}
        $report.sourceValidation.PSObject.Properties.Remove('pesterCaseInventory')
        if($Kind -cne 'pass'){
            $index=if($Kind -ceq 'general'){0}else{1}
            $report.state='FAILED';$report.exitCode=20;$report.failure=[pscustomobject]@{state='FAILED';message='Fixture repository check failed before sidecar creation.'}
            $report.checks[$index].status='failed';$report.checks[$index].exitCode=1
        }
        $valid=Test-Json -Json ($report | ConvertTo-Json -Depth 100) -SchemaFile $schemaPath -ErrorAction SilentlyContinue
        if($valid -ne $Expected){throw "Source '$Kind' without case sidecar has schema validity '$valid', expected '$Expected'."}
    }
}

Describe 'Agent Skill Repository Standard v1 contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:StandardsRoot = Join-Path $script:RepositoryRoot 'docs\standards'
        $script:IndexPath = Join-Path $script:StandardsRoot 'README.md'
        $script:StandardPath = Join-Path $script:StandardsRoot 'skill-repository-standard.md'
        $script:MatrixPath = Join-Path $script:StandardsRoot 'skill-repository-review-matrix.md'
        $script:ToolchainPath = Join-Path $script:StandardsRoot 'validation-toolchain.json'
        $script:SourceInventorySchemaPath = Join-Path $script:StandardsRoot 'schemas\source-inventory-v2.schema.json'
        $script:OpenAiMetadataSchemaPath = Join-Path $script:StandardsRoot 'schemas\openai-agent-metadata.schema.json'
        $script:LifecyclePath = Join-Path $script:StandardsRoot 'managed-skill-lifecycle.md'
        $script:LifecycleSchemaPath = Join-Path $script:StandardsRoot 'schemas\managed-skill-lifecycle-v1.schema.json'
        $script:UpstreamInteroperabilityPath = Join-Path $script:StandardsRoot 'upstream-interoperability.md'
        $script:UpstreamAdapterPolicyPath = Join-Path $script:StandardsRoot 'upstream-adapter.json'
        $script:UpstreamAdapterSchemaPath = Join-Path $script:StandardsRoot 'schemas\upstream-adapter-v1.schema.json'
        $script:ValidationSecurityGatePath = Join-Path $script:StandardsRoot 'validation-security-gate.json'
        $script:ValidationSecurityGateSchemaPath = Join-Path $script:StandardsRoot 'schemas\validation-security-gate-v1.schema.json'
        $script:StandardValidationAdapterSchemaPath = Join-Path $script:StandardsRoot 'schemas\standard-validation-adapter-v1.schema.json'
        $script:StandardValidationEvidenceSchemaPath = Join-Path $script:StandardsRoot 'schemas\standard-validation-evidence-v1.schema.json'
        $script:StandardSemanticConsentEvidenceV2SchemaPath = Join-Path $script:StandardsRoot 'schemas\standard-semantic-consent-evidence-v2.schema.json'
        $script:StandardValidationContractPath = Join-Path $script:StandardsRoot 'standard-validation-contract-v1.json'
        $script:ResolverPath = Join-Path $script:RepositoryRoot 'scripts\Resolve-StandardValidationTool.ps1'
        $script:PythonClosureHelperPath = Join-Path $script:RepositoryRoot 'scripts\Resolve-PythonWheelClosure.py'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-StandardAuthorityGate.ps1'
        $script:UpstreamAdapterValidatorPath = Join-Path $script:RepositoryRoot 'scripts\Validate-UpstreamAdapter.ps1'
        $script:WorkflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $script:RequiredPowerShellWorkflowPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'

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
            param([AllowNull()] $Actual, [string] $Pattern, [string] $Message)
            if ([string]$Actual -notmatch $Pattern) {
                $actualDisplay = if ($null -eq $Actual) { '<null>' } else { $Actual }
                throw "$Message Actual='$actualDisplay' Pattern='$Pattern'."
            }
        }

        function Assert-NotMatch {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -match $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Test-Syp325FixturePathChain {
            param([Parameter(Mandatory)][string] $Path)

            $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
            while ($null -ne $current) {
                if (-not $current.Exists -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
                $current = $current.Parent
            }
            return $true
        }

        function New-Syp325FixtureRoot {
            $candidates = [Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrWhiteSpace([string]$env:RUNNER_TEMP)) { $candidates.Add([string]$env:RUNNER_TEMP) }
            if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Temp')) }
            if (-not [string]::IsNullOrWhiteSpace([string]$env:TEMP)) { $candidates.Add([string]$env:TEMP) }
            try {
                $runtimeTempPath = [IO.Path]::GetTempPath()
                if (-not [string]::IsNullOrWhiteSpace([string]$runtimeTempPath)) { $candidates.Add([string]$runtimeTempPath) }
            }
            catch { }
            $candidates = @($candidates | Sort-Object { ([string]$_).Length })
            $errors = [Collections.Generic.List[string]]::new()

            foreach ($candidate in $candidates) {
                try {
                    $basePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$candidate))
                    if (-not (Test-Path -LiteralPath $basePath -PathType Container)) { continue }
                    if (-not (Test-Syp325FixturePathChain -Path $basePath)) { continue }

                    $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
                    $leaf = 'syp325-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
                    $root = [IO.Path]::GetFullPath((Join-Path $basePath $leaf))
                    if (-not [string]::Equals([IO.Path]::GetDirectoryName($root), $basePath, $pathComparison)) { throw 'The fixture root must be a direct child of its temporary base.' }
                    $placeholderRunId = 'a' * 32
                    $fallbackRoot = Join-Path $root 'Temp'
                    $deepestProbe = Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $fallbackRoot ("svt-tools-{0}" -f $placeholderRunId)) ('ss-' + ('a' * 12))) 'venv') 'Lib') (Join-Path 'site-packages' (('p' * 96) + '.probe'))
                    if ($deepestProbe.Length -ge 248) { continue }
                    if (Test-Path -LiteralPath $root) { throw "Refusing to reuse fixture path: $root" }
                    [void](New-Item -ItemType Directory -Path $root -ErrorAction Stop)
                    $script:Syp325FixtureRoots.Add([pscustomobject]@{ Root = $root; Base = $basePath })

                    $rootInfo = [IO.DirectoryInfo]::new($root)
                    if (-not $rootInfo.Exists -or ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        throw 'The newly created fixture root is missing or is a reparse point.'
                    }
                    if (-not [string]::Equals([IO.Path]::GetFullPath($rootInfo.FullName), $root, $pathComparison)) {
                        throw 'The created fixture root did not retain its canonical path.'
                    }
                    return [pscustomobject]@{ Root = $root; Base = $basePath }
                }
                catch { $errors.Add("'$candidate': $($_.Exception.Message)") }
            }

            throw "Unable to allocate a short create-only SYP325 fixture root. $($errors -join ' | ')"
        }

        function Remove-Syp325FixtureRoot {
            param([Parameter(Mandatory)] $Fixture)

            $basePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$Fixture.Base))
            $root = [IO.Path]::GetFullPath([string]$Fixture.Root)
            $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            $prefix = $basePath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $registered = @($script:Syp325FixtureRoots | Where-Object {
                [string]::Equals([IO.Path]::GetFullPath([string]$_.Root), $root, $pathComparison) -and
                [string]::Equals([IO.Path]::GetFullPath([string]$_.Base), $basePath, $pathComparison)
            })
            if ($registered.Count -ne 1 -or -not $root.StartsWith($prefix, $pathComparison) -or
                -not [string]::Equals([IO.Path]::GetDirectoryName($root), $basePath, $pathComparison) -or
                [IO.Path]::GetFileName($root) -notmatch '^syp325-[0-9a-f]{12}$') {
                throw "Refusing to clean a fixture outside its bounded task-owned root: '$root'."
            }
            if (-not (Test-Syp325FixturePathChain -Path $basePath)) { throw "Refusing to clean through a missing or reparse parent: '$basePath'." }
            $rootInfo = [IO.DirectoryInfo]::new($root)
            if (-not $rootInfo.Exists) { return }
            if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to recursively clean a reparse fixture root: '$root'." }
            if (-not [string]::Equals([IO.Path]::GetFullPath($rootInfo.FullName), $root, $pathComparison)) {
                throw "Refusing to clean a noncanonical fixture path: '$root'."
            }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        }

        $script:Syp325FixtureRoots = [Collections.Generic.List[object]]::new()

        function Get-CaseSensitiveProperty {
            param($Object, [string] $Name)

            if ($null -eq $Object -or $null -eq $Object.PSObject) { return $null }
            foreach ($property in @($Object.PSObject.Properties)) {
                if ([string]$property.Name -ceq $Name) { return $property }
            }
            return $null
        }

        function Assert-ExactPropertySet {
            param($Object, [string[]] $Expected, [string] $Message)

            $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
            Assert-Equal $actual.Count $Expected.Count "$Message Property count differs."
            foreach ($name in $Expected) {
                Assert-True ($actual -ccontains $name) "$Message Missing property '$name'."
            }
            foreach ($name in $actual) {
                Assert-True ($Expected -ccontains $name) "$Message Unexpected property '$name'."
            }
        }

        function Assert-ExactStringSequence {
            param($Actual, [string[]] $Expected, [string] $Message)

            $values = @($Actual)
            Assert-Equal $values.Count $Expected.Count "$Message Item count differs."
            for ($index = 0; $index -lt $Expected.Count; $index++) {
                Assert-True ([string]$values[$index] -ceq $Expected[$index]) "$Message Item $index differs."
            }
        }

        function Test-AuthorityJsonSchemaValue {
            param($Value, $Schema, $RootSchema)

            $referenceProperty = Get-CaseSensitiveProperty -Object $Schema -Name '$ref'
            if ($null -ne $referenceProperty) {
                $reference = [string]$referenceProperty.Value
                if (-not $reference.StartsWith('#/', [StringComparison]::Ordinal)) { return $false }
                $resolved = $RootSchema
                foreach ($segment in @($reference.Substring(2).Split('/'))) {
                    $segmentProperty = Get-CaseSensitiveProperty -Object $resolved -Name $segment
                    if ($null -eq $segmentProperty) { return $false }
                    $resolved = $segmentProperty.Value
                }
                return Test-AuthorityJsonSchemaValue -Value $Value -Schema $resolved -RootSchema $RootSchema
            }

            $oneOfProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'oneOf'
            if ($null -ne $oneOfProperty) {
                $schemaMatchCount = 0
                foreach ($candidateSchema in @($oneOfProperty.Value)) {
                    if (Test-AuthorityJsonSchemaValue -Value $Value -Schema $candidateSchema -RootSchema $RootSchema) {
                        $schemaMatchCount++
                    }
                }
                if ($schemaMatchCount -ne 1) { return $false }
            }

            $allOfProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'allOf'
            if ($null -ne $allOfProperty) {
                foreach ($candidateSchema in @($allOfProperty.Value)) {
                    if (-not (Test-AuthorityJsonSchemaValue -Value $Value -Schema $candidateSchema -RootSchema $RootSchema)) {
                        return $false
                    }
                }
            }

            $ifProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'if'
            if ($null -ne $ifProperty) {
                $conditionMatches = Test-AuthorityJsonSchemaValue -Value $Value -Schema $ifProperty.Value -RootSchema $RootSchema
                if ($conditionMatches) {
                    $thenProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'then'
                    if ($null -ne $thenProperty -and
                        -not (Test-AuthorityJsonSchemaValue -Value $Value -Schema $thenProperty.Value -RootSchema $RootSchema)) {
                        return $false
                    }
                }
                else {
                    $elseProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'else'
                    if ($null -ne $elseProperty -and
                        -not (Test-AuthorityJsonSchemaValue -Value $Value -Schema $elseProperty.Value -RootSchema $RootSchema)) {
                        return $false
                    }
                }
            }

            $constProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'const'
            if ($null -ne $constProperty) {
                $expected = $constProperty.Value
                if ($null -eq $expected) {
                    if ($null -ne $Value) { return $false }
                }
                elseif ($expected -is [string]) {
                    if ($Value -isnot [string] -or [string]$Value -cne [string]$expected) { return $false }
                }
                elseif (($expected -is [int] -or $expected -is [long] -or $expected -is [double] -or $expected -is [decimal]) -and
                    ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) {
                    if ([decimal]$Value -ne [decimal]$expected) { return $false }
                }
                elseif ($expected -is [array]) {
                    if ($Value -isnot [array] -or
                        ($Value | ConvertTo-Json -Depth 50 -Compress) -cne ($expected | ConvertTo-Json -Depth 50 -Compress)) {
                        return $false
                    }
                }
                elseif ($null -eq $Value -or $Value.GetType() -ne $expected.GetType() -or $Value -ne $expected) {
                    return $false
                }
            }

            $enumProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'enum'
            if ($null -ne $enumProperty) {
                $enumMatches = $false
                foreach ($enumValue in @($enumProperty.Value)) {
                    if ($null -eq $enumValue) {
                        if ($null -eq $Value) { $enumMatches = $true; break }
                    }
                    elseif ($enumValue -is [string]) {
                        if ($Value -is [string] -and [string]$Value -ceq [string]$enumValue) { $enumMatches = $true; break }
                    }
                    elseif ($enumValue -is [int] -or $enumValue -is [long] -or $enumValue -is [double] -or $enumValue -is [decimal]) {
                        if (($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) -and
                            [decimal]$Value -eq [decimal]$enumValue) {
                            $enumMatches = $true
                            break
                        }
                    }
                    elseif ($enumValue -is [bool] -and $Value -is [bool] -and $Value -eq $enumValue) {
                        $enumMatches = $true
                        break
                    }
                }
                if (-not $enumMatches) { return $false }
            }

            $typeProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'type'
            $type = if ($null -ne $typeProperty) { [string]$typeProperty.Value } else { '' }
            $isObject = $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [array] -and
                ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject])
            $isArray = $Value -is [array]
            if ($type -ceq 'object' -or ($type -ceq '' -and $isObject)) {
                if (-not $isObject) { return $false }

                $actualNames = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
                $requiredProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'required'
                if ($null -ne $requiredProperty) {
                    foreach ($name in @($requiredProperty.Value)) {
                        if (-not ($actualNames -ccontains [string]$name)) { return $false }
                    }
                }

                $propertiesProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'properties'
                $propertySchemas = if ($null -ne $propertiesProperty) { $propertiesProperty.Value } else { $null }
                $allowedNames = if ($null -ne $propertySchemas) {
                    @($propertySchemas.PSObject.Properties | ForEach-Object { [string]$_.Name })
                }
                else { @() }
                $additionalProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'additionalProperties'
                if ($null -ne $additionalProperty -and $additionalProperty.Value -is [bool] -and
                    -not [bool]$additionalProperty.Value) {
                    foreach ($name in $actualNames) {
                        if (-not ($allowedNames -ccontains $name)) { return $false }
                    }
                }
                foreach ($name in $allowedNames) {
                    $instanceProperty = Get-CaseSensitiveProperty -Object $Value -Name $name
                    if ($null -eq $instanceProperty) { continue }
                    $propertySchema = (Get-CaseSensitiveProperty -Object $propertySchemas -Name $name).Value
                    if (-not (Test-AuthorityJsonSchemaValue -Value $instanceProperty.Value -Schema $propertySchema -RootSchema $RootSchema)) {
                        return $false
                    }
                }
            }
            elseif ($type -ceq 'array' -or ($type -ceq '' -and $isArray)) {
                if ($Value -isnot [array]) { return $false }
                $items = @($Value)
                $minItemsProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'minItems'
                if ($null -ne $minItemsProperty -and $items.Count -lt [int]$minItemsProperty.Value) { return $false }
                $maxItemsProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'maxItems'
                if ($null -ne $maxItemsProperty -and $items.Count -gt [int]$maxItemsProperty.Value) { return $false }
                $uniqueProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'uniqueItems'
                if ($null -ne $uniqueProperty -and [bool]$uniqueProperty.Value) {
                    for ($left = 0; $left -lt $items.Count; $left++) {
                        $leftJson = $items[$left] | ConvertTo-Json -Depth 50 -Compress
                        for ($right = $left + 1; $right -lt $items.Count; $right++) {
                            $rightJson = $items[$right] | ConvertTo-Json -Depth 50 -Compress
                            if ($leftJson -ceq $rightJson) { return $false }
                        }
                    }
                }
                $prefixItemsProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'prefixItems'
                $prefixSchemas = @()
                if ($null -ne $prefixItemsProperty) {
                    $prefixSchemas = @($prefixItemsProperty.Value)
                    if ($items.Count -lt $prefixSchemas.Count) { return $false }
                    for ($index = 0; $index -lt $prefixSchemas.Count; $index++) {
                        if (-not (Test-AuthorityJsonSchemaValue -Value $items[$index] -Schema $prefixSchemas[$index] -RootSchema $RootSchema)) {
                            return $false
                        }
                    }
                }
                $itemsProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'items'
                if ($null -ne $itemsProperty -and $itemsProperty.Value -is [bool] -and -not [bool]$itemsProperty.Value -and
                    $items.Count -gt $prefixSchemas.Count) {
                    return $false
                }
                if ($null -ne $itemsProperty -and $itemsProperty.Value -isnot [bool]) {
                    foreach ($item in $items) {
                        if (-not (Test-AuthorityJsonSchemaValue -Value $item -Schema $itemsProperty.Value -RootSchema $RootSchema)) {
                            return $false
                        }
                    }
                }
                $containsProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'contains'
                if ($null -ne $containsProperty) {
                    $containsCount = 0
                    foreach ($item in $items) {
                        if (Test-AuthorityJsonSchemaValue -Value $item -Schema $containsProperty.Value -RootSchema $RootSchema) {
                            $containsCount++
                        }
                    }
                    if ($containsCount -lt 1) { return $false }
                }
            }
            elseif ($type -ceq 'string') {
                if ($Value -isnot [string]) { return $false }
                $text = [string]$Value
                $minLengthProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'minLength'
                if ($null -ne $minLengthProperty -and $text.Length -lt [int]$minLengthProperty.Value) { return $false }
                $maxLengthProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'maxLength'
                if ($null -ne $maxLengthProperty -and $text.Length -gt [int]$maxLengthProperty.Value) { return $false }
                $patternProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'pattern'
                if ($null -ne $patternProperty -and $text -cnotmatch [string]$patternProperty.Value) { return $false }
                $formatProperty = Get-CaseSensitiveProperty -Object $Schema -Name 'format'
                if ($null -ne $formatProperty -and [string]$formatProperty.Value -ceq 'uri') {
                    $uri = $null
                    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) { return $false }
                }
            }
            elseif ($type -ceq 'null') {
                if ($null -ne $Value) { return $false }
            }

            return $true
        }

        function Assert-AuthoritySchemaInstance {
            param($Value, $Schema, [string] $SchemaPath, [bool] $Expected, [string] $Message)

            $portableResult = Test-AuthorityJsonSchemaValue -Value $Value -Schema $Schema -RootSchema $Schema
            Assert-Equal ([bool]$portableResult) $Expected "$Message Portable schema evaluation differs."

            $testJsonCommand = Get-Command Test-Json -ErrorAction SilentlyContinue
            if ($null -ne $testJsonCommand -and $testJsonCommand.Parameters.ContainsKey('SchemaFile')) {
                $json = $Value | ConvertTo-Json -Depth 50 -Compress
                try {
                    $nativeResult = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
                catch {
                    $nativeResult = $false
                }
                Assert-Equal ([bool]$nativeResult) $Expected "$Message Test-Json result differs."
            }
        }

        function Copy-TestJsonObject {
            param($Value)
            return ($Value | ConvertTo-Json -Depth 50 -Compress | ConvertFrom-Json)
        }

        function Test-SourceInventoryExecutableContract {
            param(
                $Inventory,
                [string] $ExpectedSourceId,
                [string] $ExpectedRepository,
                [string[]] $PackageDirectoryNames
            )

            if ($Inventory.sourceId -isnot [string] -or [string]$Inventory.sourceId -cne $ExpectedSourceId) { return $false }
            if ($Inventory.repository -isnot [string] -or [string]$Inventory.repository -cne $ExpectedRepository) { return $false }
            if ($Inventory.skills -isnot [array]) { return $false }
            $skills = [string[]]@($Inventory.skills)
            for ($index = 1; $index -lt $skills.Count; $index++) {
                if ([StringComparer]::Ordinal.Compare($skills[$index - 1], $skills[$index]) -ge 0) { return $false }
            }
            $directories = [string[]]@($PackageDirectoryNames)
            [Array]::Sort($directories, [StringComparer]::Ordinal)
            if ($skills.Count -ne $directories.Count) { return $false }
            for ($index = 0; $index -lt $skills.Count; $index++) {
                if ($skills[$index] -cne $directories[$index]) { return $false }
            }
            return $true
        }

        function Write-TestUtf8File {
            param([string] $Path, [string] $Text)

            $parent = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function New-TestAuthorityFixture {
            param([string] $Root)

            [void](New-Item -ItemType Directory -Path $Root -Force)
            $skillPath = Join-Path $Root 'SKILL.md'
            $metadataPath = Join-Path $Root 'agents/openai.yaml'
            $skillText = (@(
                '---',
                'name: standard-validation-fixture',
                'description: A deterministic Agent Skill package for authority validation.',
                '---',
                '',
                '# Standard Validation Fixture',
                '',
                'Validate the canonical toolchain.'
            ) -join "`n") + "`n"
            $metadataText = (@(
                'interface:',
                '  display_name: "Standard Validation Fixture"',
                '  short_description: "Validate one deterministic canonical Skill package."',
                '  default_prompt: "Use $standard-validation-fixture to verify the canonical validation toolchain."'
            ) -join "`n") + "`n"
            Write-TestUtf8File -Path $skillPath -Text $skillText
            Write-TestUtf8File -Path $metadataPath -Text $metadataText
            return [pscustomobject]@{ Root=$Root; SkillPath=$skillPath; MetadataPath=$metadataPath }
        }

        function New-TestWheel {
            param(
                [Parameter(Mandatory = $true)][string] $Root,
                [Parameter(Mandatory = $true)][string] $Name,
                [Parameter(Mandatory = $true)][string] $Version,
                [string[]] $RequiresDist = @()
            )

            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $distName = ($Name -replace '-', '_')
            $metadata = "Metadata-Version: 2.4`nName: $Name`nVersion: $Version`n"
            foreach ($requirement in $RequiresDist) {
                $metadata += "Requires-Dist: $requirement`n"
            }
            $wheelPath = Join-Path $Root ("$distName-$Version-py3-none-any.whl")
            $archive = [IO.Compression.ZipFile]::Open($wheelPath, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $archive.CreateEntry("$distName-$Version.dist-info/METADATA")
                $stream = $entry.Open()
                try {
                    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($metadata)
                    $stream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $stream.Dispose()
                }
            }
            finally {
                $archive.Dispose()
            }
            return $wheelPath
        }
    }

    AfterEach {
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        try {
            foreach ($fixture in @($script:Syp325FixtureRoots.ToArray())) {
                try { Remove-Syp325FixtureRoot -Fixture $fixture }
                catch { $cleanupErrors.Add($_.Exception.Message) }
            }
        }
        finally { $script:Syp325FixtureRoots.Clear() }
        if ($cleanupErrors.Count -gt 0) { throw "SYP325 fixture cleanup failed: $($cleanupErrors -join ' | ')" }
    }

    It 'UnitT10_keeps_the_normative_standard_evidence_toolchain_and_resolver_together' {
        Assert-True (Test-Path -LiteralPath $script:IndexPath -PathType Leaf) 'Missing standards index.'
        Assert-True (Test-Path -LiteralPath $script:StandardPath -PathType Leaf) 'Missing normative Standard.'
        Assert-True (Test-Path -LiteralPath $script:MatrixPath -PathType Leaf) 'Missing cross-repository review matrix.'
        Assert-True (Test-Path -LiteralPath $script:ToolchainPath -PathType Leaf) 'Missing validation toolchain policy.'
        Assert-True (Test-Path -LiteralPath $script:ResolverPath -PathType Leaf) 'Missing central validation tool resolver.'
        Assert-True (Test-Path -LiteralPath $script:PythonClosureHelperPath -PathType Leaf) 'Missing verified Python wheel closure helper.'
        Assert-True (Test-Path -LiteralPath $script:AuthorityGatePath -PathType Leaf) 'Missing shared Standard authority gate.'
        Assert-True (Test-Path -LiteralPath $script:ValidationSecurityGatePath -PathType Leaf) 'Missing canonical validation/security gate policy.'
        Assert-True (Test-Path -LiteralPath $script:ValidationSecurityGateSchemaPath -PathType Leaf) 'Missing canonical validation/security gate schema.'
        Assert-True (Test-Path -LiteralPath $script:WorkflowPath -PathType Leaf) 'Missing Standards Conformance workflow.'
        Assert-True (Test-Path -LiteralPath $script:RequiredPowerShellWorkflowPath -PathType Leaf) 'Missing required PowerShell workflow authority bridge.'

        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        Assert-Match $index 'skill-repository-standard\.md' 'Standards index must link the normative Standard.'
        Assert-Match $index 'skill-repository-review-matrix\.md' 'Standards index must link the review matrix.'
        Assert-Match $index 'validation-toolchain\.json' 'Standards index must link the toolchain policy.'
        Assert-Match $index 'validation-security-gate\.json' 'Standards index must link the canonical validation/security gate policy.'
        Assert-Match $index 'validation-security-gate-v1\.schema\.json' 'Standards index must link the canonical validation/security gate schema.'
        Assert-Match $index 'Resolve-StandardValidationTool\.ps1' 'Standards index must name the central validation tool resolver.'
    }

    # Scenario: The authority policy is loaded with every supported validation provider and distribution control.
    # Purpose: Protect the complete latest-stable source, endpoint, and cache-isolation trust contract.
    It 'UnitT20_requires_latest_stable_tools_trusted_sources_and_resolved_identity_evidence' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json

        Assert-Equal $toolchain.schemaVersion 1 'Unexpected toolchain schemaVersion.'
        Assert-Equal $toolchain.policy 'latest-stable-per-validation-run' 'Canonical validation must default to latest stable.'
        Assert-Equal $toolchain.sourceTrust.enforcement 'exact-approved-source' 'Tool sources must use exact approved-source enforcement.'
        Assert-Equal $toolchain.sourceTrust.resolver 'scripts/Resolve-StandardValidationTool.ps1' 'Tool policy must name the central resolver.'
        Assert-True ([bool]$toolchain.sourceTrust.failClosedOnMismatch) 'Tool source mismatch must fail closed.'
        Assert-True ([bool]$toolchain.resolution.resolveAtRunStart) 'Toolchain must resolve at run start.'
        Assert-True ([bool]$toolchain.resolution.freezeForRun) 'Resolved toolchain must freeze for one run.'
        Assert-True ([bool]$toolchain.resolution.recordResolvedVersion) 'Resolved version must be recorded.'
        Assert-True ([bool]$toolchain.resolution.recordResolvedIdentityWhenAvailable) 'Resolved immutable/package identity must be recorded when available.'
        Assert-True (-not [bool]$toolchain.resolution.allowPrerelease) 'Prerelease tools must not be the default.'

        $expectedSources = [ordered]@{
            'skillspector' = 'NVIDIA/SkillSpector'
            'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
            'skill-tools' = 'npm:skill-tools'
            'pester' = 'PowerShellGallery:Pester'
        }

        foreach ($entry in $expectedSources.GetEnumerator()) {
            Assert-Equal $toolchain.tools.($entry.Key).source $entry.Value "$($entry.Key) must use its approved source."
            Assert-Equal $toolchain.tools.($entry.Key).channel 'latest-stable' "$($entry.Key) must use latest-stable."
        }

        Assert-Equal $toolchain.tools.skillspector.releaseVersionRule 'v-semver-release-only' 'SkillSpector release tags must use stable v-semver.'
        Assert-Equal $toolchain.tools.skillspector.pythonPackageIndex 'https://pypi.org/simple' 'SkillSpector dependencies must use the approved PyPI index.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.configIsolation 'os.devnull' 'pip configuration must be isolated.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.environmentOverridePolicy 'deny-by-default' 'Inherited pip environment must be denied by default.'
        $allowedPipEnvironment = @($toolchain.tools.skillspector.pythonDistribution.allowedInheritedEnvironment)
        Assert-Equal $allowedPipEnvironment.Count 1 'Exactly one inherited pip variable may be conditionally accepted.'
        Assert-Equal $allowedPipEnvironment[0] 'PIP_INDEX_URL' 'Only the approved PIP_INDEX_URL may be inherited.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.rejectInheritedPythonEnvironment) 'Python startup/import environment must fail closed.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.onlyBinary) 'SkillSpector dependencies must resolve to wheels only.'
        Assert-True ($null -ne $toolchain.tools.skillspector.pythonDistribution.PSObject.Properties['allowDirectReferences']) 'SkillSpector direct-reference policy must be explicit.'
        Assert-False ([bool]$toolchain.tools.skillspector.pythonDistribution.allowDirectReferences) 'SkillSpector dependencies must not bypass PyPI with direct references.'
        Assert-False ([bool]$toolchain.tools.skillspector.pythonDistribution.allowPipOnlineDependencyTraversal) 'pip must not traverse dependency metadata online.'
        Assert-False ([bool]$toolchain.tools.skillspector.pythonDistribution.allowYanked) 'Yanked dependency candidates must not enter the verified pool.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.disableCache) 'SkillSpector dependency acquisition must disable pip cache.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.candidateDiscovery 'approved-simple-json-lazy' 'Candidate discovery must use the approved Simple JSON API lazily.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.requiresPythonPolicy 'simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' 'Simple JSON and wheel METADATA Requires-Python normalized specifier sets must agree and allow the current interpreter.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.dependencyAcquisition 'verified-wheelhouse' 'SkillSpector dependencies must use a verified wheelhouse.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.dependencyResolver 'pip-offline-backtracking' 'pip must backtrack only against the verified local wheel pool.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.installEnvironment 'isolated-venv' 'SkillSpector must install in an isolated virtual environment.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.interpreterIsolation 'python-isolated-mode' 'Every resolver-managed SkillSpector Python subprocess must ignore inherited interpreter controls.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.credentialIsolation 'github-token-cleared-before-python' 'Resolver-managed Python must start only after GitHub credentials are removed.'
        Assert-Equal $toolchain.tools.skillspector.pythonDistribution.installedMetadataVerification 'static-dist-info-metadata' 'Installed identity must be verified without starting installed Python.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.verifyOfflineResolution) 'The completed wheelhouse must pass a fully offline dependency resolution.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.installNoIndex) 'SkillSpector install must be no-index.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.requireHashes) 'SkillSpector install must require hashes.'
        Assert-True ([bool]$toolchain.tools.skillspector.pythonDistribution.recordDependencyClosureHashes) 'SkillSpector dependency closure hashes must be recorded.'

        Assert-Equal $toolchain.tools.'skill-tools'.registry 'https://registry.npmjs.org/' 'skill-tools must use the approved npm registry.'
        Assert-Equal $toolchain.tools.'skill-tools'.npmDistribution.configIsolation 'empty-config-and-workdir' 'npm configuration and project discovery must be isolated.'
        Assert-Equal $toolchain.tools.'skill-tools'.npmDistribution.environmentOverridePolicy 'deny-by-default' 'Inherited npm configuration must be denied by default.'
        Assert-True ([bool]$toolchain.tools.'skill-tools'.npmDistribution.ignoreScripts) 'npm lifecycle scripts must be disabled.'
        Assert-True ([bool]$toolchain.tools.'skill-tools'.npmDistribution.recordDependencyClosureIntegrity) 'npm dependency closure integrity must be recorded.'
        Assert-Equal $toolchain.tools.'skill-validator'.stableVersionRule 'release-semver-only' 'skill-validator must require release SemVer.'
        Assert-Equal $toolchain.tools.'skill-validator'.proxy 'https://proxy.golang.org' 'skill-validator must use the approved Go module proxy.'
        Assert-Equal $toolchain.tools.'skill-validator'.checksumDatabase 'sum.golang.org' 'skill-validator must use the approved Go checksum database.'
        Assert-Equal $toolchain.tools.'skill-validator'.goRuntimeVersion 'latest-stable' 'skill-validator must use the latest stable Go runtime rule.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOENV 'off' 'Go persisted environment configuration must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOPROXY 'https://proxy.golang.org' 'Go proxy environment must be fixed.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOSUMDB 'sum.golang.org' 'Go checksum database environment must be fixed.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOPRIVATE '' 'GOPRIVATE must not bypass canonical distribution.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GONOPROXY 'none' 'GONOPROXY must not bypass the approved proxy.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GONOSUMDB 'none' 'GONOSUMDB must not bypass checksum verification.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOINSECURE '' 'GOINSECURE must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOFLAGS '' 'GOFLAGS must not inject caller-controlled build behavior.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOTOOLCHAIN 'local' 'Go toolchain auto-download must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.GOWORK 'off' 'Go workspace discovery must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goEnvironment.CGO_ENABLED '0' 'CGO tool execution must be disabled.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.moduleCacheIsolation 'temporary-empty' 'Go module resolution must use a fresh temporary module cache.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.buildCacheIsolation 'temporary-empty' 'Go builds must use a fresh build cache.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.temporaryDirectoryIsolation 'temporary-empty' 'Go builds must use a fresh temporary directory.'
        Assert-Equal $toolchain.tools.'skill-validator'.goDistribution.binaryInstallIsolation 'run-owned' 'Go binaries must install into a run-owned directory.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectInheritedModuleCache) 'An inherited Go module cache override must fail closed.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectInheritedBuildCache) 'An inherited Go build cache override must fail closed.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.rejectDangerousEnvironment) 'Dangerous Go build environment must fail closed.'
        Assert-True ([bool]$toolchain.tools.'skill-validator'.goDistribution.recordBinaryHash) 'Installed Go binary hashes must be recorded.'
        Assert-Equal $toolchain.tools.pester.repository 'https://www.powershellgallery.com/api/v2' 'Pester must use the approved PowerShell Gallery endpoint.'
        Assert-Equal $toolchain.tools.pester.approvedPayload.version '6.2.0' 'Pester payload approval must name the reviewed latest-stable version.'
        Assert-Equal $toolchain.tools.pester.approvedPayload.sha256 '0182e2c58c18b916d0d98f0f9f0e95be688bf424cf1869850ebd373e3ab75229' 'Pester payload approval must pin the reviewed executable package content.'
        Assert-True ([bool]$toolchain.compatibilityLane.mayPinOlderVersion) 'Compatibility lanes may pin an older version.'
        Assert-True ([bool]$toolchain.compatibilityLane.requiresExplicitPurpose) 'Compatibility pins require an explicit purpose.'
        Assert-True (-not [bool]$toolchain.compatibilityLane.mayBeCanonicalReleaseGate) 'Compatibility lane must not be the canonical release gate.'
    }

    It 'UnitT25_rejects_an_unapproved_validation_tool_source_before_resolution' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.tools.skillspector.source = 'example.invalid/SkillSpector'
        $unapprovedPath = Join-Path $TestDrive 'unapproved-validation-toolchain.json'
        $json = $toolchain | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($unapprovedPath, $json, (New-Object Text.UTF8Encoding($false)))

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $unapprovedPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        Assert-Match $errorMessage 'Untrusted validation tool source.*skillspector' 'Unapproved tool source must fail closed.'
    }

    It 'UnitT25a_rejects_string_values_for_boolean_policy_controls' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.sourceTrust.failClosedOnMismatch = 'true'
        $invalidPath = Join-Path $TestDrive 'string-boolean-validation-toolchain.json'
        [IO.File]::WriteAllText($invalidPath, ($toolchain | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $invalidPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        Assert-Match $errorMessage 'failClosedOnMismatch.*boolean' 'A string that looks like a boolean must not satisfy a JSON boolean control.'
    }

    It 'UnitT25b_rejects_unexpected_policy_keys' {
        $toolchain = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ToolchainPath | ConvertFrom-Json
        $toolchain.tools.skillspector.pythonDistribution | Add-Member -NotePropertyName futureBypass -NotePropertyValue $true
        $invalidPath = Join-Path $TestDrive 'extra-key-validation-toolchain.json'
        [IO.File]::WriteAllText($invalidPath, ($toolchain | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))

        $errorMessage = $null
        try {
            & $script:ResolverPath -PolicyPath $invalidPath -ValidatePolicyOnly | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        Assert-Match $errorMessage 'pythonDistribution.*invalid property set.*futureBypass' 'Unknown policy controls must fail closed.'
    }

    It 'UnitT26_rejects_an_unapproved_npm_registry_before_skill_tools_resolution' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $previous = @(@(Get-ProcessNpmEnvironmentNames) + @(Get-ProcessNodeEnvironmentNames) | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        $errorMessage = $null
        try {
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $null, [EnvironmentVariableTarget]::Process)
            }
            [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'https://registry.example.invalid/', [EnvironmentVariableTarget]::Process)
            Assert-NoConflictingNpmEnvironment -ExpectedRegistry 'https://registry.npmjs.org/'
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        finally {
            foreach ($name in @(@(Get-ProcessNpmEnvironmentNames) + @(Get-ProcessNodeEnvironmentNames))) {
                [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
            }
        }

        Assert-Match $errorMessage 'Untrusted npm registry' 'An npm registry override must fail closed before package resolution.'
    }

    It 'UnitT26a_rejects_untrusted_pip_distribution_overrides_before_dependency_resolution' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $cases = @(
            @{ Name = 'PIP_INDEX_URL'; Value = 'https://pypi.example.invalid/simple' },
            @{ Name = 'PIP_EXTRA_INDEX_URL'; Value = 'https://extra.example.invalid/simple' },
            @{ Name = 'PIP_CONFIG_FILE'; Value = 'custom-pip.conf' },
            @{ Name = 'PIP_FIND_LINKS'; Value = 'https://files.example.invalid/' },
            @{ Name = 'PIP_TRUSTED_HOST'; Value = 'example.invalid' },
            @{ Name = 'PIP_NO_INDEX'; Value = '1' },
            @{ Name = 'PIP_CERT'; Value = 'custom-ca.pem' },
            @{ Name = 'PIP_CLIENT_CERT'; Value = 'client.pem' },
            @{ Name = 'PIP_REQUIREMENT'; Value = 'https://files.example.invalid/requirements.txt' },
            @{ Name = 'PIP_CONSTRAINT'; Value = 'https://files.example.invalid/constraints.txt' },
            @{ Name = 'PIP_FUTURE_UNTRUSTED_OPTION'; Value = '1' }
        )

        $environmentNames = @(Get-OrdinalUniqueStrings -Values @((Get-ProcessPipEnvironmentNames) + @($cases.Name)))
        $previous = @($environmentNames | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        try {
            foreach ($case in $cases) {
                foreach ($name in $environmentNames) {
                    [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
                }
                $errorMessage = $null
                try {
                [Environment]::SetEnvironmentVariable($case.Name, $case.Value, [EnvironmentVariableTarget]::Process)
                Assert-NoConflictingPipEnvironment -ApprovedIndex 'https://pypi.org/simple'
                }
                catch {
                    $errorMessage = $_.Exception.Message
                }

                Assert-Match $errorMessage ("Untrusted pip environment override.*{0}" -f $case.Name) ("pip override {0} must fail before dependency resolution." -f $case.Name)
            }
        }
        finally {
            foreach ($name in $environmentNames) {
                [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT26b_accepts_the_approved_pip_environment_and_executes_the_action' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $names = @(Get-OrdinalUniqueStrings -Values @(
            (Get-ProcessPipEnvironmentNames) + (Get-ProcessPythonEnvironmentNames) + @('PIP_INDEX_URL', 'PIP_CONFIG_FILE')
        ))
        $previous = [ordered]@{}
        try {
            foreach ($name in $names) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }

            $result = Invoke-WithApprovedPipEnvironment -ApprovedIndex 'https://pypi.org/simple' -Action {
                $index = [Environment]::GetEnvironmentVariable('PIP_INDEX_URL', [EnvironmentVariableTarget]::Process)
                $configFile = [Environment]::GetEnvironmentVariable('PIP_CONFIG_FILE', [EnvironmentVariableTarget]::Process)
                if ($index -notmatch '^https://pypi\.org/simple/?$') { throw 'Approved pip index was not applied.' }
                if ([string]::IsNullOrWhiteSpace($configFile)) { throw 'pip config isolation was not applied.' }
                $unexpected = @(Get-ProcessPipEnvironmentNames | Where-Object {
                    $_ -notin @('PIP_INDEX_URL', 'PIP_CONFIG_FILE') -and
                    -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_, [EnvironmentVariableTarget]::Process))
                })
                if ($unexpected.Count -gt 0) { throw "Unexpected effective pip environment override: $($unexpected -join ', ')" }
                $unexpectedPython = @(Get-ProcessPythonEnvironmentNames | Where-Object {
                    -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, [EnvironmentVariableTarget]::Process))
                })
                if ($unexpectedPython.Count -gt 0) { throw "Unexpected effective Python environment override: $($unexpectedPython -join ', ')" }
                'approved-pip-action-ran'
            }
            Assert-Equal $result 'approved-pip-action-ran' 'Approved pip environment must reach the action.'
        }
        finally {
            foreach ($entry in $previous.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT26ba_rejects_Python_import_overrides_without_rejecting_setup_python_runner_metadata' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $transportOverrides = @('REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR')
        $names = @('pythonLocation', 'Python_ROOT_DIR', 'Python3_ROOT_DIR', 'PYTHONPATH') + $transportOverrides
        $previous = @($names | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        try {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }
            [Environment]::SetEnvironmentVariable('pythonLocation', '/runner/toolcache/python', [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('Python_ROOT_DIR', '/runner/toolcache/python', [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('Python3_ROOT_DIR', '/runner/toolcache/python', [EnvironmentVariableTarget]::Process)
            Assert-NoConflictingPythonEnvironment
            $detectedPythonOverrides = @(Get-ProcessPythonEnvironmentNames | Where-Object {
                -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, [EnvironmentVariableTarget]::Process))
            })
            Assert-Equal $detectedPythonOverrides.Count 0 ("setup-python metadata must not be mistaken for interpreter startup configuration. Detected='{0}'." -f ($detectedPythonOverrides -join ','))

            foreach ($case in @(
                @{ Name = 'PYTHONPATH'; Value = '/untrusted/import-root' },
                @{ Name = 'REQUESTS_CA_BUNDLE'; Value = '/untrusted/requests-ca.pem' },
                @{ Name = 'CURL_CA_BUNDLE'; Value = '/untrusted/curl-ca.pem' },
                @{ Name = 'SSL_CERT_FILE'; Value = '/untrusted/openssl-ca.pem' },
                @{ Name = 'SSL_CERT_DIR'; Value = '/untrusted/openssl-ca-dir' }
            )) {
                [Environment]::SetEnvironmentVariable([string]$case.Name, [string]$case.Value, [EnvironmentVariableTarget]::Process)
                $errorMessage = $null
                try { Assert-NoConflictingPythonEnvironment }
                catch { $errorMessage = $_.Exception.Message }
                Assert-Match $errorMessage ("Untrusted Python environment override.*{0}" -f $case.Name) "$($case.Name) must fail closed before Python network or interpreter execution."
                [Environment]::SetEnvironmentVariable([string]$case.Name, $null, [EnvironmentVariableTarget]::Process)
            }
        }
        finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    # Scenario: Cross-platform test wheels expose standards-compliant METADATA entries using ZIP forward slashes.
    # Purpose: Verify dependency closure hashing without allowing host-specific archive separators to invalidate the fixture.
    It 'UnitT26c_builds_a_hash_locked_dependency_closure_from_wheels_only' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $wheelhouse = Join-Path $TestDrive 'wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse -Force)
        [void](New-TestWheel -Root $wheelhouse -Name 'skillspector' -Version '2.12.0')
        [void](New-TestWheel -Root $wheelhouse -Name 'dependency-a' -Version '1.0.0')
        $lockPath = Join-Path $TestDrive 'dependency-lock.txt'

        $manifest = New-PythonWheelhouseLock -WheelhousePath $wheelhouse -LockPath $lockPath
        Assert-Equal @($manifest.entries).Count 2 'Dependency closure must include every wheel.'
        Assert-Match $manifest.closureSha256 '^[0-9a-f]{64}$' 'Dependency closure must have a SHA-256 identity.'
        $lock = Get-Content -Raw -Encoding UTF8 -LiteralPath $lockPath
        Assert-Match $lock 'skillspector==2\.12\.0 --hash=sha256:[0-9a-f]{64}' 'Root wheel must be hash locked.'
        Assert-Match $lock 'dependency-a==1\.0\.0 --hash=sha256:[0-9a-f]{64}' 'Dependency wheel must be hash locked.'
    }

    # Scenario: The canonical resolver acquires SkillSpector dependencies from approved PyPI wheel artifacts.
    # Purpose: Preserve same-URL timeout retry bounds, shared byte/deadline accounting, and fail-closed artifact checks.
    It 'UnitT26d_requires_offline_hash_locked_SkillSpector_installation' {
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $helper = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:PythonClosureHelperPath
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-True $helper.Contains('MAX_WHEEL_DOWNLOAD_ATTEMPTS = 2') 'Approved artifact downloads must allow at most two total attempts.'
        Assert-True $helper.Contains('def _is_retryable_artifact_timeout(error: BaseException)') 'Retryable failures must be classified explicitly.'
        Assert-True $helper.Contains('isinstance(error, urllib.error.HTTPError)') 'HTTP status errors must remain non-retryable even when wrapped as URL errors.'
        Assert-True $helper.Contains('isinstance(error.reason, TimeoutError)') 'Only an explicit URLError timeout reason may retry.'
        Assert-True $helper.Contains('total_received = 0') -and $helper.Contains('total_received += len(chunk)') 'Partial bytes across attempts must share the per-wheel byte counter.'
        Assert-True $standard.Contains('at most once (two total attempts)') -and $standard.Contains('same acquisition deadline and cumulative byte budget') 'Normative policy must cap retries and preserve the acquisition budget.'
        Assert-True $standard.Contains('HTTP status, TLS, redirect, policy, integrity, metadata, local I/O, and all other failures') 'Normative policy must enumerate non-retryable failures.'
        Assert-Match $resolver 'function Invoke-IsolatedPythonCommand' 'Python isolation must be centralized in one command wrapper.'
        Assert-Match $resolver 'return Invoke-CheckedCommand.*@\(''-I''\) \+ \$Arguments' 'Every wrapped Python subprocess must prepend isolated mode.'
        Assert-NotMatch $resolver "Invoke-CheckedCommand -Command 'python'" 'System Python must not bypass isolated mode.'
        Assert-NotMatch $resolver 'Invoke-CheckedCommand -Command \$venvPython' 'Virtual-environment Python must not bypass isolated mode.'
        Assert-Match $resolver "Invoke-IsolatedPythonCommand -PythonCommand .* -Arguments @\('-S', '-m', 'venv'" 'SkillSpector must create its virtual environment with isolated Python startup and without site initialization.'
        Assert-Match $resolver '\$venvPython' 'SkillSpector dependency acquisition and install must use the virtual-environment Python.'
        Assert-Match $resolver "Invoke-IsolatedPythonCommand -PythonCommand .* -Arguments @\(\s*'-B', '-m', 'pip'" 'The final pip install must ignore inherited Python configuration and disable bytecode writes.'
        Assert-Match $helper '(?s)sys\.executable,\s*"-I",\s*"-B",\s*"-m",\s*"pip"' 'Helper pip backtracking must ignore inherited Python configuration and disable bytecode writes.'
        Assert-NotMatch $resolver '--break-system-packages' 'Canonical install must not bypass PEP 668 protections.'
        Assert-Match $resolver 'Resolve-PythonWheelClosureFromApprovedIndex' 'SkillSpector must delegate candidate acquisition to the verified helper.'
        Assert-Match $helper 'application/vnd\.pypi\.simple\.v1\+json' 'Candidate acquisition must use the PyPI Simple JSON contract.'
        Assert-Match $helper 'ValidatedRedirectHandler' 'Candidate acquisition must reject redirects before following them.'
        Assert-Match $helper 'parse_wheel_filename' 'Candidate acquisition must validate wheel identity and compatibility.'
        Assert-Match $helper 'Python direct dependency reference is not allowed' 'Candidate metadata must reject direct references before pip sees it.'
        Assert-Match $helper 'Candidate hash mismatch' 'Candidate bytes must match approved Simple JSON hashes.'
        Assert-Match $helper 'Candidate Requires-Python mismatch' 'Simple JSON and wheel METADATA Requires-Python must agree before pip sees a candidate.'
        Assert-Match $helper 'METADATA Requires-Python is incompatible' 'Root and dependency wheels must allow the current interpreter.'
        Assert-Match $helper 'rejectedCandidates' 'Malformed Simple JSON candidates must have deterministic rejection evidence.'
        Assert-Match $standard 'deterministic rejection evidence' 'Normative authority must preserve malformed-candidate rejection evidence.'
        Assert-Match $helper 'def verify_evidence' 'Candidate inventory, pip report, and selected closure identities must be recomputed across files.'
        Assert-Match $helper '"--no-index"' 'pip backtracking must use only the verified local pool.'
        Assert-Match $helper '"--only-binary=:all:"' 'Dependency resolution must reject source distributions.'
        Assert-Match $resolver '--no-cache-dir' 'Dependency acquisition must not reuse pip cache.'
        Assert-Match $resolver 'New-PythonWheelhouseLock' 'Dependency closure must be hash inventoried.'
        Assert-Match $resolver '--no-index' 'Final SkillSpector installation must not use an index.'
        Assert-Match $resolver '--require-hashes' 'Final SkillSpector installation must enforce hashes.'
        Assert-Match $resolver '--no-deps' 'Final installation must not resolve new dependencies outside the locked closure.'
        Assert-Match $resolver '--no-compile' 'Final installation must not create derived dependency bytecode.'
        Assert-Match $resolver 'interpreterIsolation=\$interpreterIsolation' 'Resolved SkillSpector identity must record Python interpreter isolation.'
        Assert-Match $resolver '\$result\.interpreterIsolation = ' 'The machine-readable receipt must expose Python interpreter isolation.'
        Assert-Match $resolver 'directReferences=blocked' 'Resolved SkillSpector identity must record direct-reference blocking.'
        Assert-Match $resolver '\$result\.directReferencesAllowed = ' 'The machine-readable receipt must expose direct-reference policy.'
        Assert-Match $resolver 'pipOnlineDependencyTraversal=disabled' 'Resolved SkillSpector identity must record that pip cannot traverse dependencies online.'
        Assert-Match $resolver 'dependencyDiscovery=approved-simple-json-lazy' 'Resolved SkillSpector identity must record mediated candidate discovery.'
        Assert-Match $resolver 'requiresPython=simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' 'Resolved SkillSpector identity must record Requires-Python cross-verification.'
        Assert-Match $resolver 'offlineBacktracking=verified' 'Resolved SkillSpector identity must record offline backtracking.'
        Assert-Match $resolver '\$result\.pipOnlineDependencyTraversalAllowed = ' 'The machine-readable receipt must expose pip online traversal policy.'
        Assert-Match $resolver '\$result\.resolverHelperSha256 = ' 'The machine-readable receipt must bind the exact Python helper.'
        Assert-Match $resolver '\$result\.requiresPythonPolicy = ' 'The machine-readable receipt must expose Requires-Python verification policy.'
        Assert-Match $resolver '\$result\.offlineResolutionVerified = ' 'The machine-readable receipt must expose offline dependency-resolution verification.'
        Assert-NotMatch $resolver 'Invoke-CheckedCommand -Command \$installedExecutablePath' 'Resolver verification must not bypass isolated Python by executing the console script directly.'
        Assert-Match $helper '"--dry-run"' 'The completed candidate pool must be resolved by pip without installation.'
        Assert-Match $standard '`SkillSpector`.*resolver \*\*MUST\*\*' 'Normative authority must define SkillSpector resolver controls.'
        Assert-Match $standard 'Python `-I` isolated mode' 'Normative authority must require inherited Python interpreter isolation.'
        Assert-Match $standard '--no-index --require-hashes --no-deps' 'Normative authority must require offline hash-locked installation.'
    }

    It 'UnitT26da_ignores_inherited_PYTHONPATH_for_every_Python_subprocess' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        [void](Assert-Command -Name 'python')
        $probeRoot = Join-Path $TestDrive 'untrusted-python-path'
        [void](New-Item -ItemType Directory -Path $probeRoot -Force)
        $siteCustomizePath = Join-Path $probeRoot 'sitecustomize.py'
        [IO.File]::WriteAllText($siteCustomizePath, "raise SystemExit('untrusted PYTHONPATH executed')`n", (New-Object Text.UTF8Encoding($false)))

        $previousPythonPath = [Environment]::GetEnvironmentVariable('PYTHONPATH', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('PYTHONPATH', $probeRoot, [EnvironmentVariableTarget]::Process)
            $output = Invoke-IsolatedPythonCommand -PythonCommand 'python' -Arguments @('-c', "print('isolated-python-ran')")
            Assert-Equal (($output -join '').Trim()) 'isolated-python-ran' 'Isolated Python must ignore caller-controlled PYTHONPATH imports.'
        }
        finally {
            [Environment]::SetEnvironmentVariable('PYTHONPATH', $previousPythonPath, [EnvironmentVariableTarget]::Process)
        }
    }

    It 'UnitT26db_rejects_direct_Python_dependency_references_before_network_resolution' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $wheelhouse = Join-Path $TestDrive 'direct-reference-wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse -Force)
        $safeWheel = New-TestWheel -Root $wheelhouse -Name 'safe-package' -Version '1.0.0' -RequiresDist @('dependency-a>=1.0')
        $unsafeWheel = New-TestWheel -Root $wheelhouse -Name 'unsafe-package' -Version '1.0.0' -RequiresDist @("dependency-b @`n https://packages.example.invalid/dependency-b.whl")

        $safeMetadata = Get-PythonWheelMetadata -WheelPath $safeWheel
        Assert-NoPythonDirectReferences -Metadata $safeMetadata -WheelFileName ([IO.Path]::GetFileName($safeWheel))
        $selfTestOutput = Invoke-IsolatedPythonCommand `
            -PythonCommand (Assert-Command -Name 'python') `
            -Arguments @($script:PythonClosureHelperPath, 'self-test')
        Assert-Match ($selfTestOutput -join "`n") 'python-wheel-closure-self-test: passed' 'Offline A/B/C backtracking and helper security regressions must pass.'

        $errorMessage = $null
        try {
            $unsafeMetadata = Get-PythonWheelMetadata -WheelPath $unsafeWheel
            Assert-NoPythonDirectReferences -Metadata $unsafeMetadata -WheelFileName ([IO.Path]::GetFileName($unsafeWheel))
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'Python direct dependency reference is not allowed' 'Direct URL dependency metadata must fail closed.'

        $lockPath = Join-Path $TestDrive 'unsafe-dependency-lock.txt'
        $errorMessage = $null
        try { New-PythonWheelhouseLock -WheelhousePath $wheelhouse -LockPath $lockPath | Out-Null }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'Python direct dependency reference is not allowed' 'Every wheel in the completed dependency closure must be checked.'

        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        $resolveStart = $resolver.IndexOf('function Resolve-SkillSpector')
        $resolveBody = $resolver.Substring($resolveStart)
        $directReferenceCheck = $resolveBody.IndexOf('Assert-NoPythonDirectReferences')
        $githubCredentialRemoval = $resolveBody.IndexOf("Remove-Item -LiteralPath 'Env:GITHUB_TOKEN'")
        $dependencyAcquisition = $resolveBody.IndexOf('Resolve-PythonWheelClosureFromApprovedIndex')
        Assert-True ($directReferenceCheck -ge 0 -and $directReferenceCheck -lt $dependencyAcquisition) 'Root direct references must be rejected before approved-index dependency acquisition.'
        Assert-True ($githubCredentialRemoval -ge 0 -and $githubCredentialRemoval -lt $dependencyAcquisition) 'GitHub release credentials must be removed before approved-index dependency acquisition.'
    }

    It 'UnitT26e_rejects_npm_and_Node_process_overrides_before_invocation' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $cases = @(
            @{ Name = 'NPM_CONFIG_DRY_RUN'; Value = 'true'; Pattern = 'Untrusted npm environment override' },
            @{ Name = 'npm_config_dry_run'; Value = ' '; Pattern = 'Untrusted npm environment override' },
            @{ Name = 'NPM_CONFIG_USERCONFIG'; Value = 'untrusted.npmrc'; Pattern = 'Untrusted npm environment override' },
            @{ Name = 'NODE_OPTIONS'; Value = '--require=/tmp/untrusted-hook.js'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'NODE_PATH'; Value = '/tmp/untrusted-modules'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'NODE_TLS_REJECT_UNAUTHORIZED'; Value = '0'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'NODE_EXTRA_CA_CERTS'; Value = '/tmp/untrusted-ca.pem'; Pattern = 'Untrusted Node environment override' },
            @{ Name = 'SSL_CERT_FILE'; Value = '/tmp/untrusted-openssl-ca.pem'; Pattern = 'Untrusted Node environment override' }
        )
        $ambientNames = @(Get-OrdinalUniqueStrings -Values @(
            @(Get-ProcessNpmEnvironmentNames) + @(Get-ProcessNodeEnvironmentNames) + @($cases.Name)
        ))
        $previous = @($ambientNames | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_
                value = [Environment]::GetEnvironmentVariable([string]$_, [EnvironmentVariableTarget]::Process)
            }
        })
        try {
            foreach ($case in $cases) {
                $caseName = [string]$case.Name
                $caseValue = [string]$case.Value
                $casePattern = [string]$case.Pattern
                foreach ($name in $ambientNames) {
                    [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
                }
                try {
                    [Environment]::SetEnvironmentVariable($caseName, $caseValue, [EnvironmentVariableTarget]::Process)
                    Assert-Equal `
                        ([Environment]::GetEnvironmentVariable($caseName, [EnvironmentVariableTarget]::Process)) `
                        $caseValue `
                        "Test process environment did not retain '$caseName'."
                    $errorMessage = $null
                    try {
                        Assert-NoConflictingNpmEnvironment -ExpectedRegistry 'https://registry.npmjs.org/'
                    }
                    catch {
                        $errorMessage = $_.Exception.Message
                    }
                    Assert-Match $errorMessage ("{0}.*{1}" -f $casePattern, $caseName) ("{0} must fail before npm invocation." -f $caseName)
                }
                finally {
                    [Environment]::SetEnvironmentVariable($caseName, $null, [EnvironmentVariableTarget]::Process)
                }
            }
        }
        finally {
            foreach ($name in @(Get-OrdinalUniqueStrings -Values @(@(Get-ProcessNpmEnvironmentNames) + @(Get-ProcessNodeEnvironmentNames) + $ambientNames))) {
                [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($entry in $previous) {
                [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT26ea_rejects_scoped_registry_configuration_even_with_an_approved_default' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $configuration = [pscustomobject][ordered]@{
            registry = 'https://registry.npmjs.org/'
            audit = $false
        }
        $configuration | Add-Member -NotePropertyName '@skill-tools:registry' -NotePropertyValue 'https://registry.example.invalid/'
        $errorMessage = $null
        try {
            Assert-ApprovedNpmConfigurationObject -Configuration $configuration -ExpectedRegistry 'https://registry.npmjs.org/'
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'Untrusted scoped npm registry.*@skill-tools:registry' 'A scoped registry must not bypass the approved default registry.'
    }

    It 'UnitT26f_validates_npm_lock_version_endpoint_integrity_and_root_bin_identity' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $integrity = 'sha512-' + ('A' * 86) + '=='
        $lock = [ordered]@{
            name = 'standard-validation-skill-tools'
            version = '1.0.0'
            lockfileVersion = 3
            requires = $true
            packages = [ordered]@{
                '' = [ordered]@{
                    name = 'standard-validation-skill-tools'
                    version = '1.0.0'
                    dependencies = [ordered]@{ 'skill-tools' = '0.4.1' }
                }
                'node_modules/skill-tools' = [ordered]@{
                    version = '0.4.1'
                    resolved = 'https://registry.npmjs.org/skill-tools/-/skill-tools-0.4.1.tgz'
                    integrity = $integrity
                    bin = [ordered]@{ 'skill-tools' = './dist/cli.js' }
                }
                'node_modules/@skill-tools/dependency' = [ordered]@{
                    version = '1.2.3'
                    resolved = 'https://registry.npmjs.org/@skill-tools/dependency/-/dependency-1.2.3.tgz'
                    integrity = $integrity
                }
            }
        }
        $lockPath = Join-Path $TestDrive 'package-lock.json'
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))

        $identity = Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1'
        Assert-Match $identity.packageLockSha256 '^[0-9a-f]{64}$' 'The raw package-lock must be hashed.'
        Assert-Match $identity.closureSha256 '^[0-9a-f]{64}$' 'The canonical dependency closure must be hashed separately.'
        Assert-Equal @($identity.entries).Count 2 'Every locked npm package must be represented in closure evidence.'
        Assert-Equal $identity.rootBinTarget 'dist/cli.js' 'The lock must bind the canonical skill-tools bin target.'
        $typedJson = ConvertFrom-NpmJsonStrict -Text '{"integer":3,"number":3.0,"string":"3","boolean":true,"object":{},"array":[]}'
        foreach ($typeCase in @(
            @{ Name='integer'; Expected='Integer' }, @{ Name='number'; Expected='Number' },
            @{ Name='string'; Expected='String' }, @{ Name='boolean'; Expected='Boolean' },
            @{ Name='object'; Expected='Object' }, @{ Name='array'; Expected='Array' }
        )) {
            Assert-Equal `
                (Get-NpmJsonTokenType -Token (Get-NpmJsonObjectProperty -Token $typedJson -Name $typeCase.Name)) `
                $typeCase.Expected `
                "Strict npm JSON parsing must preserve the '$($typeCase.Name)' token type."
        }
        foreach ($jsonCase in @(
            @{ Json='{"key":1,"key":2}'; Pattern='duplicate object key' },
            @{ Json='{"key":1,"\u006bey":2}'; Pattern='duplicate object key' },
            @{ Json='{"key":"\uD800"}'; Pattern='unpaired high surrogate' },
            @{ Json=('"' + [char]0xD800 + '"'); Pattern='unpaired raw high surrogate' },
            @{ Json=('"' + [char]0xDC00 + '"'); Pattern='unpaired raw low surrogate' },
            @{ Json='{"key":01}'; Pattern='leading zero' },
            @{ Json='{"key":1} trailing'; Pattern='trailing content' }
        )) {
            $jsonError = $null
            try { ConvertFrom-NpmJsonStrict -Text $jsonCase.Json | Out-Null }
            catch { $jsonError = $_.Exception.Message }
            Assert-Match $jsonError $jsonCase.Pattern 'Strict npm JSON parsing must reject ambiguous or malformed input.'
        }
        $rawPair = [char]::ConvertFromUtf32(0x1F600)
        Assert-Equal `
            (Get-NpmJsonTokenType -Token (ConvertFrom-NpmJsonStrict -Text ('"' + $rawPair + '"'))) `
            'String' `
            'Strict npm JSON parsing must accept a paired raw Unicode scalar.'
        $duplicatePairError = $null
        try { ConvertFrom-NpmJsonStrict -Text ('{"' + $rawPair + '":1,"\uD83D\uDE00":2}') | Out-Null }
        catch { $duplicatePairError = $_.Exception.Message }
        Assert-Match $duplicatePairError 'duplicate object key' 'Equivalent raw and escaped Unicode keys must collide ordinally after decoding.'

        $tokenLimitError = $null
        try { ConvertFrom-NpmJsonStrict -Text '[0,0,0]' -MaxTokens 3 | Out-Null }
        catch { $tokenLimitError = $_.Exception.Message }
        Assert-Match $tokenLimitError 'maximum semantic token count of 3' 'Strict npm JSON parsing must bound array node amplification independently of byte size.'
        $memberLimitError = $null
        try { ConvertFrom-NpmJsonStrict -Text '{"key":0}' -MaxTokens 2 | Out-Null }
        catch { $memberLimitError = $_.Exception.Message }
        Assert-Match $memberLimitError 'maximum semantic token count of 2' 'Strict npm JSON parsing must count object member names in its amplification budget.'
        $lock.packages[' '] = [ordered]@{
            version = '9.9.9'
            resolved = 'https://registry.example.invalid/ignored.tgz'
            integrity = $integrity
        }
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $whitespacePathError = $null
        try {
            Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1' | Out-Null
        }
        catch { $whitespacePathError = $_.Exception.Message }
        Assert-Match $whitespacePathError 'non-root whitespace package path' 'Only the exact empty root key may be excluded from npm closure validation.'
        $lock.packages.Remove(' ')
        $dependencyEntry = $lock.packages.'node_modules/@skill-tools/dependency'
        foreach ($controlField in @('version','resolved','integrity')) {
            $originalFieldValue = [string]$dependencyEntry[$controlField]
            $dependencyEntry[$controlField] = $originalFieldValue + "`tidentity-collision"
            [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
            $controlIdentityError = $null
            try {
                Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1' | Out-Null
            }
            catch { $controlIdentityError = $_.Exception.Message }
            Assert-Match $controlIdentityError 'control characters in closure identity fields' "Closure identity field '$controlField' must not embed canonical record delimiters."
            $dependencyEntry[$controlField] = $originalFieldValue
        }
        $controlPath = "node_modules/control`tpath"
        $lock.packages[$controlPath] = [ordered]@{
            version = '9.9.9'
            resolved = 'https://registry.npmjs.org/control/-/control-9.9.9.tgz'
            integrity = $integrity
        }
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $controlPathError = $null
        try {
            Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1' | Out-Null
        }
        catch { $controlPathError = $_.Exception.Message }
        Assert-Match $controlPathError 'package path with control characters' 'Closure package paths must not embed canonical field delimiters.'
        $lock.packages.Remove($controlPath)
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        foreach ($acceptedBin in @(
            @{ Value='dist/cli.js'; Expected='dist/cli.js' },
            @{ Value='./dist/cli.js'; Expected='dist/cli.js' },
            @{ Value='.\dist\.\cli.js'; Expected='dist/cli.js' },
            @{ Value='dist/./cli.js'; Expected='dist/cli.js' },
            @{ Value='.hidden/cli.js'; Expected='.hidden/cli.js' },
            @{ Value='dist/.../cli.js'; Expected='dist/.../cli.js' },
            @{ Value='dist/..hidden/cli.js'; Expected='dist/..hidden/cli.js' }
        )) {
            Assert-Equal `
                (Get-CanonicalNpmBinTarget -Value $acceptedBin.Value -Context 'test bin') `
                $acceptedBin.Expected `
                "Safe npm bin target '$($acceptedBin.Value)' must canonicalize deterministically."
        }
        Assert-Equal `
            (Get-CanonicalNpmBinTarget -Value './dist/cli.js' -Context 'installed test bin') `
            (Get-CanonicalNpmBinTarget -Value 'dist/cli.js' -Context 'lock test bin') `
            'Installed and lockfile spellings of the same npm bin target must compare identically.'
        Assert-False `
            ((Get-CanonicalNpmBinTarget -Value 'dist/other.js' -Context 'test bin') -ceq $identity.rootBinTarget) `
            'Canonicalization must not make different npm bin targets compare equal.'
        foreach ($unsafeBin in @(
            $null, 7, '', '   ', '/dist/cli.js', '\\server\share\cli.js', 'C:\dist\cli.js', 'C:dist\cli.js',
            'https://example.invalid/cli.js', '../dist/cli.js', 'dist/../cli.js', 'dist//cli.js', 'dist\\cli.js',
            'dist/', '.', './.', 'dist:cli.js', ("dist/{0}cli.js" -f [char]0x0000),
            ("dist/{0}cli.js" -f [char]0x007f), ("dist/{0}cli.js" -f [char]0x0085),
            ("dist/{0}cli.js" -f [char]0x009f)
        )) {
            $binError = $null
            try { Get-CanonicalNpmBinTarget -Value $unsafeBin -Context 'test bin' | Out-Null }
            catch { $binError = $_.Exception.Message }
            Assert-Match $binError 'safe relative package path' "Unsafe npm bin target '$unsafeBin' must fail closed."
        }
        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        Assert-Match $resolver '\$installedBinTarget = Get-CanonicalNpmBinTarget' 'Installed and lockfile bin targets must share the same canonicalization rule.'
        Assert-Match $resolver 'packageLockSha256 = Get-BytesSha256 -Bytes \$lockBytes' 'npm lock evidence must hash the exact bytes parsed for closure identity.'
        Assert-NotMatch $resolver 'packageLockSha256 = Get-FileSha256' 'npm lock evidence must not re-read a mutable path after validation.'

        $lock.packages.'node_modules/skill-tools'.bin['skill-tools'] = '../dist/cli.js'
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $unsafeLockError = $null
        try {
            Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1' | Out-Null
        }
        catch {
            $unsafeLockError = $_.Exception.Message
        }
        Assert-Match $unsafeLockError 'unsafe or missing skill-tools bin target' 'Unsafe npm bin targets must also fail closed through lockfile verification.'
        $lock.packages.'node_modules/skill-tools'.bin['skill-tools'] = './dist/cli.js'

        $lock.packages.'node_modules/@skill-tools/dependency'.resolved = 'https://registry.example.invalid/dependency.tgz'
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $errorMessage = $null
        try {
            Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry 'https://registry.npmjs.org/' -ExpectedRootIntegrity $integrity -ExpectedVersion '0.4.1' | Out-Null
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        Assert-Match $errorMessage 'untrusted endpoint' 'A dependency resolved outside the approved registry must fail closed.'
    }

    It 'UnitT26g_keeps_run_owned_install_directories_under_the_requested_root' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $requestedRoot = Join-Path $TestDrive 'validation-tools'
        $first = New-RunOwnedInstallDirectory -Root $requestedRoot -ToolName 'skillspector'
        $second = New-RunOwnedInstallDirectory -Root $requestedRoot -ToolName 'skillspector'
        $rootPrefix = [IO.Path]::GetFullPath($requestedRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        Assert-True ($first.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) 'A run-owned install must remain under InstallRoot.'
        Assert-True (Test-Path -LiteralPath $first -PathType Container) 'The first install directory must remain available after allocation returns.'
        Assert-True (Test-Path -LiteralPath $second -PathType Container) 'The second install directory must remain available after allocation returns.'
        Assert-False ([string]::Equals($first, $second, [StringComparison]::OrdinalIgnoreCase)) 'Each resolver invocation must receive a unique install directory.'

        $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
        Assert-Match $resolver '\[string\] \$InstallRoot' 'The resolver must expose the persistent InstallRoot contract.'
        Assert-Match $resolver 'installRoot = \$resolved\.installRoot' 'Every tool receipt must project its run-owned install root.'
        Assert-Match $resolver 'executablePath = \$resolved\.executablePath' 'Every tool receipt must project its exact executable path.'
        Assert-Match $resolver 'executableSha256 = \$resolved\.executableSha256' 'Every tool receipt must project its exact executable hash.'
    }

    # Scenario: A wheel member fits below the Windows limit only with the short run-owned root.
    # Purpose: Fail before dependency acquisition when a real install target cannot be written.
    It 'UnitT26i_probes_the_longest_wheel_member_under_a_short_install_root' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }

        $fixture = New-Syp325FixtureRoot
        $fixtureRoot = $fixture.Root
        $requestedRoot = Join-Path $fixtureRoot 'short-wheel-root'
        $short = New-RunOwnedInstallDirectory -Root $requestedRoot -ToolName 'skillspector'
        $long = Join-Path $requestedRoot ("skillspector-{0}" -f [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $long)
        $sitePackages = Join-Path $short 'venv\Lib\site-packages'
        $longSitePackages = Join-Path $long 'venv\Lib\site-packages'
        $memberLength = 264 - $longSitePackages.Length - 1 - 'pathprobe/'.Length
        Assert-True ($memberLength -gt 40) 'The short task-owned fixture root must leave enough space for the synthetic wheel member.'
        $member = ('n' * ($memberLength - 4)) + '.txt'
        $wheelPath = Join-Path $fixtureRoot 'pathprobe-1.0-py3-none-any.whl'
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $archive = [IO.Compression.ZipFile]::Open($wheelPath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $members = [ordered]@{
                ("pathprobe/{0}" -f $member) = 'installed-path-probe'
                'pathprobe-1.0.dist-info/METADATA' = "Metadata-Version: 2.1`nName: pathprobe`nVersion: 1.0`n"
                'pathprobe-1.0.dist-info/WHEEL' = "Wheel-Version: 1.0`nGenerator: path-probe`nRoot-Is-Purelib: true`nTag: py3-none-any`n"
                'pathprobe-1.0.dist-info/RECORD' = ''
            }
            foreach ($name in $members.Keys) {
                $entry = $archive.CreateEntry($name)
                $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
                try { $writer.Write([string]$members[$name]) }
                finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }

        $longError = $null
        try { Assert-PythonWheelInstallPath -InstallPath $long -WheelPath $wheelPath }
        catch { $longError = $_.Exception.Message }
        Assert-Match $longError 'path length|headroom' 'The old long root must fail before installation.'
        Assert-PythonWheelInstallPath -InstallPath $short -WheelPath $wheelPath
        Assert-True ($short.Length -lt $long.Length) 'The run-owned SkillSpector root must be shorter than the old form.'
        $venvPath = Join-Path $short 'venv'
        $python = Assert-Command -Name 'python'
        [void](Invoke-IsolatedPythonCommand -PythonCommand $python -Arguments @('-S', '-m', 'venv', '--copies', $venvPath) -TimeoutSeconds 30)
        $venvPython = Join-Path $venvPath 'Scripts\python.exe'
        [void](Invoke-IsolatedPythonCommand -PythonCommand $venvPython -Arguments @('-m', 'pip', 'install', '--no-index', '--no-deps', '--no-cache-dir', $wheelPath) -TimeoutSeconds 30)
        $installedFile = Join-Path $sitePackages ("pathprobe/{0}" -f $member)
        Assert-Equal ([IO.File]::ReadAllText($installedFile)) 'installed-path-probe' 'The synthetic wheel member must be installed and readable under the short root.'
        $unrelated = Join-Path $requestedRoot 'unrelated.txt'
        [IO.File]::WriteAllText($unrelated, 'retain')
        Remove-Item -LiteralPath $short -Recurse -Force
        Assert-True (Test-Path -LiteralPath $unrelated -PathType Leaf) 'Cleaning the run-owned install must retain neighboring files.'
    }

    # Scenario: A Python child stalls during acquisition.
    # Purpose: Bound the child process and report a deadline error to the caller.
    It 'UnitT26j_terminates_a_stalled_python_child_at_the_acquisition_deadline' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $python = Assert-Command -Name 'python'
        $deadlineError = $null
        try {
            [void](Invoke-CheckedCommand -Command $python -Arguments @('-c', 'import time; time.sleep(4)') -TimeoutSeconds 1)
        }
        catch { $deadlineError = $_.Exception.Message }
        Assert-Match $deadlineError 'acquisition deadline' 'The stalled child must be terminated at the configured deadline.'
    }

    # Scenario: A response body sends bytes repeatedly without ever going idle.
    # Purpose: Enforce the absolute cancellation token instead of a socket inactivity timeout.
    It 'UnitT26k_cancels_a_slow_trickle_http_body_at_the_absolute_deadline' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        if (-not ('C245SlowTrickleStream' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class C245SlowTrickleStream : Stream {
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
        await Task.Delay(50, token);
        buffer[offset] = 1;
        return 1;
    }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
'@
        }
        $inputBody = New-Object C245SlowTrickleStream
        $outputBody = New-Object IO.MemoryStream
        $deadline = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds(300))
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $cancelled = $false
        try { [void](Copy-BoundedHttpBody -InputStream $inputBody -OutputStream $outputBody -CancellationToken $deadline.Token -MaximumBytes 1024) }
        catch { $cancelled = $_.Exception.ToString() -match 'cancel' }
        finally { $deadline.Dispose(); $inputBody.Dispose(); $outputBody.Dispose(); $watch.Stop() }
        Assert-True $cancelled 'A continuously trickling body must stop at the absolute deadline.'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 2) 'Slow-trickle cancellation must finish promptly.'
    }

    # Scenario: Interpreter acquisition fails before a wheel can be downloaded.
    # Purpose: Keep a diagnostic-only failure outside the cleaned install root.
    It 'UnitT26l_retains_failure_diagnostics_when_acquisition_stops_early' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $policy = Get-Policy -Path $script:ToolchainPath
        $requestedRoot = Join-Path $TestDrive 'failed-acquisition'
        Mock Assert-Command { throw 'synthetic interpreter acquisition failure' }
        $failureMessage = $null
        try {
            [void](Resolve-SkillSpector -ShouldInstall $true -ToolPolicy $policy.tools.skillspector -RequestedInstallRoot $requestedRoot -AcquisitionLimitSeconds 1)
        }
        catch { $failureMessage = $_.Exception.Message }
        Assert-Match $failureMessage 'synthetic interpreter acquisition failure' 'The original acquisition failure must propagate.'
        $failurePath = Join-Path $requestedRoot ("skillspector-failure-{0}/failure.json" -f $script:ResolverRunId)
        Assert-True (Test-Path -LiteralPath $failurePath -PathType Leaf) 'The diagnostic-only failure must survive cleanup.'
        $failure = Get-Content -Raw -LiteralPath $failurePath | ConvertFrom-Json
        Assert-Equal $failure.kind 'diagnostic-only' 'A failure artifact cannot impersonate a success receipt.'
        Assert-Equal $failure.runId $script:ResolverRunId 'The failure artifact must bind to the current run.'
    }

    # Scenario: The resolver has produced partial diagnostics and temp cleanup follows.
    # Purpose: Preserve only diagnostic files outside the cleaned untrusted wheel pool.
    It 'UnitT26m_preserves_partial_resolver_evidence_before_temp_cleanup' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $work = Join-Path $TestDrive 'partial-work'
        $saved = Join-Path $TestDrive 'saved-failure'
        [void](New-Item -ItemType Directory -Path $work)
        [IO.File]::WriteAllText((Join-Path $work 'acquisition-diagnostics.jsonl'), '{"phase":"failure"}')
        [IO.File]::WriteAllText((Join-Path $work 'candidate-inventory.failure.json'),
            '{"schemaVersion":1,"kind":"diagnostic-only","entries":[],"rejectedCandidates":[]}')
        [IO.File]::WriteAllText((Join-Path $work 'untrusted.whl'), 'do-not-retain')
        Save-SkillSpectorFailureEvidence -WorkPath $work -DestinationPath $saved
        Remove-Item -LiteralPath $work -Recurse -Force
        Assert-True (Test-Path -LiteralPath (Join-Path $saved 'acquisition-diagnostics.jsonl') -PathType Leaf) 'The append-only events must survive temporary cleanup.'
        Assert-True (Test-Path -LiteralPath (Join-Path $saved 'candidate-inventory.failure.json') -PathType Leaf) 'The partial candidate identity must survive temporary cleanup.'
        Assert-False (Test-Path -LiteralPath (Join-Path $saved 'untrusted.whl')) 'The untrusted wheel must not be copied into diagnostics.'
        Assert-False (Test-Path -LiteralPath (Join-Path $saved 'closure-result.json')) 'A failure must not acquire a success result.'
    }

    # Scenario: Resolution finishes, but a later install step fails and removes its temporary pool.
    # Purpose: Retain the completed candidate inventory as diagnostic-only failure evidence.
    It 'UnitT26r_preserves_completed_candidate_inventory_after_later_failure' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $work = Join-Path $TestDrive 'completed-work'
        $saved = Join-Path $TestDrive 'completed-failure'
        [void](New-Item -ItemType Directory -Path $work)
        $inventory = [ordered]@{
            schemaVersion = 1
            inventorySha256 = ('a' * 64)
            entries = @([ordered]@{ file = 'dependency-1.0-py3-none-any.whl'; sha256 = ('b' * 64) })
            rejectedCandidates = @()
        }
        [IO.File]::WriteAllText((Join-Path $work 'candidate-inventory.json'),
            ($inventory | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $work 'candidate-inventory.failure.json'),
            '{"schemaVersion":1,"kind":"diagnostic-only","entries":[],"rejectedCandidates":[]}',
            (New-Object Text.UTF8Encoding($false)))
        Save-SkillSpectorFailureEvidence -WorkPath $work -DestinationPath $saved
        $failurePath = Join-Path $saved 'candidate-inventory.failure.json'
        Assert-True (Test-Path -LiteralPath $failurePath -PathType Leaf) 'A completed inventory must survive later install failure.'
        $failure = Get-Content -Raw -LiteralPath $failurePath | ConvertFrom-Json
        Assert-Equal $failure.kind 'diagnostic-only' 'The preserved inventory must not impersonate a success receipt.'
        Assert-Equal $failure.source 'completed-candidate-inventory' 'The diagnostic must disclose its source.'
        Assert-Equal $failure.entries[0].file 'dependency-1.0-py3-none-any.whl' 'The selected candidate identity must survive.'
        Assert-Equal @($failure.rejectedCandidates).Count 0 'An empty rejected-candidate list must remain empty.'
        Assert-False (Test-Path -LiteralPath (Join-Path $saved 'closure-result.json')) 'A failure must not retain the success result.'
    }

    # Scenario: The helper is stopped while writing its completed inventory.
    # Purpose: Retain both the damaged bytes and the last complete diagnostic snapshot.
    It 'UnitT26u_falls_back_to_incremental_inventory_when_completed_json_is_damaged' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $work = Join-Path $TestDrive 'damaged-work'
        $saved = Join-Path $TestDrive 'damaged-failure'
        [void](New-Item -ItemType Directory -Path $work)
        [IO.File]::WriteAllText((Join-Path $work 'candidate-inventory.json'), '{"schemaVersion":1,')
        [IO.File]::WriteAllText((Join-Path $work 'candidate-inventory.failure.json'),
            '{"schemaVersion":1,"kind":"diagnostic-only","entries":[{"file":"last-verified.whl"}],"rejectedCandidates":[]}',
            (New-Object Text.UTF8Encoding($false)))
        Save-SkillSpectorFailureEvidence -WorkPath $work -DestinationPath $saved
        Assert-True (Test-Path -LiteralPath (Join-Path $saved 'candidate-inventory.unverified.json')) 'Damaged completed bytes must remain available for diagnosis.'
        $snapshot = Get-Content -Raw -LiteralPath (Join-Path $saved 'candidate-inventory.failure.json') | ConvertFrom-Json
        Assert-Equal $snapshot.kind 'diagnostic-only' 'Only the validated snapshot may be classified as diagnostic evidence.'
        Assert-Equal $snapshot.entries[0].file 'last-verified.whl' 'The last complete candidate must survive a damaged completed inventory.'
        Assert-False (Test-Path -LiteralPath (Join-Path $saved 'closure-result.json')) 'No success result may be preserved on failure.'
    }

    # Scenario: Post-install verification blocks after pip completed near the acquisition deadline.
    # Purpose: Bound the verification worker rather than treating late hashing as success.
    It 'UnitT26s_bounds_the_post_install_verification_worker' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $failure = $null
        try {
            [void](Invoke-BoundedPowerShellWorker -ScriptText 'Start-Sleep -Seconds 4; Write-Output late-success' `
                -AcquisitionStopwatch $watch -AcquisitionLimitSeconds 1)
        }
        catch { $failure = $_.Exception.Message }
        $watch.Stop()
        Assert-Match $failure 'acquisition deadline' 'A post-install worker cannot return success after its deadline.'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 3) 'Post-install verification must stop before the four-second fixture finishes.'
    }

    # Scenario: A temporary acquisition directory is removed after the main deadline.
    # Purpose: Keep cleanup limited to its run-owned root and preserve a neighboring directory.
    It 'UnitT26t_cleans_only_the_run_owned_temporary_directory' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $allowedRoot = Join-Path $TestDrive 'cleanup-root'
        [void](New-Item -ItemType Directory -Path $allowedRoot)
        $owned = Join-Path $allowedRoot ('ss-' + [guid]::NewGuid().ToString('N'))
        $neighbor = Join-Path $allowedRoot 'neighbor'
        [void](New-Item -ItemType Directory -Path $owned)
        [void](New-Item -ItemType Directory -Path $neighbor)
        [IO.File]::WriteAllText((Join-Path $owned 'payload.txt'), 'owned')
        [IO.File]::WriteAllText((Join-Path $neighbor 'retain.txt'), 'unrelated')
        Remove-BoundedRunOwnedDirectory -Path $owned -AllowedRoot $allowedRoot `
            -LeafPattern '^ss-[0-9a-f]{32}$' -CleanupTimeoutSeconds 5
        Assert-False (Test-Path -LiteralPath $owned) 'The owned temporary directory must be removed.'
        Assert-True (Test-Path -LiteralPath (Join-Path $neighbor 'retain.txt')) 'Neighboring files must remain.'
    }

    # Scenario: Acquisition succeeds, then temporary cleanup exhausts the budget.
    # Purpose: Preserve completed diagnostics and reclaim the install through the same failure path.
    It 'UnitT26v_retains_evidence_and_reclaims_install_after_a_tail_deadline' {
        Set-StrictMode -Version Latest
        . $script:ResolverPath -PolicyPath $script:ToolchainPath -ValidatePolicyOnly | Out-Null
        $script:tailCleanup = (Get-Item Function:Remove-BoundedRunOwnedDirectory).ScriptBlock
        $script:tailExpired = $false
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $fixture = New-Syp325FixtureRoot
        $fixtureRoot = $fixture.Root
        $tailWheel = Join-Path $fixtureRoot 'tail-fixture.whl'
        $tailArchive = [IO.Compression.ZipFile]::Open($tailWheel, [IO.Compression.ZipArchiveMode]::Create)
        try { [void]$tailArchive.CreateEntry('skillspector/__init__.py') }
        finally { $tailArchive.Dispose() }
        $script:tailBytes = [IO.File]::ReadAllBytes($tailWheel)
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $script:tailHash = ([BitConverter]::ToString($hasher.ComputeHash($script:tailBytes))).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        $script:tailRoot = Join-Path $fixtureRoot 'tail-install'
        $sibling = Join-Path $script:tailRoot 'adjacent-root'
        [void](New-Item -ItemType Directory -Path $sibling -Force)
        Mock Assert-Command { 'python' }
        Mock Assert-NoConflictingPipEnvironment { }
        Mock Assert-NoConflictingPythonEnvironment { }
        Mock Get-GitHubHeaders { @{} }
        Mock Add-ProcessPathValue { }
        Mock Get-PythonWheelMetadata { [pscustomobject]@{ name='skillspector'; version='1.0.0'; requiresDist=@() } }
        Mock Invoke-BoundedGitHubGet {
            if ($OutFile) {
                [IO.File]::WriteAllBytes($OutFile, $script:tailBytes)
                $script:tailWork = Join-Path (Split-Path -Parent $OutFile) 'dependency-resolution'
            }
            elseif ($Uri -like '*/releases/latest') {
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v1.0.0'; assets=@([pscustomobject]@{
                    name='skillspector-1.0.0-py3-none-any.whl'; digest=('sha256:'+$script:tailHash)
                    browser_download_url='https://github.com/NVIDIA/SkillSpector/releases/download/v1.0.0/skillspector-1.0.0-py3-none-any.whl'
                }) }
            }
            else { [pscustomobject]@{ object=[pscustomobject]@{ sha=('a'*40); type='commit' } } }
        }
        Mock Invoke-WithApprovedPipEnvironment {
            [void](New-Item -ItemType Directory -Path $script:tailWork -Force)
            [IO.File]::WriteAllText((Join-Path $script:tailWork 'offline-backtracking-plan.json'), '{"fixture":"completed-plan"}')
            [IO.File]::WriteAllText((Join-Path $script:tailWork 'candidate-inventory.json'), ('{"schemaVersion":1,"inventorySha256":"' + ('e' * 64) + '","entries":[{"file":"verified-candidate.whl"}],"rejectedCandidates":[]}'))
            $script:tailInstall = (Get-ChildItem -LiteralPath $script:tailRoot -Directory | Where-Object Name -match '^ss-[0-9a-f]{12}$').FullName
            @{ manifest=@{ closureSha256=('b'*64) }; executablePath=(Join-Path $script:tailInstall 'fixture'); executableSha256=('c'*64); installedClosureSha256=('d'*64); consoleEntryPoint='fixture:main'; installedMetadataVerification='fixture'; resolutionEvidence=@{} }
        }
        Mock Remove-BoundedRunOwnedDirectory {
            & $script:tailCleanup -Path $Path -AllowedRoot $AllowedRoot -LeafPattern $LeafPattern
            if ((Split-Path -Leaf $Path) -match '^ss-[0-9a-f]{32}$') { $script:tailExpired = $true }
        }
        Mock Get-RemainingAcquisitionSeconds {
            if ($script:tailExpired) { throw 'synthetic tail acquisition deadline exceeded' }
            2
        }
        $tokenBefore = $env:GITHUB_TOKEN
        $ghBefore = $env:GH_TOKEN
        $failure = $null
        $receipt = $null
        try {
            $policy = Get-Policy -Path $script:ToolchainPath
            try { $receipt = Resolve-SkillSpector -ShouldInstall $true -ToolPolicy $policy.tools.skillspector -RequestedInstallRoot $script:tailRoot -AcquisitionLimitSeconds 2 }
            catch { $failure = $_.Exception.Message }
        }
        finally { $env:GITHUB_TOKEN = $tokenBefore; $env:GH_TOKEN = $ghBefore }
        Assert-Match $failure 'synthetic tail acquisition deadline exceeded' 'The late budget failure must propagate.'
        $saved = Join-Path $script:tailRoot ('skillspector-failure-'+$script:ResolverRunId)
        Assert-True (Test-Path -LiteralPath (Join-Path $saved 'offline-backtracking-plan.json')) 'The completed plan must survive tail cleanup.'
        Assert-True (Test-Path -LiteralPath (Join-Path $saved 'candidate-inventory.failure.json')) 'The completed candidate identities must survive tail cleanup.'
        Assert-True (Test-Path -LiteralPath (Join-Path $saved 'failure.json')) 'The late failure must retain its diagnostic summary.'
        Assert-False (Test-Path -LiteralPath $script:tailInstall) 'The failed install must be reclaimed.'
        Assert-True (Test-Path -LiteralPath $sibling) 'Adjacent roots must survive.'
        Assert-True ($null -eq $receipt) 'A late failure must not return a success receipt.'
    }

    # Scenario: The direct Python child exits but its owned descendant keeps redirected streams open.
    # Purpose: Bound stream draining to the same acquisition deadline as process exit.
    It 'UnitT26n_bounds_inherited_streams_after_the_direct_child_exits' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $python = Assert-Command -Name 'python'
        $pidFile = (Join-Path $TestDrive 'owned-descendant.pid').Replace('\', '/')
        $fixtureCode = "import subprocess,sys; p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(4); print(123)']); open(r'$pidFile','w').write(str(p.pid)); print(456)"
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $deadlineError = $null
        try { [void](Invoke-CheckedCommand -Command $python -Arguments @('-I', '-c', $fixtureCode) -TimeoutSeconds 1) }
        catch { $deadlineError = $_.Exception.Message }
        $watch.Stop()
        Assert-Match $deadlineError 'acquisition deadline' 'Inherited stdout/stderr must not turn a timed-out acquisition into success.'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 3) 'Inherited stream cleanup must finish within a bounded grace.'
        Assert-True (Test-Path -LiteralPath $pidFile -PathType Leaf) 'The fixture must expose its owned descendant PID.'
        $descendantId = [int](Get-Content -Raw -LiteralPath $pidFile)
        Assert-False ($null -ne (Get-Process -Id $descendantId -ErrorAction SilentlyContinue)) 'The owned descendant must be stopped without touching unrelated processes.'
    }

    # Scenario: Resolve emits plan files quickly, then the independent verifier stalls.
    # Purpose: Carry the remaining acquisition deadline into the verifier process too.
    It 'UnitT26o_bounds_the_closure_evidence_verifier_with_remaining_time' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        $python = Assert-Command -Name 'python'
        $helper = Join-Path $TestDrive 'stalling-verifier.py'
        [IO.File]::WriteAllText($helper, @'
import pathlib
import sys
import time
args = sys.argv[1:]
if args[0] == "resolve":
    for flag in ("--plan", "--inventory", "--result"):
        pathlib.Path(args[args.index(flag) + 1]).write_text("{}", encoding="utf-8")
elif args[0] == "verify":
    time.sleep(4)
    print("{}")
'@, (New-Object Text.UTF8Encoding($false)))
        $rootWheel = Join-Path $TestDrive 'root-1.0-py3-none-any.whl'
        [IO.File]::WriteAllText($rootWheel, 'synthetic')
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $deadlineError = $null
        try {
            [void](Resolve-PythonWheelClosureFromApprovedIndex `
                -PythonCommand $python -HelperPath $helper -ExpectedHelperSha256 (Get-FileSha256 -Path $helper) -ApprovedIndex 'https://pypi.org/simple' `
                -RootWheelPath $rootWheel -RootWheelSha256 ('0' * 64) `
                -CandidatePath (Join-Path $TestDrive 'candidate') -WheelhousePath (Join-Path $TestDrive 'selected') `
                -WorkPath (Join-Path $TestDrive 'work') -AcquisitionStopwatch $watch -AcquisitionLimitSeconds 1)
        }
        catch { $deadlineError = $_.Exception.Message }
        $watch.Stop()
        Assert-Match $deadlineError 'acquisition deadline' 'The separate verifier must use the remaining acquisition time.'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 3) 'A stalled verifier must end before its four-second fixture finishes.'
    }

    # Scenario: A response body ignores the cancellation token while its read task stays pending.
    # Purpose: End the acquisition wait at the absolute deadline even when a stream fails to cooperate.
    It 'UnitT26p_bounds_a_noncooperative_http_body_read' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        if (-not ('C245NonCooperativeStream' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class C245NonCooperativeStream : Stream {
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
        return new TaskCompletionSource<int>().Task;
    }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
'@
        }
        $inputBody = New-Object C245NonCooperativeStream
        $outputBody = New-Object IO.MemoryStream
        $deadline = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds(300))
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $cancelled = $false
        try { [void](Copy-BoundedHttpBody -InputStream $inputBody -OutputStream $outputBody -CancellationToken $deadline.Token -MaximumBytes 1024) }
        catch { $cancelled = $_.Exception.ToString() -match 'cancel' }
        finally { $deadline.Dispose(); $inputBody.Dispose(); $outputBody.Dispose(); $watch.Stop() }
        Assert-True $cancelled 'A noncooperative body read must stop at cancellation.'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 2) 'The deadline wait must not linger on a pending task.'
    }

    # Scenario: The root wheel fits but a selected dependency has a longer install member.
    # Purpose: Check every locked wheel before pip writes any dependency into the venv.
    It 'UnitT26q_checks_selected_dependency_wheel_members_before_install' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
        $fixture = New-Syp325FixtureRoot
        $fixtureRoot = $fixture.Root
        $installPath = New-RunOwnedInstallDirectory -Root (Join-Path $fixtureRoot 'wheelhouse-root') -ToolName 'skillspector'
        $sitePackages = Join-Path $installPath 'venv\Lib\site-packages'
        $memberLength = 249 - $sitePackages.Length - 'deep/'.Length - 1
        Assert-True ($memberLength -gt 30) 'The fixture needs room for an overlong dependency member.'
        $wheelhouse = Join-Path $fixtureRoot 'dependency-member-wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse)
        $rootWheel = Join-Path $wheelhouse 'skillspector-1.0-py3-none-any.whl'
        $dependencyWheel = Join-Path $wheelhouse 'dependency-1.0-py3-none-any.whl'
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        foreach ($spec in @(
            [pscustomobject]@{ path = $rootWheel; member = 'skillspector/__init__.py' },
            [pscustomobject]@{ path = $dependencyWheel; member = 'deep/' + ('n' * $memberLength) + '.py' }
        )) {
            $archive = [IO.Compression.ZipFile]::Open($spec.path, [IO.Compression.ZipArchiveMode]::Create)
            try { [void]$archive.CreateEntry($spec.member) }
            finally { $archive.Dispose() }
        }
        Assert-PythonWheelInstallPath -InstallPath $installPath -WheelPath $rootWheel
        $manifest = [pscustomobject]@{ entries = @(
            [pscustomobject]@{ file = (Split-Path -Leaf $rootWheel) },
            [pscustomobject]@{ file = (Split-Path -Leaf $dependencyWheel) }
        ) }
        $failure = $null
        try { Assert-PythonWheelhouseInstallPaths -InstallPath $installPath -WheelhousePath $wheelhouse -Manifest $manifest }
        catch { $failure = $_.Exception.Message }
        Assert-Match $failure 'wheel member exceeds safe Windows install path length' 'The selected dependency must fail before pip installation.'
    }

    # Scenario: The validator is invoked from normal/deep repository locations and normal/nested-long owned TEMP roots.
    # Purpose: Keep test-fixture allocation independent of caller path geometry while exercising the real 84-character authority fallback boundary.
    It 'UnitT26h_allocates_authority_tool_root_with_windows_path_length_headroom_<RepositoryGeometry>_<TempGeometry>' -TestCases @(
        @{ RepositoryGeometry='normal-repository'; TempGeometry='normal-temp' },
        @{ RepositoryGeometry='normal-repository'; TempGeometry='long-temp' },
        @{ RepositoryGeometry='deep-repository'; TempGeometry='normal-temp' },
        @{ RepositoryGeometry='deep-repository'; TempGeometry='long-temp' }
    ) {
        param([string] $RepositoryGeometry, [string] $TempGeometry)

        . $script:AuthorityGatePath -DefineFunctionsOnly
        $names = @('TEMP', 'TMP', 'LOCALAPPDATA')
        $previous = @{}
        foreach ($name in $names) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        }
        $originalRepositoryRoot = $script:RepositoryRoot
        $originalLocation = Get-Location

        try {
            $contextFixture = New-Syp325FixtureRoot
            $contextRoot = $contextFixture.Root
            $repoNormal = Join-Path $contextRoot 'repo-normal'
            [void](New-Item -ItemType Directory -Path $repoNormal -ErrorAction Stop)
            $repoDeep = Join-Path $contextRoot 'repo-deep'
            [void](New-Item -ItemType Directory -Path $repoDeep -ErrorAction Stop)
            while ($repoDeep.Length -lt 150) {
                $repoDeep = Join-Path $repoDeep ('r' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                [void](New-Item -ItemType Directory -Path $repoDeep -ErrorAction Stop)
            }
            $tempNormal = Join-Path $contextRoot 'temp-normal'
            [void](New-Item -ItemType Directory -Path $tempNormal -ErrorAction Stop)
            $tempLong = Join-Path $contextRoot 'temp-long'
            [void](New-Item -ItemType Directory -Path $tempLong -ErrorAction Stop)
            while ($tempLong.Length -lt 150) {
                $tempLong = Join-Path $tempLong ('t' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                [void](New-Item -ItemType Directory -Path $tempLong -ErrorAction Stop)
            }
            $repositoryContext = if ($RepositoryGeometry -ceq 'normal-repository') { $repoNormal } else { $repoDeep }
            $tempContext = if ($TempGeometry -ceq 'normal-temp') { $tempNormal } else { $tempLong }
            $script:RepositoryRoot = [IO.Path]::GetFullPath($repositoryContext)
            Set-Location -LiteralPath $repositoryContext
            [Environment]::SetEnvironmentVariable('TEMP', $tempContext, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('TMP', $tempContext, [EnvironmentVariableTarget]::Process)

            $fixture = New-Syp325FixtureRoot
            $taskRoot = $fixture.Root
            $localAppData = $taskRoot
            $fallbackRoot = [IO.Path]::GetFullPath((Join-Path $localAppData 'Temp'))
            $currentPrefix = 'cur-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $currentLength = 84
            $currentTemp = Join-Path $fallbackRoot ($currentPrefix + ('x' * ($currentLength - $fallbackRoot.Length - $currentPrefix.Length - 1)))

            Assert-True ($taskRoot.Length -le 57) 'The derived fixture root must preserve the established fallback path-budget geometry.'
            Assert-Equal $currentTemp.Length 84 'The synthetic current-temp path must retain the established 84-character geometry.'
            [void](New-Item -ItemType Directory -Path $fallbackRoot -ErrorAction Stop)
            [void](New-Item -ItemType Directory -Path $currentTemp -ErrorAction Stop)
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('TEMP', $currentTemp, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('TMP', $currentTemp, [EnvironmentVariableTarget]::Process)

            $collisionRunId = [guid]::NewGuid().ToString('N')
            $collisionRoot = Join-Path $fallbackRoot ("svt-tools-{0}" -f $collisionRunId)
            [void][IO.Directory]::CreateDirectory($collisionRoot)
            $collision = $null
            try { [void](New-AuthorityRunOwnedToolRoot -RunId $collisionRunId) }
            catch { $collision = $_.Exception.Message }
            Assert-True (-not [string]::IsNullOrWhiteSpace($collision)) 'A same-run root in any candidate must fail create-only instead of escaping into another candidate.'
            Assert-False (Test-Path -LiteralPath (Join-Path $currentTemp ("svt-tools-{0}" -f $collisionRunId))) 'A collision must not create a duplicate root in the current temp candidate.'

            $runId = [guid]::NewGuid().ToString('N')
            $expectedCurrentRoot = Join-Path $currentTemp ("svt-tools-{0}" -f $runId)
            $expectedCurrentProbe = Join-Path (Join-Path (Join-Path (Join-Path $expectedCurrentRoot ('ss-' + ('a' * 12))) 'venv') 'Lib') (Join-Path 'site-packages' (('p' * 96) + '.probe'))
            Assert-True ($expectedCurrentRoot.Length -lt 128) 'The synthetic current-temp root must pass the old root-only limit.'
            Assert-True ($expectedCurrentProbe.Length -ge 248) 'The actual deepest Spector path must exceed the Windows limit in the synthetic current temp.'

            $toolRoot = New-AuthorityRunOwnedToolRoot -RunId $runId
            $expectedFallbackRoot = Join-Path $fallbackRoot ("svt-tools-{0}" -f $runId)
            $selectedProbe = Join-Path (Join-Path (Join-Path (Join-Path $toolRoot ('ss-' + ('a' * 12))) 'venv') 'Lib') (Join-Path 'site-packages' (('p' * 96) + '.probe'))
            Assert-Equal ([IO.Path]::GetFullPath($toolRoot)) ([IO.Path]::GetFullPath($expectedFallbackRoot)) 'An over-budget current temp must fall back to per-user LocalAppData Temp.'
            Assert-True ($selectedProbe.Length -lt 248) 'The selected root must keep the actual deepest Spector path below the Windows limit.'
            Assert-False (Test-Path -LiteralPath $expectedCurrentRoot) 'An over-budget current temp must not receive a partially usable tool root.'
            Assert-True (Test-Path -LiteralPath $toolRoot -PathType Container) 'Authority tools must be created in a run-owned directory.'
            Assert-False ((Get-Item -Force -LiteralPath $toolRoot).Attributes -band [System.IO.FileAttributes]::ReparsePoint) 'Authority tool root must not be a reparse point.'
            Assert-True ($toolRoot.Length -lt 128) 'Authority tool root must remain within the established root budget.'
            Assert-Match $toolRoot ('svt-tools-' + $runId) 'Authority tool root must bind to the current run id.'
        }
        finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $previous[$name], [EnvironmentVariableTarget]::Process)
            }
            $script:RepositoryRoot = $originalRepositoryRoot
            Set-Location -LiteralPath $originalLocation.Path
        }
    }

    It 'UnitT26ha_fails_before_creation_when_all_authority_tool_candidates_exceed_the_windows_path_budget' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $names = @('TEMP', 'TMP', 'LOCALAPPDATA')
        $previous = @{}
        foreach ($name in $names) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        }

        $fixture = New-Syp325FixtureRoot
        $taskRoot = $fixture.Root
        $token = [guid]::NewGuid().ToString('N')
        $longCurrentLength = 110
        $currentLeafLength = $longCurrentLength - $taskRoot.Length - 1
        $longCurrent = Join-Path $taskRoot ('t' + $token.Substring(0, 8) + ('x' * ($currentLeafLength - 9)))
        $localAppDataLength = 100
        $localAppDataLeafLength = $localAppDataLength - $taskRoot.Length - 1
        $localAppData = Join-Path $taskRoot ('l' + $token.Substring(8, 8) + ('y' * ($localAppDataLeafLength - 9)))
        $fallbackRoot = Join-Path $localAppData 'Temp'
        $runId = [guid]::NewGuid().ToString('N')
        $currentToolRoot = Join-Path $longCurrent ("svt-tools-{0}" -f $runId)
        $fallbackToolRoot = Join-Path $fallbackRoot ("svt-tools-{0}" -f $runId)
        $ownsLongCurrent = $false
        $ownsLocalAppData = $false

        try {
            if (Test-Path -LiteralPath $longCurrent) { throw "Refusing to reuse fixture path: $longCurrent" }
            [void](New-Item -ItemType Directory -Path $longCurrent -ErrorAction Stop)
            $ownsLongCurrent = $true
            if (Test-Path -LiteralPath $localAppData) { throw "Refusing to reuse fixture path: $localAppData" }
            [void](New-Item -ItemType Directory -Path $localAppData -ErrorAction Stop)
            $ownsLocalAppData = $true
            [void](New-Item -ItemType Directory -Path $fallbackRoot -ErrorAction Stop)
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('TEMP', $longCurrent, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('TMP', $longCurrent, [EnvironmentVariableTarget]::Process)

            $failure = $null
            try { [void](New-AuthorityRunOwnedToolRoot -RunId $runId) }
            catch { $failure = $_.Exception.Message }
            Assert-Match $failure '248' 'When every candidate exceeds the complete Windows probe-path budget, fail with a clear early path-budget diagnostic.'
            Assert-False (Test-Path -LiteralPath $currentToolRoot) 'An over-budget current temp must not receive a tool root.'
            Assert-False (Test-Path -LiteralPath $fallbackToolRoot) 'An over-budget fallback temp must not receive a tool root.'
        }
        finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $previous[$name], [EnvironmentVariableTarget]::Process)
            }
        }
    }

    # Scenario: The current temp is usable while the optional per-user fallback is not a directory.
    # Purpose: An unusable fallback must not block allocation in the available current temp.
    It 'UnitT26hb_keeps_an_available_current_temp_when_the_optional_fallback_is_unusable' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $names = @('TEMP', 'TMP', 'LOCALAPPDATA')
        $previous = @{}
        foreach ($name in $names) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        }

        $token = [guid]::NewGuid().ToString('N')
        $fixture = New-Syp325FixtureRoot
        $taskRoot = $fixture.Root
        $currentTempFixture = New-Syp325FixtureRoot
        $localAppData = $taskRoot
        $unavailableFallback = [IO.Path]::GetFullPath((Join-Path $localAppData 'Temp'))
        $runId = [guid]::NewGuid().ToString('N')
        $currentTemp = $null
        $expectedToolRoot = $null
        $expectedProbe = $null

        try {
            Write-TestUtf8File -Path $unavailableFallback -Text 'the optional fallback is not a directory'
            $currentTemp = $currentTempFixture.Root
            $expectedToolRoot = [IO.Path]::GetFullPath((Join-Path $currentTemp ("svt-tools-{0}" -f $runId)))
            $expectedProbe = Join-Path (Join-Path (Join-Path (Join-Path $expectedToolRoot ('ss-' + ('a' * 12))) 'venv') 'Lib') (Join-Path 'site-packages' (('p' * 96) + '.probe'))
            Assert-True ($expectedProbe.Length -lt 248) ("The available current-temp fixture must leave room for the full Windows Python venv probe path; length=$($expectedProbe.Length), path='$expectedProbe'.")
            [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localAppData, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('TEMP', $currentTemp, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('TMP', $currentTemp, [EnvironmentVariableTarget]::Process)

            $toolRoot = New-AuthorityRunOwnedToolRoot -RunId $runId
            Assert-Equal ([IO.Path]::GetFullPath($toolRoot)) $expectedToolRoot ("An unusable optional fallback must not redirect a usable current temp candidate; helper returned '$toolRoot'.")
            Assert-True (Test-Path -LiteralPath $expectedToolRoot -PathType Container) ("The available current temp candidate must receive the run-owned root at '$toolRoot'.")
            Assert-True (Test-Path -LiteralPath $unavailableFallback -PathType Leaf) 'The non-directory fallback blocker must remain untouched.'
            Assert-Equal ([IO.File]::ReadAllText($unavailableFallback)) 'the optional fallback is not a directory' 'The fallback blocker must remain unchanged.'
        }
        finally {
            foreach ($name in $names) {
                [Environment]::SetEnvironmentVariable($name, $previous[$name], [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT27_requires_ordinary_gate_to_execute_retained_checks_without_external_tooling' {
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:WorkflowPath
        $requiredWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:RequiredPowerShellWorkflowPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        $bindingOnlyIndex = $gate.IndexOf('if ($BindingOnly) {')

        . $script:AuthorityGatePath -DefineFunctionsOnly

        foreach ($workflowText in @($workflow, $requiredWorkflow)) {
            Assert-NotMatch $workflowText 'actions/setup-go|STANDARD_GO_RUNTIME_VERSION|STANDARD_GO_COMMAND_PATH|GITHUB_TOKEN' 'Ordinary authority workflows must not set up Go or pass external release credentials.'
            Assert-Match $workflowText "persist-credentials:\s*false" 'Authority checkout credentials must remain disabled.'
            Assert-Match $workflowText 'Install-Module Pester -RequiredVersion 4\.10\.1 -Scope CurrentUser -Force -SkipPublisherCheck' 'Each ordinary authority workflow must provision the pinned Pester version when absent.'
            Assert-Match $workflowText '-CandidateRoot \$candidateRoot -AuthorityRoot \$candidateRoot -CandidateRevision \$revision -AuthorityRevision \$revision -EventName \$env:GITHUB_EVENT_NAME -ResultArtifact ''[^'']+\.json''' 'Each ordinary workflow must pass both roots, full revision identities, event name, and a checkout-external relative result name.'
        }

        Assert-Match $workflow 'Run canonical Standard v1 authority gate' 'Standards workflow must execute the shared authority gate.'
        Assert-Match $requiredWorkflow 'name:\s*Windows Core' 'The Windows Core automatic authority job must remain present.'
        Assert-Match $requiredWorkflow 'Run the Standard v1 authority gate' 'Windows Core must execute the authority gate.'
        Assert-Match $gate 'tests/skill-repository-standard\.Tests\.ps1' 'Shared gate must run the Standard authority regression.'
        Assert-Match $gate 'tests/skill-repository-workflows\.Tests\.ps1' 'Shared gate must run the workflow authority regression.'
        Assert-Match $gate 'tests/standard-authority-entry-preflight\.Tests\.ps1' 'Shared gate must run the entry preflight contract.'
        Assert-Match $gate 'tests/standard-entry-point-binding\.Tests\.ps1' 'Shared gate must run the binding contract.'
        Assert-Match $gate 'tests/standard-core-pester-adapter\.Tests\.ps1' 'Shared gate must run the bounded Pester adapter contract.'

        $normalMain = $gate.Substring($bindingOnlyIndex)
        Assert-NotMatch $normalMain 'ExpectedGoRuntimeVersion|GoCommandPath|STANDARD_GO_|Resolve-StandardValidationTool|Resolve-PythonWheelClosure|New-AuthorityRunOwnedToolRoot|Invoke-AuthorityExternalCommand|skill-validator|skill-tools|SkillSpector|STANDARD_AUTHORITY_PYTHON|validation-security-gate\.json|upstream-adapter\.json|tenStageCompletionClaim' 'Ordinary gate main must not depend on Go, resolvers, providers, fixtures, scanners, or the ten-stage runner.'
        Assert-Match $normalMain 'Invoke-Pester -Script \$authorityTestPaths -Strict -PassThru' 'The normal main must really execute the retained TestPaths with strict Pester 4 results.'
        Assert-Match $normalMain 'Import-PowerShellDataFile -LiteralPath \$pesterManifestPath' 'The ordinary gate must inspect the exact pinned Pester manifest before importing it.'
        Assert-Match $normalMain '\$pesterManifest\.ContainsKey\(''RootModule''\)' 'The ordinary gate must check whether the Pester manifest declares RootModule before reading it.'
        Assert-Match $normalMain '\$pesterManifest\[''RootModule''\]' 'The ordinary gate must select RootModule through the verified manifest hashtable indexer.'
        Assert-Match $normalMain '\$pesterManifest\.ContainsKey\(''ModuleToProcess''\)' 'The ordinary gate must check whether the Pester manifest declares ModuleToProcess before reading it.'
        Assert-Match $normalMain '\$pesterManifest\[''ModuleToProcess''\]' 'The ordinary gate must select ModuleToProcess through the verified manifest hashtable indexer.'
        Assert-Match $normalMain '\$loadedPester\.Path' 'The loaded Pester path must be checked against its declared root module.'
        Assert-Match $normalMain '\$loadedPester\.ModuleBase' 'The loaded Pester module base must be checked against the selected installation.'
        Assert-Match $normalMain 'pesterRootModuleSha256|pesterManifestSha256' 'The imported Pester files must retain their verified file hashes.'
        Assert-Match $normalMain 'Assert-AuthorityPesterResult -Result \$pesterResult -PesterMajorVersion 4' 'The normal main must reject zero, failed, skipped, pending, or incomplete Pester results.'
        Assert-Match $normalMain 'Get-AuthorityEntryPreflight @bindingParameters' 'The normal main must rebind current source identity after the retained tests run.'
        Assert-Match $normalMain 'Assert-StandardEntryPointResult' 'The normal main must validate the executed result against the candidate binding.'
        Assert-Match $normalMain '\[IO\.FileMode\]::CreateNew' 'The result writer must create a unique temporary file without overwriting.'
        Assert-Match $normalMain '\[IO\.File\]::Move\(\$temporaryResultPath, \$resultPath, \$false\)' 'The result writer must publish with a no-overwrite move.'
        Assert-NotMatch $normalMain '\bMinimumTotalCount\b' 'The gate must not impose a fixed test-count prerequisite.'

        $observedTestPaths = @([regex]::Matches($normalMain, "tests/[^']+\.Tests\.ps1") | ForEach-Object { $_.Value })
        $expectedTestPaths = @(
            'tests/internal-source-continuation.Tests.ps1',
            'tests/skill-repository-standard.Tests.ps1',
            'tests/skill-repository-workflows.Tests.ps1',
            'tests/standard-authority-entry-preflight.Tests.ps1',
            'tests/standard-entry-point-binding.Tests.ps1',
            'tests/standard-core-pester-adapter.Tests.ps1'
        )
        Assert-Equal ($observedTestPaths -join '|') ($expectedTestPaths -join '|') 'The ordinary gate must execute exactly the six retained TestPaths in the packet order.'
        Assert-NotMatch $normalMain 'GITHUB_TOKEN|GH_TOKEN' 'The ordinary gate must not receive external resolver credentials.'
        # Scenario: External validators return clean-looking reports for a different package, incomplete inventory, or downgraded findings.
        # Purpose: Bind every report to this exact fixture and interpret native report severity without PowerShell coercion.
        $reportFixture = New-TestAuthorityFixture -Root (Join-Path $TestDrive 'standard-validation-fixture')
        $fixtureInventory = @('SKILL.md', 'agents/openai.yaml')

        $skillSpectorBaseline = [pscustomobject][ordered]@{
            execution_successful=$true
            analysis_completeness=[pscustomobject][ordered]@{
                execution_successful=$true; is_complete=$true; status='complete'; coverage_percent=100
                ledger_exceptions=@(); scope_exclusions=@(); limitations=@()
            }
            skill=[pscustomobject]@{ name='standard-validation-fixture'; source=$reportFixture.Root }
            components=@(
                [pscustomobject]@{ path='SKILL.md'; type='markdown' },
                [pscustomobject]@{ path='agents/openai.yaml'; type='yaml' }
            )
            issues=@()
            risk_assessment=[pscustomobject]@{ recommendation='SAFE' }
        }
        Assert-AuthoritySkillSpectorReport -Report $skillSpectorBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedSkillId 'standard-validation-fixture' -ExpectedInventoryPaths $fixtureInventory
        $skillSpectorCases = @(
            @{ Pattern='unsuccessful or incomplete'; Mutate={ param($r) $r.analysis_completeness.coverage_percent='100' } },
            @{ Pattern='unsuccessful or incomplete'; Mutate={ param($r) $r.analysis_completeness.coverage_percent=$true } },
            @{ Pattern='unsuccessful or incomplete'; Mutate={ param($r) $r.analysis_completeness.status=1 } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.risk_assessment.recommendation=$true } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.issues=@([pscustomobject]@{ severity='CRITICAL' }) } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.issues=@([pscustomobject]@{ severity='WARNING' }) } },
            @{ Pattern='empty issues\[\]'; Mutate={ param($r) $r.issues=@([pscustomobject]@{ futureFinding=$true }) } },
            @{ Pattern='fixture identity'; Mutate={ param($r) $r.skill.name='other-fixture' } },
            @{ Pattern='fixture identity'; Mutate={ param($r) $r.skill.source=(Split-Path -Parent $reportFixture.Root) } },
            @{ Pattern='exact controlled fixture inventory'; Mutate={ param($r) $r.components=@($r.components[0]) } },
            @{ Pattern='exact controlled fixture inventory'; Mutate={ param($r) $r.components[1].path='other.yaml' } }
        )
        foreach ($case in $skillSpectorCases) {
            $report = Copy-TestJsonObject $skillSpectorBaseline
            & $case.Mutate $report
            $errorMessage = $null
            try { Assert-AuthoritySkillSpectorReport -Report $report -ExpectedFixtureRoot $reportFixture.Root -ExpectedSkillId 'standard-validation-fixture' -ExpectedInventoryPaths $fixtureInventory }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) 'SkillSpector report identity, inventory, findings, and scalar types must fail closed on drift.'
        }

        $skillValidatorBaseline = [pscustomobject][ordered]@{
            skill_dir=$reportFixture.Root; passed=$true; errors=0; warnings=0
            results=@(
                [pscustomobject]@{ level='pass'; category='structure'; message='SKILL.md structure is valid.'; file='SKILL.md'; line=1 },
                [pscustomobject]@{ level='info'; category='metadata'; message='Optional metadata was inspected.'; file='agents/openai.yaml' },
                [pscustomobject]@{ level='pass'; category='overall'; message='Package validation completed.' }
            )
            token_counts=[pscustomobject]@{
                files=@([pscustomobject]@{ file='SKILL.md body'; tokens=1 })
                total=1
            }
            other_token_counts=[pscustomobject]@{
                files=@([pscustomobject]@{ file='agents/openai.yaml'; tokens=1 })
                total=1
            }
        }
        Assert-AuthoritySkillValidatorReport -Report $skillValidatorBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -ExpectedTokenPaths @('SKILL.md') -ExpectedOtherTokenPaths @('agents/openai.yaml')
        $skillValidatorCases = @(
            @{ Mutate={ param($r) $r.skill_dir=(Split-Path -Parent $reportFixture.Root) } },
            @{ Mutate={ param($r) $r.errors='0' } },
            @{ Mutate={ param($r) $r.errors=$false } },
            @{ Mutate={ param($r) $r.warnings='0' } },
            @{ Mutate={ param($r) $r.results=[pscustomobject]@{ level='pass'; category='structure'; message='scalar' } } },
            @{ Mutate={ param($r) $r.results=@($true) } },
            @{ Mutate={ param($r) $r.results[0].level='warning' } },
            @{ Mutate={ param($r) $r.results[0].level='error' } },
            @{ Mutate={ param($r) $r.results[0].level='unknown' } },
            @{ Mutate={ param($r) $r.results[0].level=1 } },
            @{ Mutate={ param($r) $r.results[0].category=$true } },
            @{ Mutate={ param($r) $r.results[0].message='' } },
            @{ Mutate={ param($r) $r.results[0].file='../outside.md' } },
            @{ Mutate={ param($r) $r.results[0].line='1' } },
            @{ Pattern='coverage envelope'; Mutate={ param($r) $r.PSObject.Properties.Remove('token_counts') } },
            @{ Pattern='coverage envelope'; Mutate={ param($r) $r.other_token_counts.files=@([pscustomobject]@{ file='other.md'; tokens=1 }); $r.other_token_counts.total=1 } },
            @{ Pattern='coverage envelope'; Mutate={ param($r) $r.other_token_counts.total=2 } },
            @{ Pattern='coverage envelope'; Mutate={ param($r) $r.token_counts.files[0].tokens='1' } }
        )
        foreach ($case in $skillValidatorCases) {
            $report = Copy-TestJsonObject $skillValidatorBaseline
            & $case.Mutate $report
            $errorMessage = $null
            try { Assert-AuthoritySkillValidatorReport -Report $report -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -ExpectedTokenPaths @('SKILL.md') -ExpectedOtherTokenPaths @('agents/openai.yaml') }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'skill-validator' 'skill-validator package binding, result shape, severity, and optional locations must fail closed on drift.'
        }

        $skillPath = Join-Path $reportFixture.Root 'SKILL.md'
        $metadataPath = Join-Path $reportFixture.Root 'agents/openai.yaml'
        $skillToolsCoverageBaseline = [pscustomobject][ordered]@{
            schemaVersion=1
            toolName='skill-tools'
            coverageMode='authority-input-inventory'
            root=$reportFixture.Root
            files=@(
                [pscustomobject][ordered]@{ path='SKILL.md'; sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $skillPath).Hash.ToLowerInvariant() }
                [pscustomobject][ordered]@{ path='agents/openai.yaml'; sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $metadataPath).Hash.ToLowerInvariant() }
            )
        }
        $sarifBaseline = [pscustomobject][ordered]@{
            version='2.1.0'
            runs=@([pscustomobject]@{
                tool=[pscustomobject]@{ driver=[pscustomobject]@{
                    name='skill-tools'
                    rules=@([pscustomobject]@{ id='fixture-rule'; defaultConfiguration=[pscustomobject]@{ level='warning' } })
                } }
                results=@([pscustomobject]@{
                    ruleId='fixture-rule'; level='warning'; message=[pscustomobject]@{ text='Controlled fixture advisory.' }
                    locations=@(
                        [pscustomobject]@{ physicalLocation=[pscustomobject]@{ artifactLocation=[pscustomobject]@{ uri=$skillPath } } },
                        [pscustomobject]@{ physicalLocation=[pscustomobject]@{ artifactLocation=[pscustomobject]@{ uri=$metadataPath } } }
                    )
                })
            })
        }
        Assert-AuthoritySkillToolsSarifReport -Report $sarifBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -CoverageEnvelope $skillToolsCoverageBaseline
        $sarifExplicitLevelWithoutRuleDefault = Copy-TestJsonObject $sarifBaseline
        $sarifExplicitLevelWithoutRuleDefault.runs[0].tool.driver.rules[0].PSObject.Properties.Remove('defaultConfiguration')
        Assert-AuthoritySkillToolsSarifReport -Report $sarifExplicitLevelWithoutRuleDefault -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -CoverageEnvelope $skillToolsCoverageBaseline
        $sarifDefaultLevelBaseline = Copy-TestJsonObject $sarifBaseline
        $sarifDefaultLevelBaseline.runs[0].results[0].PSObject.Properties.Remove('level')
        $sarifDefaultLevelBaseline.runs[0].tool.driver.rules[0].defaultConfiguration.level = 'note'
        Assert-AuthoritySkillToolsSarifReport -Report $sarifDefaultLevelBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -CoverageEnvelope $skillToolsCoverageBaseline

        $sarifCases = @(
            @{ Mutate={ param($r) $r.version=2.1 } },
            @{ Mutate={ param($r) $r.runs[0].tool.driver.name=123 } },
            @{ Mutate={ param($r) $r.runs[0].tool.driver.rules=@() } },
            @{ Mutate={ param($r) $r.runs[0].results=[pscustomobject]@{ ruleId='fixture-rule' } } },
            @{ Mutate={ param($r) $r.runs[0].results=@($true) } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level=$true } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level=2 } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level='fatal' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level=@('warning') } },
            @{ Mutate={ param($r) $r.runs[0].results[0].level='error' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].ruleId='unknown-rule' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].PSObject.Properties.Remove('defaultConfiguration') } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].defaultConfiguration.level=$true } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].defaultConfiguration.level='fatal' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].PSObject.Properties.Remove('level'); $r.runs[0].tool.driver.rules[0].defaultConfiguration.level='error' } },
            @{ Mutate={ param($r) $r.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri=(Join-Path (Split-Path -Parent $reportFixture.Root) 'outside.md') } }
        )
        foreach ($case in $sarifCases) {
            $report = Copy-TestJsonObject $sarifBaseline
            & $case.Mutate $report
            $errorMessage = $null
            try { Assert-AuthoritySkillToolsSarifReport -Report $report -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -CoverageEnvelope $skillToolsCoverageBaseline }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'skill-tools' 'SARIF rule binding, effective severity, result shape, and fixture location must fail closed on drift.'
        }

        $sarifPartialLocations = Copy-TestJsonObject $sarifBaseline
        $sarifPartialLocations.runs[0].results[0].locations=@($sarifPartialLocations.runs[0].results[0].locations[0])
        Assert-AuthoritySkillToolsSarifReport -Report $sarifPartialLocations -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -CoverageEnvelope $skillToolsCoverageBaseline

        $skillToolsCoverageCases = @(
            @{ Mutate={ param($e) $e.PSObject.Properties.Remove('files') } },
            @{ Mutate={ param($e) $e.files=@($e.files[0]) } },
            @{ Mutate={ param($e) $e.files[1].path='other.yaml' } },
            @{ Mutate={ param($e) $e.files[0].sha256='0' * 64 } },
            @{ Mutate={ param($e) $e.coverageMode='sarif-result-locations' } },
            @{ Mutate={ param($e) $e.root=(Split-Path -Parent $reportFixture.Root) } },
            @{ Mutate={ param($e) $e.files += [pscustomobject][ordered]@{ path='SKILL.md'; sha256=$e.files[0].sha256 } } }
        )
        foreach ($case in $skillToolsCoverageCases) {
            $coverage = Copy-TestJsonObject $skillToolsCoverageBaseline
            & $case.Mutate $coverage
            $errorMessage = $null
            try { Assert-AuthoritySkillToolsSarifReport -Report $sarifBaseline -ExpectedFixtureRoot $reportFixture.Root -ExpectedInventoryPaths $fixtureInventory -CoverageEnvelope $coverage }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'skill-tools coverage envelope' 'skill-tools coverage envelope identity, exact inventory, and current file hashes must fail closed on drift.'
        }
    }

    # Scenario: Pester returns one all-passed authority test or discovers zero tests.
    # Purpose: Prove any positive discovery count can pass while zero discovery still fails closed.
    It 'UnitT27a_accepts_one_passed_test_and_rejects_zero_discovery' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $clean = [pscustomobject][ordered]@{
            TotalCount=1; PassedCount=1; FailedCount=0; Result='Passed'
            FailedBlocksCount=0; FailedContainersCount=0; SkippedCount=0
            NotRunCount=0; InconclusiveCount=0; Errors=@()
        }
        Assert-AuthorityPesterResult -Result $clean -PesterMajorVersion 6

        $empty = $clean.PSObject.Copy()
        $empty.TotalCount = 0
        $empty.PassedCount = 0
        $errorMessage = $null
        try { Assert-AuthorityPesterResult -Result $empty -PesterMajorVersion 6 }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'discovered zero authority tests' 'Zero authority-test discovery must fail closed.'
    }

    # Scenario: Pester reports every test passed while discovery/container metadata still records a framework failure.
    # Purpose: Prevent a false green based only on FailedCount and PassedCount.
    It 'UnitT27b_rejects_hidden_Pester_block_container_and_discovery_errors' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $cases = @(
            @{ Name='FailedBlocksCount'; Value=1; Pattern='FailedBlocksCount=1' },
            @{ Name='FailedContainersCount'; Value=1; Pattern='FailedContainersCount=1' },
            @{ Name='SkippedCount'; Value=1; Pattern='SkippedCount=1' },
            @{ Name='NotRunCount'; Value=1; Pattern='NotRunCount=1' },
            @{ Name='InconclusiveCount'; Value=1; Pattern='InconclusiveCount=1' },
            @{ Name='Errors'; Value=@('discovery failed', 'container failed'); Pattern='discovery/container errors' }
        )
        foreach ($case in $cases) {
            $result = [pscustomobject][ordered]@{
                TotalCount=1; PassedCount=1; FailedCount=0; Result='Passed'
                FailedBlocksCount=0; FailedContainersCount=0; SkippedCount=0
                NotRunCount=0; InconclusiveCount=0; Errors=@()
            }
            $result.($case.Name) = $case.Value
            $errorMessage = $null
            try { Assert-AuthorityPesterResult -Result $result -PesterMajorVersion 6 }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Pester $($case.Name) must fail closed."
        }
    }

    # Scenario: The controlled authority fixture loses metadata or drifts from its exact Skill identity and lexical contracts.
    # Purpose: Prevent the authority repository's no-active-Skill exception from validating a partial or malformed package.
    It 'UnitT31_rejects_incomplete_or_malformed_authority_fixtures' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $cases = @(
            @{
                Name='missing-openai-metadata'; Pattern='missing required file.*openai.yaml'
                Mutate={ param($fixture) Remove-Item -LiteralPath $fixture.MetadataPath -Force }
            },
            @{
                Name='wrong-default-prompt-token'; Pattern='must reference exact token'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.MetadataPath).Replace('$standard-validation-fixture', '$other-fixture')
                    Write-TestUtf8File -Path $fixture.MetadataPath -Text $text
                }
            },
            @{
                Name='unquoted-openai-string'; Pattern='double-quoted string values'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.MetadataPath).Replace('"Standard Validation Fixture"', 'Standard Validation Fixture')
                    Write-TestUtf8File -Path $fixture.MetadataPath -Text $text
                }
            },
            @{
                Name='quoted-openai-key'; Pattern='unquoted keys and double-quoted string values'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.MetadataPath).Replace('display_name:', '"display_name":')
                    Write-TestUtf8File -Path $fixture.MetadataPath -Text $text
                }
            },
            @{
                Name='wrong-frontmatter-identity'; Pattern='metadata or body is incomplete'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.SkillPath).Replace('name: standard-validation-fixture', 'name: other-fixture')
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            },
            @{
                Name='unknown-frontmatter-field'; Pattern='unsupported or duplicate frontmatter key'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.SkillPath).Replace("description: A deterministic Agent Skill package for authority validation.`n", "description: A deterministic Agent Skill package for authority validation.`nfuture-field: forbidden`n")
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            },
            @{
                Name='malformed-frontmatter-delimiter'; Pattern='closed YAML frontmatter'
                Mutate={ param($fixture)
                    $text = [IO.File]::ReadAllText($fixture.SkillPath).Replace("---`n`n# Standard Validation Fixture", "--`n`n# Standard Validation Fixture")
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            },
            @{
                Name='whitespace-only-body'; Pattern='metadata or body is incomplete'
                Mutate={ param($fixture)
                    $text = "---`nname: standard-validation-fixture`ndescription: A deterministic Agent Skill package for authority validation.`n---`n   `n"
                    Write-TestUtf8File -Path $fixture.SkillPath -Text $text
                }
            }
        )

        $validFixture = New-TestAuthorityFixture -Root (Join-Path $TestDrive 'fixture-valid')
        Assert-AuthorityFixtureContract -FixtureRoot $validFixture.Root -ExpectedSkillId 'standard-validation-fixture'
        foreach ($case in $cases) {
            $fixture = New-TestAuthorityFixture -Root (Join-Path $TestDrive ([string]$case.Name))
            & $case.Mutate $fixture
            $errorMessage = $null
            try { Assert-AuthorityFixtureContract -FixtureRoot $fixture.Root -ExpectedSkillId 'standard-validation-fixture' }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Malformed fixture '$($case.Name)' must fail closed."
        }
    }

    # Scenario: GITHUB_SHA names a syntactically valid commit other than the checked-out candidate.
    # Purpose: Bind authority evidence to checkout HEAD rather than caller-controlled CI metadata.
    It 'UnitT32_rejects_a_GITHUB_SHA_that_does_not_match_checkout_HEAD' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $head = Get-AuthorityCandidateCommit -RepositoryRoot $script:RepositoryRoot -ExpectedCommit ''
        Assert-Match $head '^[0-9a-f]{40}$' 'Checkout HEAD must resolve to a full lowercase commit.'
        $wrongCommit = if ($head -ceq ('0' * 40)) { '1' * 40 } else { '0' * 40 }
        $previous = [Environment]::GetEnvironmentVariable('GITHUB_SHA', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('GITHUB_SHA', $wrongCommit, [EnvironmentVariableTarget]::Process)
            $errorMessage = $null
            try { Get-AuthorityCandidateCommit -RepositoryRoot $script:RepositoryRoot | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'does not match checkout HEAD' 'A different full GITHUB_SHA must not label the authority evidence.'
        }
        finally {
            [Environment]::SetEnvironmentVariable('GITHUB_SHA', $previous, [EnvironmentVariableTarget]::Process)
        }
    }

    # Scenario: Resolver receipts use text that PowerShell could coerce to trusted booleans or integers.
    # Purpose: Keep policy and installed-tool evidence type-strict after ConvertFrom-Json.
    It 'UnitT33_rejects_receipt_and_policy_scalar_coercion' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $installRoot = Join-Path $TestDrive 'receipt-install-root'
        $toolRoot = Join-Path $installRoot 'fixture-tool'
        [void](New-Item -ItemType Directory -Path $toolRoot -Force)
        $executablePath = Join-Path $toolRoot 'fixture-tool.bin'
        Write-TestUtf8File -Path $executablePath -Text 'fixture executable'
        $executableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $executablePath).Hash.ToLowerInvariant()
        $launcher = [pscustomobject][ordered]@{
            kind='direct-executable'; shimPath=$null; shimSha256=$null; payloadPath=$null; payloadSha256=$null; runtimePath=$null; runtimeSha256=$null
        }
        $validReceipt = [pscustomobject][ordered]@{
            schemaVersion=1; toolName='fixture-tool'; source='fixture/source'; channel='latest-stable'
            frozenForRun=$true; resolvedVersion='1.0.0'; resolvedIdentity='fixture@1.0.0'
            identityKind='fixture-release'; installRoot=$toolRoot; executablePath=$executablePath
            executableSha256=$executableSha256; installedClosureSha256=(Get-AuthorityDirectoryClosureSha256 -Path $toolRoot)
            launcher=$launcher; launcherDigestSha256=(Get-AuthorityLauncherDigest -Launcher $launcher); dependencyClosureSha256=('a' * 64)
            dependencyClosure=@([pscustomobject]@{ name='fixture-tool'; version='1.0.0' }, [pscustomobject]@{ name='dependency'; version='2.0.0' })
        }
        Assert-InstalledAuthorityToolReceipt -Receipt $validReceipt -ToolName 'fixture-tool' -ExpectedSource 'fixture/source' -InstallRoot $installRoot | Out-Null

        $receiptCases = @(
            @{ Name='schemaVersion'; Value='1'; Pattern='unsupported schemaVersion' },
            @{ Name='toolName'; Value=@('fixture-tool'); Pattern='wrong tool identity' },
            @{ Name='channel'; Value=@('latest-stable'); Pattern='must be the exact string' },
            @{ Name='frozenForRun'; Value='true'; Pattern='not frozen' },
            @{ Name='resolvedVersion'; Value=1; Pattern='missing resolvedVersion' },
            @{ Name='dependencyClosureSha256'; Value=('A' * 64); Pattern='lowercase SHA-256' },
            @{ Name='dependencyClosure'; Value=[pscustomobject]@{ name='scalar'; version='1.0.0' }; Pattern='does not contain a dependency/install closure' }
        )
        foreach ($case in $receiptCases) {
            $receipt = Copy-TestJsonObject -Value $validReceipt
            $receipt.([string]$case.Name) = $case.Value
            $errorMessage = $null
            try { Assert-InstalledAuthorityToolReceipt -Receipt $receipt -ToolName 'fixture-tool' -ExpectedSource 'fixture/source' -InstallRoot $installRoot | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Receipt coercion '$($case.Name)' must fail closed."
        }

        $closureMutationPath = Join-Path $toolRoot 'unexpected-installed-file.bin'
        Write-TestUtf8File -Path $closureMutationPath -Text 'installed closure mutation'
        try {
            $errorMessage = $null
            try { Assert-InstalledAuthorityToolReceipt -Receipt $validReceipt -ToolName 'fixture-tool' -ExpectedSource 'fixture/source' -InstallRoot $installRoot | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'installed closure changed' 'A post-resolution installed-file mutation must fail the closure binding.'
        }
        finally {
            Remove-Item -LiteralPath $closureMutationPath -Force -ErrorAction SilentlyContinue
        }

        $validPolicy = [pscustomobject][ordered]@{
            schemaVersion=1; policy='latest-stable-per-validation-run'
            sourceTrust=[pscustomobject][ordered]@{ enforcement='exact-approved-source'; failClosedOnMismatch=$true }
            trustedGoRuntimeVersion='latest-stable'
            recordResolvedIdentityWhenAvailable=$true
        }
        Assert-AuthorityPolicyReceipt -Receipt $validPolicy
        foreach ($case in @(
            @{ Path='schemaVersion'; Value='1'; Pattern='unsupported schemaVersion' },
            @{ Path='policy'; Value=@('latest-stable-per-validation-run'); Pattern='must be the exact string' },
            @{ Path='sourceTrust.enforcement'; Value=1; Pattern='must be the exact string' },
            @{ Path='trustedGoRuntimeVersion'; Value=@('latest-stable'); Pattern='must be the exact string' },
            @{ Path='sourceTrust.failClosedOnMismatch'; Value='true'; Pattern='incomplete or untrusted' },
            @{ Path='recordResolvedIdentityWhenAvailable'; Value='true'; Pattern='incomplete or untrusted' }
        )) {
            $policy = Copy-TestJsonObject -Value $validPolicy
            if ([string]$case.Path -like 'sourceTrust.*') {
                $propertyName = ([string]$case.Path).Substring('sourceTrust.'.Length)
                $policy.sourceTrust.$propertyName = $case.Value
            }
            else {
                $policy.([string]$case.Path) = $case.Value
            }
            $errorMessage = $null
            try { Assert-AuthorityPolicyReceipt -Receipt $policy }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Policy coercion '$($case.Path)' must fail closed."
        }
    }

    # Scenario: A resolver can emit a plausible Go runtime identity for a different executable or run.
    # Purpose: Bind the skill-validator receipt to the exact setup-go executable, bytes, version output and authority run.
    It 'UnitT33a_requires_run_bound_skill_validator_runtime_identity' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $runId = 'b' * 32
        $goPath = Join-Path $TestDrive 'go.exe'
        Write-TestUtf8File -Path $goPath -Text 'approved go executable fixture'
        $goSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $goPath).Hash.ToLowerInvariant()
        $receipt = [pscustomobject][ordered]@{
            resolutionRunId=$runId
            resolvedAtUtc=[DateTime]::UtcNow
            executionContext=[pscustomobject][ordered]@{ os='windows'; architecture='amd64' }
            goRuntimePath=$goPath
            goRuntimeSha256=$goSha256
            goRuntimeVersion='1.27.1'
            goRuntimeVersionOutput=@('go version go1.27.1 windows/amd64')
            goRuntimeOs='windows'
            goRuntimeArchitecture='amd64'
        }

        Assert-AuthorityRunReceiptContext -Receipt $receipt -ExpectedRunId $runId -Context 'skill-validator receipt'
        Assert-AuthoritySkillValidatorRuntimeReceipt `
            -Receipt $receipt `
            -GoCommandPath $goPath `
            -ExpectedGoRuntimeVersion '1.27.1' `
            -Context 'skill-validator receipt'

        $tampered = Copy-TestJsonObject -Value $receipt
        $tampered.goRuntimeSha256 = ('c' * 64)
        $errorMessage = $null
        try {
            Assert-AuthoritySkillValidatorRuntimeReceipt `
                -Receipt $tampered `
                -GoCommandPath $goPath `
                -ExpectedGoRuntimeVersion '1.27.1' `
                -Context 'skill-validator receipt'
        }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'changed after resolution|hash' 'A changed Go runtime receipt must fail closed.'
    }

    # Scenario: Pester 4 and Pester 6 expose different result shapes, and required counts can arrive as coercible text.
    # Purpose: Fail closed on missing version-specific fields and scalar coercion in either supported result contract.
    It 'UnitT34_requires_type_strict_Pester4_and_Pester6_result_fields' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $newPester6Result = {
            [pscustomobject][ordered]@{
                TotalCount=1; PassedCount=1; FailedCount=0; Result='Passed'
                FailedBlocksCount=0; FailedContainersCount=0; SkippedCount=0
                NotRunCount=0; InconclusiveCount=0; Errors=@()
            }
        }
        $newPester4Result = {
            [pscustomobject][ordered]@{
                TotalCount=1; PassedCount=1; FailedCount=0
                SkippedCount=0; PendingCount=0; InconclusiveCount=0
            }
        }
        Assert-AuthorityPesterResult -Result (& $newPester6Result) -PesterMajorVersion 6
        Assert-AuthorityPesterResult -Result (& $newPester4Result) -PesterMajorVersion 4

        foreach ($versionCase in @(
            @{ Major=6; Factory=$newPester6Result; Required=@('Result','FailedBlocksCount','FailedContainersCount','SkippedCount','NotRunCount','InconclusiveCount') },
            @{ Major=4; Factory=$newPester4Result; Required=@('SkippedCount','PendingCount','InconclusiveCount') }
        )) {
            foreach ($name in @($versionCase.Required)) {
                $result = & $versionCase.Factory
                $result.PSObject.Properties.Remove([string]$name)
                $errorMessage = $null
                try { Assert-AuthorityPesterResult -Result $result -PesterMajorVersion ([int]$versionCase.Major) }
                catch { $errorMessage = $_.Exception.Message }
                Assert-Match $errorMessage ("missing required property '{0}'" -f [regex]::Escape([string]$name)) "Pester $($versionCase.Major) must require $name."
            }
        }

        foreach ($case in @(
            @{ Major=6; Factory=$newPester6Result; Name='TotalCount'; Value='1'; Pattern='TotalCount.*non-negative integer' },
            @{ Major=6; Factory=$newPester6Result; Name='TotalCount'; Value=$false; Pattern='TotalCount.*non-negative integer' },
            @{ Major=6; Factory=$newPester6Result; Name='Result'; Value=@('Passed'); Pattern='status must be the exact string' },
            @{ Major=6; Factory=$newPester6Result; Name='FailedBlocksCount'; Value='0'; Pattern='FailedBlocksCount.*non-negative integer' },
            @{ Major=4; Factory=$newPester4Result; Name='PassedCount'; Value='1'; Pattern='PassedCount.*non-negative integer' },
            @{ Major=4; Factory=$newPester4Result; Name='PendingCount'; Value='0'; Pattern='PendingCount.*non-negative integer' },
            @{ Major=6; Factory=$newPester6Result; Name='Errors'; Value='one error'; Pattern='Errors must be an array' },
            @{ Major=6; Factory=$newPester6Result; Name='Errors'; Value=$null; Pattern='Errors must be an array' },
            @{ Major=6; Factory=$newPester6Result; Name='Errors'; Value=@('one error'); Pattern='discovery/container errors' }
        )) {
            $result = & $case.Factory
            $result.([string]$case.Name) = $case.Value
            $errorMessage = $null
            try { Assert-AuthorityPesterResult -Result $result -PesterMajorVersion ([int]$case.Major) }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage ([string]$case.Pattern) "Pester $($case.Major) coercion '$($case.Name)' must fail closed."
        }
    }

    It 'UnitT28_rejects_prerelease_and_pseudo_versions_for_skill_validator' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        Assert-True (Test-StableGoModuleVersion -Version 'v1.6.1') 'A normal release version must be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v1.7.0-rc1') 'A prerelease version must not be stable.'
        Assert-False (Test-StableGoModuleVersion -Version 'v0.0.0-20260902000000-0123456789ab') 'A pseudo-version must not be stable.'
        Assert-True (Test-StableNpmPackageVersion -Version '0.4.1') 'A normal npm release version must be stable.'
        Assert-True (Test-StableNpmPackageVersion -Version '1.2.3+build.4') 'SemVer build metadata may identify a stable npm release.'
        Assert-False (Test-StableNpmPackageVersion -Version '1.2.3-rc.1') 'An npm prerelease must not be stable.'
        Assert-False (Test-StableNpmPackageVersion -Version '^1.2.3') 'An npm range must not be accepted as one frozen version.'
        Assert-False (Test-StableNpmPackageVersion -Version '01.2.3') 'SemVer numeric identifiers must not contain leading zeroes.'
    }

    It 'UnitT28a_binds_SkillSpector_release_wheel_metadata_and_installed_version' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        Assert-SkillSpectorWheelIdentity -ReleaseVersion '2.12.0' -WheelFileName 'skillspector-2.12.0-py3-none-any.whl' -MetadataName 'skillspector' -MetadataVersion '2.12.0'

        $cases = @(
            @{ File = 'skillspector-2.11.0-py3-none-any.whl'; Name = 'skillspector'; Version = '2.12.0'; Pattern = 'release/wheel version mismatch' },
            @{ File = 'skillspector-2.12.0-py3-none-any.whl'; Name = 'other-package'; Version = '2.12.0'; Pattern = 'METADATA Name mismatch' },
            @{ File = 'skillspector-2.12.0-py3-none-any.whl'; Name = 'skillspector'; Version = '2.11.0'; Pattern = 'METADATA Version mismatch' }
        )

        foreach ($case in $cases) {
            $errorMessage = $null
            try {
                Assert-SkillSpectorWheelIdentity -ReleaseVersion '2.12.0' -WheelFileName $case.File -MetadataName $case.Name -MetadataVersion $case.Version
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            Assert-Match $errorMessage $case.Pattern 'SkillSpector release identity mismatch must fail closed.'
        }

        $resolverLines = Get-Content -Encoding UTF8 -LiteralPath $script:ResolverPath
        $codeOnly = (($resolverLines | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        Assert-NotMatch $codeOnly 'importlib\.metadata' 'Installed metadata verification must not start Python and process site-packages startup files.'
        Assert-Match $codeOnly 'Get-InstalledPythonDistributionMetadata' 'Installed SkillSpector version and console entry point must be verified from static dist-info files.'
    }

    # Scenario: A caller supplies one conflicting Go distribution variable before skill-validator resolution.
    # Purpose: Ensure proxy, checksum, bypass, and module-cache overrides all fail before network or cache use.
    It 'UnitT29_rejects_untrusted_Go_distribution_overrides_before_module_resolution' {
        $cases = @(
            @{ Name = 'GOENV'; Value = 'custom-go-env' },
            @{ Name = 'GOPROXY'; Value = 'https://proxy.example.invalid' },
            @{ Name = 'GOSUMDB'; Value = 'off' },
            @{ Name = 'GOPRIVATE'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GONOPROXY'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GONOSUMDB'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GOINSECURE'; Value = 'github.com/agent-ecosystem' },
            @{ Name = 'GOFLAGS'; Value = '-toolexec=untrusted-wrapper' },
            @{ Name = 'GOTOOLCHAIN'; Value = 'auto' },
            @{ Name = 'GOWORK'; Value = (Join-Path $TestDrive 'untrusted-go.work') },
            @{ Name = 'CGO_ENABLED'; Value = '1' },
            @{ Name = 'GOROOT'; Value = (Join-Path $TestDrive 'untrusted-go-root') },
            @{ Name = 'GOOS'; Value = 'plan9' },
            @{ Name = 'GOARCH'; Value = 'wasm' },
            @{ Name = 'GOCACHEPROG'; Value = '/tmp/untrusted-cache-helper' },
            @{ Name = 'GOMODCACHE'; Value = (Join-Path $TestDrive 'untrusted-go-module-cache') },
            @{ Name = 'GOCACHE'; Value = (Join-Path $TestDrive 'untrusted-go-build-cache') },
            @{ Name = 'GOTMPDIR'; Value = (Join-Path $TestDrive 'untrusted-go-tmp') },
            @{ Name = 'GOBIN'; Value = (Join-Path $TestDrive 'untrusted-go-bin') }
        )

        foreach ($case in $cases) {
            $previous = [Environment]::GetEnvironmentVariable($case.Name, [EnvironmentVariableTarget]::Process)
            $errorMessage = $null
            try {
                [Environment]::SetEnvironmentVariable($case.Name, $case.Value, [EnvironmentVariableTarget]::Process)
                & $script:ResolverPath -ToolName skill-validator | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
            }
            finally {
                [Environment]::SetEnvironmentVariable($case.Name, $previous, [EnvironmentVariableTarget]::Process)
            }

            Assert-Match $errorMessage ("Untrusted Go environment override.*{0}" -f $case.Name) ("Go override {0} must fail closed before module resolution." -f $case.Name)
        }
    }

    # Scenario: No conflicting Go variables exist and the approved environment is applied to a resolver action.
    # Purpose: Protect the valid GOENV=off path plus fresh temporary module-cache setup and cleanup.
    It 'UnitT29a_accepts_the_approved_Go_environment_and_executes_the_action' {
        . $script:ResolverPath -ValidatePolicyOnly | Out-Null

        $expectedEnvironment = [ordered]@{
            'GOENV' = 'off'
            'GOPROXY' = 'https://proxy.golang.org'
            'GOSUMDB' = 'sum.golang.org'
            'GOPRIVATE' = ''
            'GONOPROXY' = 'none'
            'GONOSUMDB' = 'none'
            'GOINSECURE' = ''
            'GOFLAGS' = ''
            'GOTOOLCHAIN' = 'local'
            'GOWORK' = 'off'
            'CGO_ENABLED' = '0'
        }

        $previous = [ordered]@{}
        try {
            foreach ($entry in $expectedEnvironment.GetEnumerator()) {
                $previous[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $null, [EnvironmentVariableTarget]::Process)
            }
            foreach ($name in @($deniedGoEnvironmentNames + @('GOMODCACHE', 'GOCACHE', 'GOTMPDIR', 'GOBIN'))) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
            }

            $distributionPolicy = [ordered]@{
                moduleCacheIsolation = 'temporary-empty'
                buildCacheIsolation = 'temporary-empty'
                temporaryDirectoryIsolation = 'temporary-empty'
                binaryInstallIsolation = 'run-owned'
                rejectInheritedModuleCache = $true
                rejectInheritedBuildCache = $true
                rejectDangerousEnvironment = $true
                recordBinaryHash = $true
            }
            $result = Invoke-WithApprovedGoEnvironment -ExpectedEnvironment $expectedEnvironment -DistributionPolicy $distributionPolicy -EnvironmentProbe {
                param($names)
                $snapshot = [ordered]@{}
                foreach ($name in $names) {
                    $snapshot[[string]$name] = if ([string]$name -ceq 'GOENV') {
                        ''
                    }
                    else {
                        [Environment]::GetEnvironmentVariable([string]$name, [EnvironmentVariableTarget]::Process)
                    }
                }
                return [pscustomobject]$snapshot
            } -Action {
                $moduleCache = [Environment]::GetEnvironmentVariable('GOMODCACHE', [EnvironmentVariableTarget]::Process)
                $buildCache = [Environment]::GetEnvironmentVariable('GOCACHE', [EnvironmentVariableTarget]::Process)
                $temporaryDirectory = [Environment]::GetEnvironmentVariable('GOTMPDIR', [EnvironmentVariableTarget]::Process)
                $binaryDirectory = [Environment]::GetEnvironmentVariable('GOBIN', [EnvironmentVariableTarget]::Process)
                [ordered]@{
                    action = 'approved-action-ran'
                    moduleCache = $moduleCache
                    moduleCacheExists = Test-Path -LiteralPath $moduleCache -PathType Container
                    moduleCacheEntryCount = @(Get-ChildItem -LiteralPath $moduleCache -Force).Count
                    buildCache = $buildCache
                    buildCacheExists = Test-Path -LiteralPath $buildCache -PathType Container
                    buildCacheEntryCount = @(Get-ChildItem -LiteralPath $buildCache -Force).Count
                    temporaryDirectory = $temporaryDirectory
                    binaryDirectory = $binaryDirectory
                }
            }
            Assert-Equal $result.action 'approved-action-ran' 'Approved Go environment must reach the action.'
            Assert-True ([bool]$result.moduleCacheExists) 'Approved Go resolution must provide an isolated module cache.'
            Assert-Equal $result.moduleCacheEntryCount 0 'The isolated Go module cache must be empty before resolution.'
            Assert-False (Test-Path -LiteralPath $result.moduleCache) 'The isolated Go module cache must be removed after resolution.'
            Assert-True ([bool]$result.buildCacheExists) 'Approved Go installation must provide an isolated build cache.'
            Assert-Equal $result.buildCacheEntryCount 0 'The isolated Go build cache must be empty before installation.'
            Assert-False (Test-Path -LiteralPath $result.buildCache) 'The isolated Go build cache must be removed after resolution.'
            Assert-False (Test-Path -LiteralPath $result.temporaryDirectory) 'The isolated Go temporary directory must be removed after resolution.'
            Assert-False (Test-Path -LiteralPath $result.binaryDirectory) 'The ephemeral Go binary directory must be removed after resolution.'

            $resolver = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
            Assert-Match $resolver '\$identity = "go:.*#moduleCache=\$\(' 'Resolved skill-validator identity must record module-cache isolation.'
            Assert-Match $resolver '#buildCache=\$\(' 'Resolved skill-validator identity must record build-cache isolation.'
            Assert-Match $resolver '#goflags=empty' 'Resolved skill-validator identity must record clean build flags.'
            Assert-Match $resolver '#goRuntime=\$goRuntimeVersion' 'Resolved skill-validator identity must bind the selected Go runtime version.'
            Assert-Match $resolver '#goRuntimeSource=\$trustedGoRuntimeSource' 'Resolved skill-validator identity must bind the official Go release metadata source.'
            Assert-Match $resolver ([regex]::Escape("Invoke-CheckedCommand -Command `$goCommand -Arguments @('version')")) 'The resolver must verify the native Go runtime before module resolution.'
            Assert-Match $resolver ([regex]::Escape("Invoke-CheckedCommand -Command `$goCommand -Arguments @('clean', '-cache', '-modcache')")) 'Run-owned Go caches must be cleaned through Go before their temporary root is removed.'
            Assert-Match $resolver '\$result\.goRuntimeVersion = \[string\]\$resolved\.goRuntimeVersion' 'The receipt must project the verified Go runtime version.'
            Assert-Match $resolver '\$result\.goRuntimeSource = \[string\]\$resolved\.goRuntimeSource' 'The receipt must project the official Go release metadata source.'
            Assert-Match $resolver 'ExpectedRuntimeVersion \$ExpectedGoRuntimeVersion' 'The resolver must compare native Go to the run-resolved latest stable runtime.'
            Assert-Match $resolver 'Get-OfficialLatestStableGoRuntimeVersion' 'The resolver must independently authenticate latest stable Go release metadata.'
            Assert-Match $resolver 'Invoke-WithApprovedGoWebTransport' 'Official Go release metadata must execute inside the approved web transport boundary.'
            Assert-Match $resolver 'DefaultWebProxy' 'Official Go release metadata must clear process-global proxy state.'
            Assert-Match $resolver 'ServerCertificateValidationCallback' 'Official Go release metadata must clear process-global certificate callback state.'
            Assert-Match $resolver 'CertificatePolicy' 'Windows PowerShell 5.1 official Go release authentication must clear legacy certificate policy state when that property exists.'
            Assert-Match $resolver "InvokeCommand\.GetCommand\(\s*'Invoke-WithApprovedGoWebTransport'[\s\S]*CommandTypes\]::Function" 'Official Go metadata retrieval must bind its transport boundary to the Function command type.'
            Assert-Match $resolver "InvokeCommand\.GetCommand\(\s*'Assert-NoConflictingGoTransportEnvironment'[\s\S]*CommandTypes\]::Function" 'Official Go metadata retrieval must bind its production transport environment boundary to the Function command type.'
            Assert-Match $resolver "InvokeCommand\.GetCommand\(\s*'Assert-GoTransportEnvironmentValues'[\s\S]*CommandTypes\]::Function" 'Go transport environment validation must bind its nested validator to the Function command type.'
            Assert-Match $resolver "InvokeCommand\.GetCommand\(\s*'Get-ApprovedGoRuntimeVersion'[\s\S]*CommandTypes\]::Function" 'The resolver must bind runtime evidence authentication to the Function command type.'
            $versionProbeIndex = $resolver.IndexOf("Invoke-CheckedCommand -Command `$goCommand -Arguments @('version')")
            $moduleLookupIndex = $resolver.IndexOf("Invoke-CheckedCommand -Command `$goCommand -Arguments @('list', '-m', '-json'")
            Assert-True ($versionProbeIndex -ge 0 -and $moduleLookupIndex -gt $versionProbeIndex) 'Go runtime verification must fail closed before module resolution can start.'
            Assert-NotMatch $resolver '\$metadata = @\(Microsoft\.PowerShell\.Utility\\Invoke-RestMethod' 'Official Go JSON arrays must be passed to the strict metadata parser without nesting the array as one entry.'

            $stableGoVersion = '1.99.8'
            $stableGoOutput = "go version go$stableGoVersion linux/amd64"
            $officialGoMetadata = @(
                [pscustomobject]@{ version = 'go1.99.7'; stable = $true }
                [pscustomobject]@{ version = 'go1.99.8'; stable = $true }
                [pscustomobject]@{ version = 'go1.100.0'; stable = $false }
            )
            Assert-Equal (Get-OfficialLatestStableGoRuntimeVersionFromMetadata -ReleaseMetadata $officialGoMetadata) $stableGoVersion 'The official Go metadata resolver must select the highest stable release and ignore prereleases.'
            Assert-Equal (Assert-ApprovedGoRuntimeEvidence -VersionOutput @($stableGoOutput) -ExpectedVersionRule 'latest-stable' -ExpectedRuntimeVersion $stableGoVersion -OfficialLatestStableVersion $stableGoVersion) $stableGoVersion 'A stable Go runtime independently selected for the run must be accepted.'
            foreach ($case in @(
                @{ Output=@(); Expected=$stableGoVersion; Pattern='ambiguous runtime-version evidence' },
                @{ Output=@($stableGoOutput, 'unexpected second line'); Expected=$stableGoVersion; Pattern='ambiguous runtime-version evidence' },
                @{ Output=@("go version devel go$stableGoVersion linux/amd64"); Expected=$stableGoVersion; Pattern='Unapproved Go runtime' },
                @{ Output=@("go version go${stableGoVersion}rc1 linux/amd64"); Expected=$stableGoVersion; Pattern='Unapproved Go runtime' },
                @{ Output=@('go version go1.99.7 linux/amd64'); Expected=$stableGoVersion; Pattern='does not match the independently authenticated latest stable Go runtime' },
                @{ Output=@('go version go1.99.7 linux/amd64'); Expected='1.99.7'; Pattern='caller-supplied Go runtime.*does not match the independently authenticated latest stable Go runtime' },
                @{ Output=@($stableGoOutput); Expected=''; Pattern='run-resolved latest stable Go runtime version is required' }
            )) {
                $runtimeError = $null
                try { Assert-ApprovedGoRuntimeEvidence -VersionOutput @($case.Output) -ExpectedVersionRule 'latest-stable' -ExpectedRuntimeVersion ([string]$case.Expected) -OfficialLatestStableVersion $stableGoVersion | Out-Null }
                catch { $runtimeError = $_.Exception.Message }
                Assert-Match $runtimeError ([string]$case.Pattern) 'Untrusted Go runtime evidence must fail closed.'
            }

            $malformedMetadataError = $null
            try {
                Get-OfficialLatestStableGoRuntimeVersionFromMetadata -ReleaseMetadata @([pscustomobject]@{ version = 'go1.99.8rc1'; stable = $true }) | Out-Null
            }
            catch { $malformedMetadataError = $_.Exception.Message }
            Assert-Match $malformedMetadataError 'marked.*as stable.*not a stable release version' 'Malformed official stable release metadata must fail closed.'

            $transportError = $null
            try {
                Assert-GoTransportEnvironmentValues -EnvironmentReader {
                    param([string] $Name)
                    if ($Name -ceq 'HTTPS_PROXY') { return 'https://attacker.invalid:8443' }
                    return ''
                }
            }
            catch { $transportError = $_.Exception.Message }
            Assert-Match $transportError 'Untrusted Go transport environment override.*HTTPS_PROXY' 'Official Go release authentication must reject caller-controlled proxy transport.'
            $resolverLines = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ResolverPath
            Assert-Match $resolverLines 'MaximumRedirection\s*=\s*0' 'Official Go release authentication must not follow an untrusted redirect.'
            Assert-Match $resolverLines 'NoProxy' 'PowerShell web transport must explicitly disable proxy use when the current cmdlet supports it.'

            $singleFileClosureRoot = Join-Path $TestDrive 'single-file-go-closure'
            [void](New-Item -ItemType Directory -Path $singleFileClosureRoot -Force)
            [IO.File]::WriteAllText(
                (Join-Path $singleFileClosureRoot 'skill-validator'),
                'fixture binary',
                (New-Object Text.UTF8Encoding($false))
            )
            $singleFileClosure = Get-DirectoryClosureIdentity -Path $singleFileClosureRoot
            $closureJson = [ordered]@{
                installed = (Get-DependencyClosureEntriesArray -Closure $singleFileClosure)
                unresolved = (Get-DependencyClosureEntriesArray -Closure $null)
            } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            Assert-True ($closureJson.installed -is [array]) 'A one-file installed closure must remain a JSON array instead of scalarizing to an object.'
            Assert-Equal @($closureJson.installed).Count 1 'A one-file installed closure must contain exactly one entry.'
            Assert-True ($closureJson.unresolved -is [array]) 'An unresolved closure must remain an empty JSON array.'
            Assert-Equal @($closureJson.unresolved).Count 0 'An unresolved closure must not contain an entry.'
            Assert-Equal ([regex]::Matches($resolver, 'dependencyClosure = \(Get-DependencyClosureEntriesArray -Closure \$').Count) 4 'Every resolver receipt must use the scalarization-safe closure-array helper.'
            Assert-Match $resolver '\$result\.moduleCacheIsolation = \[string\]\$resolved\.moduleCacheIsolation' 'The receipt must project module-cache isolation from the resolved installation.'
            Assert-Match $resolver '\$result\.buildCacheIsolation = \[string\]\$resolved\.buildCacheIsolation' 'The receipt must project build-cache isolation from the resolved installation.'
            Assert-Match $resolver 'binarySha256=\$executableSha256' 'The immutable skill-validator identity must include the installed binary hash.'
            Assert-Match $resolver 'executablePath = \$resolved\.executablePath' 'The receipt must expose the exact installed skill-validator executable.'
        }
        finally {
            foreach ($entry in $previous.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT30_validates_openai_agent_metadata_against_the_OpenAI_minimum_contract' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $standard 'agents/openai\.yaml.*contract' 'Standard must define an openai.yaml content contract.'
        Assert-Match $standard 'syntactically valid YAML' 'Standard must require valid YAML.'
        Assert-Match $standard 'YAML keys.*MUST.*unquoted' 'Standard must require unquoted YAML keys.'
        Assert-Match $standard 'all string scalar values.*MUST.*quoted' 'Standard must require quoted YAML string values.'
        Assert-Match $standard 'interface\.display_name' 'Standard must require display_name.'
        Assert-Match $standard 'interface\.short_description.*25.*64' 'Standard must require the OpenAI 25-64 character short_description bound.'
        Assert-Match $standard 'interface\.default_prompt' 'Standard must require default_prompt.'
        Assert-Match $standard '\$<skill-id>' 'Standard must bind default_prompt to the Skill ID.'
    }

    # Scenario: The two Standard schemas are edited without updating their strict semantic baselines.
    # Purpose: Protect the exact draft, fields, required sets, bounds, and extension policy consumed by source repositories.
    It 'UnitT35_keeps_the_source_inventory_and_OpenAI_metadata_schema_shapes_exact' {
        Assert-True (Test-Path -LiteralPath $script:SourceInventorySchemaPath -PathType Leaf) 'Missing source inventory v2 schema.'
        Assert-True (Test-Path -LiteralPath $script:OpenAiMetadataSchemaPath -PathType Leaf) 'Missing OpenAI agent metadata schema.'
        $sourceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:SourceInventorySchemaPath | ConvertFrom-Json
        $openAiSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:OpenAiMetadataSchemaPath | ConvertFrom-Json

        Assert-ExactPropertySet $sourceSchema @('$schema','title','description','type','additionalProperties','required','properties','$defs') 'Source inventory schema root must remain exact.'
        Assert-True ([string]$sourceSchema.'$schema' -ceq 'https://json-schema.org/draft/2020-12/schema') 'Source inventory must use the reviewed JSON Schema draft.'
        Assert-True ([string]$sourceSchema.type -ceq 'object') 'Source inventory root must be an object.'
        Assert-True ($sourceSchema.additionalProperties -is [bool] -and -not [bool]$sourceSchema.additionalProperties) 'Source inventory root must reject unknown fields.'
        Assert-ExactStringSequence $sourceSchema.required @('schemaVersion','sourceId','repository','skillsRoot','skills') 'Source inventory required fields must remain exact and ordered.'
        Assert-ExactPropertySet $sourceSchema.properties @('schemaVersion','sourceId','repository','skillsRoot','skills') 'Source inventory properties must remain exact.'
        Assert-Equal $sourceSchema.properties.schemaVersion.const 2 'Source inventory must require schemaVersion 2.'
        Assert-True ([string]$sourceSchema.properties.sourceId.'$ref' -ceq '#/$defs/stableId') 'sourceId must use the stable-ID definition.'
        Assert-True ([string]$sourceSchema.properties.repository.type -ceq 'string') 'repository must remain a string.'
        Assert-True ([string]$sourceSchema.properties.repository.pattern -ceq '^https://github\.com/[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]+\.git$') 'repository must retain the canonical GitHub HTTPS clone grammar.'
        Assert-True ([string]$sourceSchema.properties.skillsRoot.const -ceq 'skills') 'skillsRoot must remain the exact canonical directory.'
        Assert-ExactPropertySet $sourceSchema.properties.skills @('type','minItems','uniqueItems','items') 'skills array constraints must remain exact.'
        Assert-True ([string]$sourceSchema.properties.skills.type -ceq 'array') 'skills must remain an array.'
        Assert-Equal $sourceSchema.properties.skills.minItems 1 'Source inventory must contain at least one Skill.'
        Assert-True ($sourceSchema.properties.skills.uniqueItems -is [bool] -and [bool]$sourceSchema.properties.skills.uniqueItems) 'Source inventory must reject duplicate Skills.'
        Assert-True ([string]$sourceSchema.properties.skills.items.'$ref' -ceq '#/$defs/stableId') 'Every Skill inventory item must use the stable-ID definition.'
        Assert-ExactPropertySet $sourceSchema.'$defs' @('stableId') 'Source inventory definitions must remain exact.'
        Assert-ExactPropertySet $sourceSchema.'$defs'.stableId @('type','minLength','maxLength','pattern') 'Stable-ID constraints must remain exact.'
        Assert-True ([string]$sourceSchema.'$defs'.stableId.type -ceq 'string') 'Stable IDs must remain strings.'
        Assert-Equal $sourceSchema.'$defs'.stableId.minLength 1 'Stable IDs must not be empty.'
        Assert-Equal $sourceSchema.'$defs'.stableId.maxLength 64 'Stable IDs must retain the 64-character bound.'
        Assert-True ([string]$sourceSchema.'$defs'.stableId.pattern -ceq '^[a-z0-9]+(?:-[a-z0-9]+)*$') 'Stable IDs must retain their lexical grammar.'

        Assert-ExactPropertySet $openAiSchema @('$schema','title','description','type','required','properties','additionalProperties') 'OpenAI metadata schema root must remain exact.'
        Assert-True ([string]$openAiSchema.'$schema' -ceq 'https://json-schema.org/draft/2020-12/schema') 'OpenAI metadata must use the reviewed JSON Schema draft.'
        Assert-True ([string]$openAiSchema.type -ceq 'object') 'OpenAI metadata root must be an object.'
        Assert-ExactStringSequence $openAiSchema.required @('interface') 'OpenAI metadata must require interface.'
        Assert-ExactPropertySet $openAiSchema.properties @('interface','dependencies') 'OpenAI metadata root properties must remain exact.'
        Assert-True ($openAiSchema.additionalProperties -is [bool] -and [bool]$openAiSchema.additionalProperties) 'Host-specific OpenAI root metadata must remain extensible.'

        $interfaceSchema = $openAiSchema.properties.interface
        Assert-ExactPropertySet $interfaceSchema @('type','required','properties','additionalProperties') 'OpenAI interface schema must remain exact.'
        Assert-ExactStringSequence $interfaceSchema.required @('display_name','short_description','default_prompt') 'OpenAI interface required fields must remain exact.'
        Assert-ExactPropertySet $interfaceSchema.properties @('display_name','short_description','icon_small','icon_large','brand_color','default_prompt') 'OpenAI interface properties must remain exact.'
        Assert-True ($interfaceSchema.additionalProperties -is [bool] -and [bool]$interfaceSchema.additionalProperties) 'Optional host interface metadata must remain extensible.'
        Assert-Equal $interfaceSchema.properties.short_description.minLength 25 'short_description must retain its lower bound.'
        Assert-Equal $interfaceSchema.properties.short_description.maxLength 64 'short_description must retain its upper bound.'
        Assert-True ([string]$interfaceSchema.properties.icon_small.pattern -ceq '^\./assets/[^\r\n]+$') 'Small icons must remain package-relative assets.'
        Assert-True ([string]$interfaceSchema.properties.icon_large.pattern -ceq '^\./assets/[^\r\n]+$') 'Large icons must remain package-relative assets.'
        Assert-True ([string]$interfaceSchema.properties.brand_color.pattern -ceq '^#[0-9A-Fa-f]{6}$') 'Brand colors must remain six-digit hex values.'
        Assert-True ([string]$interfaceSchema.properties.default_prompt.pattern -ceq '[\s\S]*\$[a-z0-9]+(?:-[a-z0-9]+)*[\s\S]*') 'default_prompt must contain a lexical Skill token.'

        $dependenciesSchema = $openAiSchema.properties.dependencies
        Assert-ExactPropertySet $dependenciesSchema @('type','properties','additionalProperties') 'OpenAI dependency schema must remain exact.'
        Assert-ExactPropertySet $dependenciesSchema.properties @('tools') 'Only tools have a Standard semantic dependency baseline.'
        Assert-True ($dependenciesSchema.additionalProperties -is [bool] -and [bool]$dependenciesSchema.additionalProperties) 'Optional dependency metadata must remain extensible.'
        $toolsSchema = $dependenciesSchema.properties.tools
        Assert-ExactPropertySet $toolsSchema @('type','minItems','items') 'OpenAI tools array constraints must remain exact.'
        Assert-Equal $toolsSchema.minItems 1 'An explicit tools array must not be empty.'
        Assert-ExactPropertySet $toolsSchema.items @('type','additionalProperties','required','properties') 'OpenAI dependency item schema must remain exact.'
        Assert-True ($toolsSchema.items.additionalProperties -is [bool] -and -not [bool]$toolsSchema.items.additionalProperties) 'Unknown dependency tool fields must fail closed.'
        Assert-ExactStringSequence $toolsSchema.items.required @('type','value') 'OpenAI dependency tools must require type and value.'
        Assert-ExactPropertySet $toolsSchema.items.properties @('type','value','description','transport','url') 'OpenAI dependency tool properties must remain exact.'
        Assert-True ([string]$toolsSchema.items.properties.type.const -ceq 'mcp') 'Standard v1 dependency tools must remain MCP dependencies.'
        Assert-True ([string]$toolsSchema.items.properties.url.format -ceq 'uri') 'Dependency URLs must remain URI-formatted.'
        Assert-True ([string]$toolsSchema.items.properties.url.pattern -ceq '^https://[^\s/?#]+(?:[/?#][^\s]*)?$') 'Dependency URLs must remain absolute HTTPS URIs.'
    }

    # Scenario: Source inventory documents use legacy shape, unknown fields, unsafe lexical identities, or drift from package directories.
    # Purpose: Exercise schema v2 plus the executable sort and authority-binding rules that JSON Schema cannot express.
    It 'UnitT36_rejects_invalid_unsorted_or_identity_mismatched_source_inventories' {
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:SourceInventorySchemaPath | ConvertFrom-Json
        $valid = [pscustomobject][ordered]@{
            schemaVersion=2
            sourceId='example-source'
            repository='https://github.com/example/example-source.git'
            skillsRoot='skills'
            skills=[object[]]@('alpha-skill','zeta-skill')
        }
        Assert-AuthoritySchemaInstance -Value $valid -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'Canonical source inventory must be schema-valid.'
        Assert-True (Test-SourceInventoryExecutableContract -Inventory $valid -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('zeta-skill','alpha-skill')) 'Canonical inventory must bind the expected source, repository, sort order, and package directories.'

        $invalidCases = @(
            @{ Name='legacy-version'; Mutate={ param($item) $item.schemaVersion=1 } },
            @{ Name='string-version'; Mutate={ param($item) $item.schemaVersion='2' } },
            @{ Name='unknown-root-field'; Mutate={ param($item) $item | Add-Member -NotePropertyName profiles -NotePropertyValue @('default') } },
            @{ Name='uppercase-source-id'; Mutate={ param($item) $item.sourceId='Example-Source' } },
            @{ Name='leading-hyphen-source-id'; Mutate={ param($item) $item.sourceId='-example-source' } },
            @{ Name='double-hyphen-source-id'; Mutate={ param($item) $item.sourceId='example--source' } },
            @{ Name='overlong-source-id'; Mutate={ param($item) $item.sourceId=('a' * 65) } },
            @{ Name='credentialed-repository'; Mutate={ param($item) $item.repository='https://token@github.com/example/example-source.git' } },
            @{ Name='repository-query'; Mutate={ param($item) $item.repository='https://github.com/example/example-source.git?ref=main' } },
            @{ Name='missing-dot-git'; Mutate={ param($item) $item.repository='https://github.com/example/example-source' } },
            @{ Name='wrong-skills-root'; Mutate={ param($item) $item.skillsRoot='src/skills' } },
            @{ Name='empty-skills'; Mutate={ param($item) $item.skills=[object[]]@() } },
            @{ Name='duplicate-skills'; Mutate={ param($item) $item.skills=[object[]]@('alpha-skill','alpha-skill') } },
            @{ Name='legacy-object-skills'; Mutate={ param($item) $item.skills=[object[]]@([pscustomobject]@{ id='alpha-skill'; path='skills/alpha-skill' }) } }
        )
        foreach ($case in $invalidCases) {
            $inventory = Copy-TestJsonObject -Value $valid
            & $case.Mutate $inventory
            Assert-AuthoritySchemaInstance -Value $inventory -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $false -Message "Invalid source inventory '$($case.Name)' must fail schema validation."
        }

        $unsorted = Copy-TestJsonObject -Value $valid
        $unsorted.skills = [object[]]@('zeta-skill','alpha-skill')
        Assert-AuthoritySchemaInstance -Value $unsorted -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'Sort order is intentionally an executable cross-document rule.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $unsorted -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill','zeta-skill')) 'Non-ordinal inventory order must fail the executable contract.'

        $wrongSource = Copy-TestJsonObject -Value $valid
        $wrongSource.sourceId = 'other-source'
        Assert-AuthoritySchemaInstance -Value $wrongSource -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'A different lexical source ID is valid only before authority binding.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $wrongSource -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill','zeta-skill')) 'A different valid source ID must fail exact authority binding.'

        $wrongRepository = Copy-TestJsonObject -Value $valid
        $wrongRepository.repository = 'https://github.com/example/other-source.git'
        Assert-AuthoritySchemaInstance -Value $wrongRepository -Schema $schema -SchemaPath $script:SourceInventorySchemaPath -Expected $true -Message 'A different canonical repository is valid only before authority binding.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $wrongRepository -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill','zeta-skill')) 'A different valid repository must fail exact authority binding.'
        Assert-False (Test-SourceInventoryExecutableContract -Inventory $valid -ExpectedSourceId 'example-source' -ExpectedRepository 'https://github.com/example/example-source.git' -PackageDirectoryNames @('alpha-skill')) 'Declared inventory and actual package directories must be equal.'
    }

    # Scenario: Parsed OpenAI metadata contains wrong types, bounds, dependency fields, or only a different valid Skill token.
    # Purpose: Distinguish semantic schema validation from the fixture validator's exact YAML lexical and identity checks.
    It 'UnitT37_validates_OpenAI_metadata_semantics_without_overclaiming_lexical_identity' {
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:OpenAiMetadataSchemaPath | ConvertFrom-Json
        $valid = [pscustomobject][ordered]@{
            interface=[pscustomobject][ordered]@{
                display_name='Standard Validation Fixture'
                short_description='Validate one deterministic canonical Skill package.'
                icon_small='./assets/icon-small.svg'
                icon_large='./assets/icon-large.png'
                brand_color='#0A84FF'
                default_prompt='Use $standard-validation-fixture to validate this package.'
            }
            dependencies=[pscustomobject][ordered]@{
                tools=[object[]]@(
                    [pscustomobject][ordered]@{ type='mcp'; value='github'; description='GitHub connector'; transport='streamable-http'; url='https://example.invalid/mcp' }
                )
            }
        }
        Assert-AuthoritySchemaInstance -Value $valid -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $true -Message 'Canonical parsed OpenAI metadata must be schema-valid.'

        $rootExtension = Copy-TestJsonObject -Value $valid
        $rootExtension | Add-Member -NotePropertyName host_extension -NotePropertyValue 'allowed'
        $rootExtension.interface | Add-Member -NotePropertyName host_hint -NotePropertyValue 'allowed'
        Assert-AuthoritySchemaInstance -Value $rootExtension -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $true -Message 'Reviewed host extension points must remain schema-valid.'

        $invalidCases = @(
            @{ Name='missing-interface'; Mutate={ param($item) $item.PSObject.Properties.Remove('interface') } },
            @{ Name='numeric-display-name'; Mutate={ param($item) $item.interface.display_name=7 } },
            @{ Name='short-description-underflow'; Mutate={ param($item) $item.interface.short_description=('a' * 24) } },
            @{ Name='short-description-overflow'; Mutate={ param($item) $item.interface.short_description=('a' * 65) } },
            @{ Name='prompt-without-skill-token'; Mutate={ param($item) $item.interface.default_prompt='Validate this package.' } },
            @{ Name='unsafe-small-icon'; Mutate={ param($item) $item.interface.icon_small='../icon.svg' } },
            @{ Name='invalid-brand-color'; Mutate={ param($item) $item.interface.brand_color='#12345G' } },
            @{ Name='wrong-tool-type'; Mutate={ param($item) $item.dependencies.tools[0].type='http' } },
            @{ Name='empty-tool-value'; Mutate={ param($item) $item.dependencies.tools[0].value='' } },
            @{ Name='non-HTTPS-tool-url'; Mutate={ param($item) $item.dependencies.tools[0].url='http://example.invalid/mcp' } },
            @{ Name='unknown-tool-field'; Mutate={ param($item) $item.dependencies.tools[0] | Add-Member -NotePropertyName command -NotePropertyValue 'forbidden' } }
        )
        foreach ($case in $invalidCases) {
            $metadata = Copy-TestJsonObject -Value $valid
            & $case.Mutate $metadata
            Assert-AuthoritySchemaInstance -Value $metadata -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $false -Message "Invalid OpenAI metadata '$($case.Name)' must fail semantic schema validation."
        }

        $differentToken = Copy-TestJsonObject -Value $valid
        $differentToken.interface.default_prompt = 'Use $other-fixture to validate this package.'
        Assert-AuthoritySchemaInstance -Value $differentToken -Schema $schema -SchemaPath $script:OpenAiMetadataSchemaPath -Expected $true -Message 'JSON Schema validates token grammar, not exact package identity.'
        $schemaDescription = [string]$schema.description
        Assert-Match $schemaDescription 'exact \$<skill-id> binding.*YAML-aware checks' 'Schema documentation must assign exact lexical identity binding to the YAML-aware validator.'
    }

    # Scenario: A valid package includes a script that upstream intentionally omits from token accounting.
    # Purpose: Bind the whole input with hashes without mistaking token statistics for per-file analysis coverage.
    It 'UnitT38_binds_script_inputs_without_requiring_script_token_counts' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $fixture = New-TestAuthorityFixture -Root (Join-Path $TestDrive 'package-input-fixture')
        Write-TestUtf8File -Path (Join-Path $fixture.Root 'scripts/run.ps1') -Text "Write-Output 'fixture'`n"
        $inventory = @('SKILL.md', 'agents/openai.yaml', 'scripts/run.ps1')
        $report = [pscustomobject]@{
            skill_dir=$fixture.Root; passed=$true; errors=0; warnings=0
            results=@([pscustomobject]@{ level='pass'; category='structure'; message='Package structure is valid.' })
            token_counts=[pscustomobject]@{ files=@([pscustomobject]@{ file='SKILL.md body'; tokens=1 }); total=1 }
            other_token_counts=[pscustomobject]@{ files=@([pscustomobject]@{ file='agents/openai.yaml'; tokens=1 }); total=1 }
        }
        Assert-AuthoritySkillValidatorReport -Report $report -ExpectedFixtureRoot $fixture.Root -ExpectedInventoryPaths $inventory -ExpectedTokenPaths @('SKILL.md') -ExpectedOtherTokenPaths @('agents/openai.yaml')
        # Scenario: A clean-looking native report omits the token table for required metadata.
        # Purpose: Input hashes must not substitute for the validator's token-accounted file evidence.
        $missingMetadataReport = Copy-TestJsonObject $report
        $missingMetadataReport.PSObject.Properties.Remove('other_token_counts')
        $errorMessage = $null
        try { Assert-AuthoritySkillValidatorReport -Report $missingMetadataReport -ExpectedFixtureRoot $fixture.Root -ExpectedInventoryPaths $inventory -ExpectedTokenPaths @('SKILL.md') -ExpectedOtherTokenPaths @('agents/openai.yaml') }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'token-accounted inventory' 'The report must include every known token-eligible input.'
        foreach ($reportCase in @('wrong-table', 'unexpected-script')) {
            $wrongTokenReport = Copy-TestJsonObject $report
            if ($reportCase -ceq 'wrong-table') {
                # The union still contains both files, but their native table identities are wrong.
                $wrongTokenReport.token_counts.files[0].file = 'agents/openai.yaml'
                $wrongTokenReport.other_token_counts.files[0].file = 'SKILL.md body'
            }
            else {
                $wrongTokenReport.other_token_counts.files += [pscustomobject]@{ file='scripts/run.ps1'; tokens=1 }
                $wrongTokenReport.other_token_counts.total = 2
            }
            $errorMessage = $null
            try { Assert-AuthoritySkillValidatorReport -Report $wrongTokenReport -ExpectedFixtureRoot $fixture.Root -ExpectedInventoryPaths $inventory -ExpectedTokenPaths @('SKILL.md') -ExpectedOtherTokenPaths @('agents/openai.yaml') }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'token-accounted inventory' 'Each native table must match its known eligible inputs.'
        }
        $baseline = [pscustomobject][ordered]@{
            schemaVersion=1; toolName='skill-validator'; coverageMode='authority-input-inventory'; root=$fixture.Root
            files=@($inventory | ForEach-Object {
                [pscustomobject][ordered]@{ path=$_; sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fixture.Root $_)).Hash.ToLowerInvariant() }
            })
        }
        Assert-AuthorityToolInputInventory -Envelope $baseline -ExpectedToolName 'skill-validator' -ExpectedFixtureRoot $fixture.Root -ExpectedInventoryPaths $inventory
        $cases = @(
            @{ Mutate={ param($e) $e.PSObject.Properties.Remove('files') } },
            @{ Mutate={ param($e) $e.files=@($e.files[0], $e.files[1]) } },
            @{ Mutate={ param($e) $e.files += [pscustomobject]@{ path='unexpected.txt'; sha256=('0' * 64) } } },
            @{ Mutate={ param($e) $e.files += $e.files[0] } },
            @{ Mutate={ param($e) $e.files[2].path='../outside.ps1' } },
            @{ Mutate={ param($e) $e.files[2].sha256='invalid' } },
            @{ Mutate={ param($e) $e.files[2].sha256=('0' * 64) } },
            @{ Mutate={ param($e) $e.toolName='skill-tools' } },
            @{ Mutate={ param($e) $e.coverageMode='token-counts' } },
            @{ Mutate={ param($e) $e.root=(Split-Path -Parent $fixture.Root) } },
            @{ Mutate={ param($e) $e.schemaVersion='1' } },
            @{ Mutate={ param($e) $e.files[2] | Add-Member -NotePropertyName ignored -NotePropertyValue $true } }
        )
        foreach ($case in $cases) {
            $envelope = Copy-TestJsonObject $baseline
            & $case.Mutate $envelope
            $errorMessage = $null
            try { Assert-AuthorityToolInputInventory -Envelope $envelope -ExpectedToolName 'skill-validator' -ExpectedFixtureRoot $fixture.Root -ExpectedInventoryPaths $inventory }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'skill-validator coverage envelope' 'Input identity and exact file hashes must fail closed on envelope drift.'
        }

        # Scenario: An unrecorded regular file appears in the input directory after capture.
        # Purpose: Ensure the envelope binds the actual complete input, not only the listed files.
        $extraPath = Join-Path $fixture.Root 'unexpected.txt'
        Write-TestUtf8File -Path $extraPath -Text 'unexpected fixture file'
        try {
            $errorMessage = $null
            try { Assert-AuthorityToolInputInventory -Envelope $baseline -ExpectedToolName 'skill-validator' -ExpectedFixtureRoot $fixture.Root -ExpectedInventoryPaths $inventory }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'exact expected inventory' 'Unrecorded input files must fail closed.'
        }
        finally { Remove-Item -LiteralPath $extraPath -Force }

        # Scenario: A script changes after the native tool ran while the captured envelope stays unchanged.
        # Purpose: Reject stale input evidence even when the native report remains clean.
        Write-TestUtf8File -Path (Join-Path $fixture.Root 'scripts/run.ps1') -Text "Write-Output 'changed fixture'`n"
        $errorMessage = $null
        try { Assert-AuthorityToolInputInventory -Envelope $baseline -ExpectedToolName 'skill-validator' -ExpectedFixtureRoot $fixture.Root -ExpectedInventoryPaths $inventory }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'changed after the tool run' 'Post-run input verification must reject a modified script.'
    }

    It 'UnitT40_distinguishes_release_approval_from_installing_an_already_approved_release' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $standard 'Release Approval' 'Standard must define release approval.'
        Assert-Match $standard 'Approved Release Installation' 'Standard must define approved release installation.'
        Assert-Match $standard 'Human Approved.*MUST NOT.*human approval' 'Installing an approved immutable release must not require repeated release approval.'
    }

    It 'UnitT50_makes_standard_conformance_tests_effective_in_the_same_policy_change' {
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath

        Assert-Match $standard 'normative authority.*conformance regression.*MUST.*PR' 'Standard changes must update authority regression in the same PR.'
        Assert-Match $index 'tests/skill-repository-standard\.Tests\.ps1' 'Standards index must name the authority regression test.'
        Assert-Match $standard 'trusted supervisor.*fresh validation run ID at invocation start' 'The Standard must bind resolver receipts to the current trusted-supervisor launch.'
        Assert-Match $standard 'validation-launch-binding-v1' 'The Standard must define the signed supervisor launch-binding contract.'
        Assert-Match $standard 'pass the same ID to the resolution orchestration.*before' 'The Standard must require the resolver to receive the supervisor run ID before receipt creation.'
        Assert-Match $standard 'consumptionPath.*outside.*candidate.*artifact.*trusted-tool.*roots' 'The Standard must require an authenticated one-time launch-binding consumption path outside caller-controlled roots.'
        Assert-Match $standard 'atomically create a supervisor-owned create-only consumption marker.*reject an existing marker' 'The Standard must reject launch-binding replay after artifact-root recreation.'
        Assert-Match $standard 'revalidate its file hash before and after every child process' 'The Standard must revalidate the launch binding around child execution.'
        Assert-Match $standard '1,048,576 characters' 'The Standard must define a fixed child-output memory quota.'
        Assert-Match $standard 'record the overflow diagnostic separately' 'The Standard must keep overflow diagnostics outside bounded stream prefixes.'
        Assert-Match $standard 'MUST NOT.*unbounded `ReadToEnd` capture' 'The Standard must prohibit unbounded child-output capture.'
    }

    It 'UnitT60_keeps_the_review_matrix_current_with_the_SYP167_authority_deliverables' {
        $matrix = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:MatrixPath
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath

        Assert-Match $matrix 'Validation tool policy' 'Review matrix must record the validation tool policy decision.'
        Assert-Match $matrix 'latest stable' 'Review matrix must record latest-stable validation tooling.'
        Assert-Match $matrix 'authority-level regression' 'Review matrix must record SYP-167 authority regression/CI deliverables.'
        Assert-Match $matrix 'proxy.golang.org' 'Review matrix must record the approved Go module proxy.'
        Assert-Match $matrix 'sum.golang.org' 'Review matrix must record the approved Go checksum database.'
        Assert-Match $matrix 'GOCACHE' 'Review matrix must record isolated Go build-cache enforcement.'
        Assert-Match $matrix 'GOFLAGS' 'Review matrix must record clean Go build flags.'
        Assert-Match $matrix 'pypi.org/simple' 'Review matrix must record the approved Python package index.'
        Assert-Match $matrix 'Python `-I` isolated mode' 'Review matrix must record inherited Python interpreter isolation.'
        Assert-Match $matrix 'direct references' 'Review matrix must record direct-reference blocking.'
        Assert-Match $matrix 'every candidate before pip can inspect it' 'Review matrix must record candidate direct-reference rejection before offline pip can inspect it.'
        Assert-NotMatch $matrix 'post-materialization' 'Review matrix must not retain the obsolete online-pip post-materialization model.'
        Assert-NotMatch $standard 'post-materialization' 'Normative Standard must not retain the obsolete online-pip post-materialization model.'
        Assert-Match $standard 'MUST NOT.*installed interpreter.*\.pth' 'Normative Standard must require static installed-metadata verification before Python startup processing.'
        Assert-NotMatch $standard 'exact security-patched Go runtime' 'Normative Standard must not require a fixed Go patch version after adopting latest-stable resolution.'
        Assert-Match $standard 'go-version: stable.*check-latest: true.*latest-stable Go runtime' 'Normative Standard must require the run-resolved latest-stable Go runtime.'
        Assert-Match $matrix 'persist-credentials' 'Review matrix must record CI checkout credential isolation.'
        Assert-Match $matrix 'wheelhouse' 'Review matrix must record hash-locked SkillSpector dependency acquisition.'
        Assert-NotMatch $matrix 'SYP-167 establishes normative Standard v1 only\.' 'Review matrix must not describe the pre-regression SYP-167 scope.'
    }

    Context 'SYP325 central validation ownership documentation' {
    # Scenario: Central validation ownership or its required CI gate is undocumented or drifts from the v2 contracts.
    # Purpose: Keep the implementation-to-test map explicit while preserving the existing adapter/result and testOwnership schemas.
    It 'UnitT110_documents_central_validation_owners_tests_and_windows_gate' {
        $standard=Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        foreach($required in @(
            '12.3 Central reference implementation ownership and CI',
            'scripts/Invoke-StandardValidation.ps1',
            'tests/skill-repository-standard.Tests.ps1',
            'tests/standard-validation-runner.Tests.ps1',
            'tests/standard-core-pester-adapter.Tests.ps1',
            'scripts/Resolve-StandardValidationTool.ps1',
            'tests/standard-validation-resolver-hardening.Tests.ps1',
            'scripts/Invoke-StandardAuthorityGate.ps1',
            'docs/standards/validation-security-gate.json',
            '.github/workflows/pr8-powershell-validation.yml',
            'tests/skill-repository-workflows.Tests.ps1',
            'Windows Core', 'ExpectedSkippedCount = 5', 'standards-conformance.yml',
            'schema v2', 'testOwnership', 'unknown schema or ownership values',
            'SourceValidation execution remains owned by the central source-validation function',
            'scripts/Invoke-RepositoryCheck.ps1', 'scripts/Invoke-CorePester.ps1',
            'scripts/CorePesterIntegrity.psm1', 'scripts/Test-Repository.ps1', 'tests/validate-catalog.ps1',
            'candidate==base bytes', 'full discovered tests tree', 'normal reader PR', 'before candidate adoption',
            'A pin or immutable version update alone MUST NOT transfer ownership',
            'Source-copy equivalence or removal is deferred to downstream adoption',
            'identified item by item', 'normal required Windows Core CI gate', 'SYP-325 changes none of the Code trial paths above',
            'This list records the Code trial', 'not a universal file inventory', 'Each source repository MUST retain its own protected reader identities'
        )) { if(-not $standard.Contains($required)){throw "Central validation ownership contract is missing '$required'."} }
    }
    }

    # Scenario: The managed lifecycle contract or its machine-readable evidence schema is removed or detached from the central authority.
    # Purpose: Bind SYP-194 ownership, migration, rollback, and post-install semantics to Standard v1 regression coverage.
    It 'UnitT70_binds_managed_lifecycle_to_the_central_standard_authority' {
        Assert-True (Test-Path -LiteralPath $script:LifecyclePath -PathType Leaf) 'Managed lifecycle contract is missing from the central standards directory.'
        Assert-True (Test-Path -LiteralPath $script:LifecycleSchemaPath -PathType Leaf) 'Managed lifecycle evidence schema is missing from the central standards directory.'
        $lifecycle = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:LifecyclePath
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:LifecycleSchemaPath | ConvertFrom-Json
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $matrix = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:MatrixPath

        Assert-Match $index 'managed-skill-lifecycle\.md' 'Standards index must expose the managed lifecycle contract.'
        Assert-Match $index 'managed-skill-lifecycle-v1\.schema\.json' 'Standards index must expose the managed lifecycle evidence schema.'
        Assert-Match $standard 'managed-skill-lifecycle\.md' 'Normative Standard must bind the detailed managed lifecycle contract.'
        Assert-Match $matrix 'Managed lifecycle / legacy migration' 'Cross-repository matrix must record the SYP-194 lifecycle boundary.'
        Assert-Match $lifecycle 'Managed drift' 'Lifecycle contract must distinguish managed drift from clean ownership.'
        Assert-Match $lifecycle 'known-legacy' 'Lifecycle contract must define explicit known-legacy adoption.'
        Assert-Match $lifecycle 'unmanaged-unknown' 'Lifecycle contract must preserve unknown ownership and block collisions.'
        Assert-Match $lifecycle 'transaction-owned staged snapshot' 'Lifecycle contract must prevent mutable staging TOCTOU writes.'
        Assert-Match $lifecycle 'post-install' 'Lifecycle contract must require post-install verification.'
        Assert-Equal $schema.title 'Managed Skill lifecycle evidence v1' 'Lifecycle evidence schema title must remain bound to v1.'
        Assert-Equal @($schema.oneOf).Count 4 'Lifecycle evidence schema must distinguish ownership, failure, current transaction journal, and legacy transaction journal records.'
        $schemaReferences = @($schema.oneOf | ForEach-Object { [string]$_.PSObject.Properties['$ref'].Value })
        Assert-True ($schemaReferences -ccontains '#/$defs/ownershipEvidence') 'Lifecycle evidence schema must expose ownership records.'
        Assert-True ($schemaReferences -ccontains '#/$defs/failureDetail') 'Lifecycle evidence schema must expose failure records.'
        Assert-True ($schemaReferences -ccontains '#/$defs/transactionJournal') 'Lifecycle evidence schema must expose transaction journals.'
        Assert-True ($schemaReferences -ccontains '#/$defs/legacyTransactionJournal') 'Lifecycle evidence schema must expose the predecessor transaction journal shape for upgrade recovery.'
        Assert-Equal $schema.'$defs'.transactionJournal.properties.desiredManifestSha256.'$ref' '#/$defs/requiredSha256' 'Transaction journals must require a non-null desired manifest SHA-256.'
        Assert-Equal $schema.'$defs'.transactionJournal.properties.desiredInventorySha256.'$ref' '#/$defs/requiredSha256' 'Transaction journals must require a non-null desired inventory SHA-256.'
        Assert-Equal $schema.'$defs'.requiredSha256.type 'string' 'Required transaction SHA-256 values must reject null.'
        Assert-True (@($schema.'$defs'.failureDetail.required) -ccontains 'remediation') 'Failure evidence must require remediation.'
        Assert-True (@($schema.'$defs'.failureDetail.required) -ccontains 'destructiveChangeAllowed') 'Failure evidence must require destructive-change authorization state.'
    }

    # Scenario: Transaction state and rejected-candidate evidence must be accepted by the central schema exactly when runtime invariants hold.
    # Purpose: Prevent adapters from accepting recovery metadata or failure paths that the reference reconciler rejects.
    It 'UnitT75_enforces_lifecycle_transaction_state_and_failure_path_contract' {
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:LifecycleSchemaPath | ConvertFrom-Json
        $schemaPath = $script:LifecycleSchemaPath
        $existingState = [pscustomobject][ordered]@{
            relativePath='.agents/skills/alpha/SKILL.md'; existed=$true
            backupPath='C:\Users\fixture\.agents\backups\tx\.agents\skills\alpha\SKILL.md'
            originalSha256=('c' * 64); backupSha256=('c' * 64); appliedSha256=('d' * 64)
        }
        $journal = [pscustomobject][ordered]@{
            schemaVersion=1; transactionId=('a' * 32); userHome='C:\Users\fixture'
            backupPath='C:\Users\fixture\.agents\backups\tx'; phase='mutating'
            desiredManifestSha256=('a' * 64); desiredInventorySha256=('b' * 64)
            states=@($existingState)
        }
        Assert-AuthoritySchemaInstance -Value $journal -Schema $schema -SchemaPath $schemaPath -Expected $true -Message 'A pre-existing target with complete backup metadata must validate.'

        $legacyJournal = [pscustomobject][ordered]@{
            schemaVersion=1; userHome='C:\Users\fixture'
            backupPath='C:\Users\fixture\.agents\backups\tx'
            states=@([pscustomobject][ordered]@{
                relativePath='.agents/skills/alpha/SKILL.md'; existed=$true
                backupPath='C:\Users\fixture\.agents\backups\tx\.agents\skills\alpha\SKILL.md'
                originalSha256=('c' * 64); appliedSha256=('d' * 64)
            })
        }
        Assert-AuthoritySchemaInstance -Value $legacyJournal -Schema $schema -SchemaPath $schemaPath -Expected $true -Message 'The predecessor v1 recovery journal shape must remain recoverable after runtime upgrade.'

        $legacyOutsideScope = Copy-TestJsonObject $legacyJournal
        $legacyOutsideScope.states[0].relativePath = 'outside/product.txt'
        Assert-AuthoritySchemaInstance -Value $legacyOutsideScope -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'A legacy transaction journal must reject a state outside the managed consumer scope.'

        $outsideScope = Copy-TestJsonObject $journal
        $outsideScope.states[0].relativePath = 'outside/product.txt'
        Assert-AuthoritySchemaInstance -Value $outsideScope -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'A current transaction journal must reject a state outside the managed consumer scope.'

        $journalWithWhitespaceBackupPath = Copy-TestJsonObject $journal
        $journalWithWhitespaceBackupPath.backupPath = '   '
        Assert-AuthoritySchemaInstance -Value $journalWithWhitespaceBackupPath -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'A transaction journal with a whitespace-only backup path must fail closed.'

        $journalWithNextLineBackupPath = Copy-TestJsonObject $journal
        $journalWithNextLineBackupPath.backupPath = [string][char]0x0085
        Assert-AuthoritySchemaInstance -Value $journalWithNextLineBackupPath -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'A transaction journal with a U+0085 whitespace-only backup path must fail closed.'

        $absentJournal = Copy-TestJsonObject $journal
        $absentJournal.states = @([pscustomobject][ordered]@{
            relativePath='.agents/skills/beta/SKILL.md'; existed=$false
            backupPath=$null; originalSha256=$null; backupSha256=$null; appliedSha256=('d' * 64)
        })
        Assert-AuthoritySchemaInstance -Value $absentJournal -Schema $schema -SchemaPath $schemaPath -Expected $true -Message 'A previously absent target with null backup metadata must validate.'

        $existingWithoutBackup = Copy-TestJsonObject $journal
        $existingWithoutBackup.states[0].backupPath = $null
        Assert-AuthoritySchemaInstance -Value $existingWithoutBackup -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An existing target without backup metadata must fail closed.'

        $existingWithWhitespaceBackupPath = Copy-TestJsonObject $journal
        $existingWithWhitespaceBackupPath.states[0].backupPath = '   '
        Assert-AuthoritySchemaInstance -Value $existingWithWhitespaceBackupPath -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An existing target with a whitespace-only backup path must fail closed.'

        $existingWithNextLineBackupPath = Copy-TestJsonObject $journal
        $existingWithNextLineBackupPath.states[0].backupPath = [string][char]0x0085
        Assert-AuthoritySchemaInstance -Value $existingWithNextLineBackupPath -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An existing target with a U+0085 whitespace-only backup path must fail closed.'

        $existingWithoutOriginalHash = Copy-TestJsonObject $journal
        $existingWithoutOriginalHash.states[0].originalSha256 = $null
        Assert-AuthoritySchemaInstance -Value $existingWithoutOriginalHash -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An existing target without an original hash must fail closed.'

        $existingWithoutBackupHash = Copy-TestJsonObject $journal
        $existingWithoutBackupHash.states[0].backupSha256 = $null
        Assert-AuthoritySchemaInstance -Value $existingWithoutBackupHash -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An existing target without a backup hash must fail closed.'

        $absentWithBackup = Copy-TestJsonObject $absentJournal
        $absentWithBackup.states[0].backupPath = 'C:\Users\fixture\.agents\backups\tx\unexpected'
        Assert-AuthoritySchemaInstance -Value $absentWithBackup -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An absent target with backup metadata must fail closed.'

        $absentWithOriginalHash = Copy-TestJsonObject $absentJournal
        $absentWithOriginalHash.states[0].originalSha256 = ('c' * 64)
        Assert-AuthoritySchemaInstance -Value $absentWithOriginalHash -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An absent target with an original hash must fail closed.'

        $absentWithBackupHash = Copy-TestJsonObject $absentJournal
        $absentWithBackupHash.states[0].backupSha256 = ('c' * 64)
        Assert-AuthoritySchemaInstance -Value $absentWithBackupHash -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'An absent target with a backup hash must fail closed.'

        $failureDetail = [pscustomobject][ordered]@{
            schemaVersion=1; code='unsafe-target-path'; skillId='alpha'
            path='.agents/skills/<rejected-target-path>'; classification='controlled-candidate'
            owner='desired-state-staged-inventory'; evidence="Rejected target path 'C:\outside\SKILL.md'."
            destructiveChangeAllowed=$false; backupCreated=$false
            expectedSha256=('e' * 64); actualSha256=$null; remediation=@('Rebuild desired state.')
        }
        Assert-AuthoritySchemaInstance -Value $failureDetail -Schema $schema -SchemaPath $schemaPath -Expected $true -Message 'Unsafe candidate evidence must use a schema-valid sentinel path.'

        $unsafeFailureDetail = Copy-TestJsonObject $failureDetail
        $unsafeFailureDetail.path = 'C:\outside\SKILL.md'
        Assert-AuthoritySchemaInstance -Value $unsafeFailureDetail -Schema $schema -SchemaPath $schemaPath -Expected $false -Message 'A raw unsafe candidate path must not satisfy repositoryPath.'
    }

    # Scenario: An upstream Plugin or Agent Skills change is accepted without an explicit central boundary.
    # Purpose: Keep the portable contract, adapter decisions, and SYP-specific governance in one reviewable authority record.
    It 'UnitT80_binds_upstream_interoperability_to_explicit_central_decisions' {
        Assert-True (Test-Path -LiteralPath $script:UpstreamInteroperabilityPath -PathType Leaf) 'Upstream interoperability decision record is missing from the central standards directory.'
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $matrix = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:MatrixPath
        $upstream = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UpstreamInteroperabilityPath
        $authorityGate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath

        Assert-True (Test-Path -LiteralPath $script:UpstreamAdapterPolicyPath -PathType Leaf) 'Upstream adapter policy is missing from the central standards directory.'
        Assert-True (Test-Path -LiteralPath $script:UpstreamAdapterSchemaPath -PathType Leaf) 'Upstream adapter schema is missing from the central standards directory.'
        Assert-True (Test-Path -LiteralPath $script:UpstreamAdapterValidatorPath -PathType Leaf) 'Upstream adapter validator is missing from the central scripts directory.'
        $adapterPolicy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UpstreamAdapterPolicyPath | ConvertFrom-Json
        $adapterSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UpstreamAdapterSchemaPath | ConvertFrom-Json
        Assert-AuthoritySchemaInstance -Value $adapterPolicy -Schema $adapterSchema -SchemaPath $script:UpstreamAdapterSchemaPath -Expected $true -Message 'Upstream adapter policy must be schema-valid.'
        Assert-Equal $adapterPolicy.schemaVersion 1 'Upstream adapter policy must remain v1.'
        Assert-Equal $adapterPolicy.policy 'upstream-interoperability-adapter-v1' 'Upstream adapter policy identity changed.'
        $validatorText = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UpstreamAdapterValidatorPath
        Assert-Match $validatorText 'pluginManifestPath|marketplacePath|rootRelativePathPrefix' 'Upstream adapter validator must consume the central path/manifest policy.'
        Assert-Match $validatorText 'Assert-AdapterNoReparsePath' 'Upstream adapter validator must reject reparse-point manifest paths before reading package metadata.'
        Assert-Match $validatorText 'Assert-AdapterRegularFile' 'Upstream adapter validator must reject non-regular files before reading or executing package-local inputs.'
        Assert-Match $validatorText 'Get-AdapterSkillResourceInventory|bundledSkills' 'Upstream adapter validator must inventory every declared bundled Skill resource.'
        Assert-Match $validatorText 'duplicate object key' 'Upstream adapter validator must reject duplicate JSON object keys before deserialization.'
        Assert-Match $validatorText 'allowedRemoteMcpEndpoints' 'Upstream adapter policy must approve exact MCP endpoints rather than hostnames.'
        Assert-Match $validatorText 'approvedMarketplaceRepositories' 'Upstream adapter policy must bind marketplace repositories to approved provenance identities.'
        Assert-Match $validatorText 'source\.path must be exactly' 'Marketplace source paths must be restricted to the reviewed package root.'
        Assert-Match $validatorText 'lstat|IsRegularFile' 'Upstream adapter validator must establish Unix regular-file type without opening special files.'
        Assert-Match $validatorText 'ReparsePoint|mkfifo|Mode' 'Upstream adapter validator and regression boundary must account for Windows reparse and Unix special-file inputs.'
        Assert-NotMatch $validatorText 'ProcessArchitecture|Linux architecture|x86_64' 'Upstream adapter regular-file detection must not be restricted to one Unix ABI or architecture.'
        Assert-Match $validatorText 'Assert-AdapterReservedSurfacePaths' 'Upstream adapter validator must reject case aliases of every reserved adapter surface before probing manifests.'
        Assert-Match $validatorText 'Assert-AdapterDeclaredSkillPath' 'Upstream adapter validator must enforce the canonical declared Skill root.'
        Assert-Match $validatorText 'must declare at least one Skill or MCP server capability' 'Upstream adapter validator must reject metadata-only Plugin packages.'
        Assert-Match $validatorText 'componentInventory|packageSha256|SourceRevision|ArchiveSha256' 'Upstream adapter evidence must bind candidate identity and hashed validated components.'
        Assert-Match $validatorText 'source\.sha must equal.*SourceRevision' 'Marketplace selector evidence must bind to the adapter candidate revision.'
        Assert-Match $validatorText 'DeclaredServerNames|not a declared MCP server identity' 'Upstream adapter apps must bind to declared MCP server identities.'
        Assert-Match $validatorText 'BLOCK' 'Upstream adapter validator must fail closed.'
        Assert-Match $authorityGate 'Assert-AuthorityComponentInventoryFiles' 'The authority gate must recheck adapter component hashes after validation.'
        Assert-Match $authorityGate 'replay check|mutation' 'The authority gate must regress report replay after component mutation.'
        Assert-Match $index 'upstream-interoperability\.md' 'Standards index must expose the upstream interoperability authority record.'
        Assert-Match $standard 'upstream-interoperability\.md' 'Normative Standard must bind the upstream interoperability boundary.'
        Assert-Match $matrix 'Upstream interoperability' 'Cross-repository matrix must record the SYP-193 upstream boundary.'
        Assert-Match $upstream '69ef37e9424c0a7ea9dd2293b559e43ec8176379' 'Agent Skills evidence must bind an immutable upstream revision.'
        Assert-Match $upstream '\.codex-plugin/plugin\.json' 'Plugin manifest adoption must be explicit.'
        Assert-Match $upstream '\.mcp\.json' 'MCP package adoption must be explicit.'
        Assert-Match $upstream 'Adopt' 'The upstream decision record must contain Adopt decisions.'
        Assert-Match $upstream 'Partial Adopt' 'The upstream decision record must contain Partial Adopt decisions.'
        Assert-Match $upstream 'Do Not Adopt' 'The upstream decision record must contain Do Not Adopt decisions.'
        Assert-Match $upstream 'MUST NOT.*replace.*central Catalog/Lock' 'Upstream packaging must not replace central provenance and lifecycle authority.'
        Assert-Match $upstream 'schema' 'Schema/pin limitations must be recorded instead of inferred from mutable documentation.'
        Assert-Match $upstream 'SYP-192 Gate 1' 'Plugin conformance must be bound to the deterministic package-validation gate.'
        Assert-Match $upstream 'skill-validator' 'The upstream decision must preserve skill-validator as a Gate 1 requirement.'
        Assert-Match $upstream 'skill-tools check' 'The upstream decision must preserve skill-tools check as a Gate 1 requirement.'
        Assert-Match $upstream 'marketplace\.json' 'Marketplace install-surface responsibility must be explicit.'
        Assert-Match $upstream 'source\.path' 'Marketplace source-path responsibility must be explicit.'
        Assert-Match $upstream 'ref.*sha' 'Marketplace selector integrity responsibility must be explicit.'
        Assert-Match $upstream 'agents/openai\.yaml' 'Host metadata responsibility must be explicit.'
        Assert-Match $upstream 'catalog/source\.json' 'Central source inventory responsibility must be explicit.'
        Assert-Match $upstream 'SkillSpector' 'Security validation responsibility must be explicit.'
        Assert-Match $upstream 'AI Review' 'AI review responsibility must be explicit.'
        Assert-Match $upstream 'Human Approval' 'Human approval responsibility must be explicit.'
        Assert-Match $upstream 'SYP-155' 'Reference implementation impact must be explicit.'
        Assert-Match $upstream 'SYP-156' 'Fan-out migration impact must be explicit.'
    }

    # Scenario: A Plugin or marketplace fixture bypasses the executable adapter and is treated as safe by test-only logic.
    # Purpose: Route representative SYP-193 negative cases through the production validator entry point.
    It 'UnitT81_routes_upstream_negative_cases_through_the_executable_adapter' {
        $fixtureRoot = Join-Path $TestDrive 'upstream-adapter-valid'
        [void](New-Item -ItemType Directory -Path (Join-Path $fixtureRoot '.codex-plugin') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'skills/fixture-skill') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'skills/fixture-skill/references') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $fixtureRoot '.agents/plugins') -Force)
        Write-TestUtf8File -Path (Join-Path $fixtureRoot 'skills/fixture-skill/SKILL.md') -Text "---`nname: fixture-skill`ndescription: A valid adapter fixture Skill package.`n---`n`n# Fixture`n"
        Write-TestUtf8File -Path (Join-Path $fixtureRoot 'skills/fixture-skill/references/nested.txt') -Text 'nested fixture resource'
        Write-TestUtf8File -Path (Join-Path $fixtureRoot '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","description":"A deterministic Plugin adapter fixture.","version":"1.0.0","skills":["./skills/fixture-skill"]}'
        Write-TestUtf8File -Path (Join-Path $fixtureRoot 'adapter-command.ps1') -Text "Write-Output 'adapter fixture'`n"
        Write-TestUtf8File -Path (Join-Path $fixtureRoot '.mcp.json') -Text '{"mcpServers":{"local":{"command":"./adapter-command.ps1","args":[]}}}'
        Write-TestUtf8File -Path (Join-Path $fixtureRoot '.app.json') -Text '{"apps":[{"name":"fixture-app","mcpServer":"local"}]}'
        Write-TestUtf8File -Path (Join-Path $fixtureRoot '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-marketplace-entry","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('a' * 40) + '"}}]}')
        $validReportPath = Join-Path $fixtureRoot 'valid-report.json'
        & $script:UpstreamAdapterValidatorPath `
            -PackageRoot $fixtureRoot `
            -PolicyPath $script:UpstreamAdapterPolicyPath `
            -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceRevision ('a' * 40) `
            -ArchiveSha256 ('b' * 64) `
            -OutputPath $validReportPath | Out-Null
        $validReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $validReportPath | ConvertFrom-Json
        Assert-Equal $validReport.status 'passed' 'A valid Plugin package must pass the executable upstream adapter.'
        Assert-ExactStringSequence $validReport.surfaces @('plugin', 'mcp', 'app', 'marketplace') 'The positive adapter fixture must exercise every adopted upstream surface.'
        Assert-Equal @($validReport.bundledSkills).Count 1 'The positive adapter fixture must report one declared bundled Skill.'
        Assert-Equal $validReport.bundledSkills[0].path './skills/fixture-skill' 'The positive adapter fixture inventory must bind to the declared Skill path.'
        Assert-ExactStringSequence $validReport.bundledSkills[0].inventory @('SKILL.md', 'references/nested.txt') 'The positive adapter fixture must report the complete nested Skill inventory.'
        Assert-Equal $validReport.adapterVersion 'upstream-interoperability-adapter-v1' 'The positive adapter report must identify the adapter version.'
        Assert-Equal $validReport.candidateIdentity.sourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' 'The positive adapter report must bind the source repository.'
        Assert-Equal $validReport.candidateIdentity.sourceRevision ('a' * 40) 'The positive adapter report must bind the immutable source revision.'
        Assert-Equal $validReport.candidateIdentity.archiveSha256 ('b' * 64) 'The positive adapter report must bind the archive hash.'
        Assert-Match $validReport.candidateIdentity.packageSha256 '^[0-9a-f]{64}$' 'The positive adapter report must bind the validated package hash.'
        Assert-Match $validReport.componentInventorySha256 '^[0-9a-f]{64}$' 'The positive adapter report must bind the deterministic component inventory hash.'
        Assert-Equal $validReport.candidateIdentity.packageSha256 $validReport.componentInventorySha256 'Candidate package identity must equal the component inventory identity.'
        Assert-Equal @($validReport.componentInventory).Count 7 'The positive adapter report must hash every validated manifest, command and Skill resource.'
        foreach ($component in @($validReport.componentInventory)) {
            Assert-Match $component.path '^[^/]+(?:/[^/]+)*$' 'Component inventory paths must be canonical relative paths.'
            Assert-Match $component.sha256 '^[0-9a-f]{64}$' 'Component inventory entries must contain lowercase SHA-256 values.'
        }

        $cases = @(
            @{ id='package-missing-skill-md'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root 'skills/fixture-skill/SKILL.md') -Force } },
            @{ id='plugin-path-out-of-root'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["../outside"]}' } },
            @{ id='plugin-path-backslash'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":[".\\skills\\fixture-skill"]}' } },
            @{ id='plugin-path-rooted-windows'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["C:/outside"]}' } },
            @{ id='plugin-path-dot'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["./."]}' } },
            @{ id='plugin-path-colon'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["./skills/a:b"]}' } },
            @{ id='plugin-path-noncanonical-root'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["./packages/fixture-skill"]}' } },
            @{ id='plugin-path-nested'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["./skills/fixture-skill/references"]}' } },
            @{ id='plugin-duplicate-field'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","\u006eame":"other"}' } },
            @{ id='plugin-empty-capability'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root '.mcp.json') -Force; Remove-Item -LiteralPath (Join-Path $root '.app.json') -Force; Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin"}' } },
            @{ id='plugin-empty-skills'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root '.mcp.json') -Force; Remove-Item -LiteralPath (Join-Path $root '.app.json') -Force; Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":[]}' } },
            @{ id='plugin-empty-mcp'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root '.mcp.json') -Force; Remove-Item -LiteralPath (Join-Path $root '.app.json') -Force; Write-TestUtf8File -Path (Join-Path $root '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","mcpServers":{}}' } },
            @{ id='mcp-unapproved-endpoint'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.mcp.json') -Text '{"mcpServers":{"unapproved":{"url":"https://unapproved.example.test/mcp"}}}' } },
            @{ id='app-unknown-mcp-server'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.app.json') -Text '{"apps":[{"name":"fixture-app","mcpServer":"ghost"}]}' } },
            @{ id='plugin-manifest-case-alias'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root '.codex-plugin') -Recurse -Force; Write-TestUtf8File -Path (Join-Path $root '.Codex-Plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["./skills/fixture-skill"]}' } },
            @{ id='mcp-manifest-case-alias'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root '.mcp.json') -Force; Write-TestUtf8File -Path (Join-Path $root '.MCP.json') -Text '{"mcpServers":{"local":{"command":"./adapter-command.ps1","args":[]}}}' } },
            @{ id='app-manifest-case-alias'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root '.app.json') -Force; Write-TestUtf8File -Path (Join-Path $root '.APP.json') -Text '{"apps":[{"name":"fixture-app","mcpServer":"local"}]}' } },
            @{ id='marketplace-manifest-case-alias'; mutate={ param($root) Remove-Item -LiteralPath (Join-Path $root '.agents') -Recurse -Force; Write-TestUtf8File -Path (Join-Path $root '.AGENTS/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-marketplace-entry","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('a' * 40) + '"}}]}') } },
            @{ id='marketplace-mutable-ref'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('a' * 40) + '","ref":"main"}}]}') } },
            @{ id='marketplace-duplicate-name'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('a' * 40) + '"}},{"name":"fixture-plugin","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('b' * 40) + '"}}]}') } },
            @{ id='marketplace-duplicate-nested-field'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('a' * 40) + '","\u0073ha":"' + ('b' * 40) + '"}}]}') } },
            @{ id='marketplace-unknown-field'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('a' * 40) + '"},"trust":"trusted"}]}') } },
            @{ id='marketplace-source-subpath'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"github","repo":"SyuanTsai/SyuanTsai-AI-Instructions","path":"./unreviewed-or-missing-package","sha":"' + ('a' * 40) + '"}}]}') } },
            @{ id='marketplace-unapproved-repository'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"github","repo":"attacker/plugin","path":"./","sha":"' + ('a' * 40) + '"}}]}') } },
            @{ id='marketplace-repository-case-variant'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"github","repo":"syuantsai/SyuanTsai-AI-Instructions","path":"./","sha":"' + ('a' * 40) + '"}}]}') } },
            @{ id='marketplace-unapproved-endpoint'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-plugin","source":{"source":"http","path":"./","sha":"' + ('a' * 40) + '"}}]}') } },
            @{ id='app-duplicate-name'; mutate={ param($root) Write-TestUtf8File -Path (Join-Path $root '.app.json') -Text '{"apps":[{"name":"fixture-app","mcpServer":"local"},{"name":"fixture-app","mcpServer":"local"}]}' } },
            @{ id='plugin-hook-bypass'; mutate={ param($root) [void](New-Item -ItemType Directory -Path (Join-Path $root 'hooks') -Force); Write-TestUtf8File -Path (Join-Path $root 'hooks/run.ps1') -Text 'Write-Output hook' } },
            @{ id='plugin-hook-case-variant'; mutate={ param($root) [void](New-Item -ItemType Directory -Path (Join-Path $root 'Hooks') -Force); Write-TestUtf8File -Path (Join-Path $root 'Hooks/run.ps1') -Text 'Write-Output hook' } }
        )
        $expectedErrorPatterns = @{
            'package-missing-skill-md' = 'SKILL\.md|missing'
            'plugin-path-out-of-root' = 'canonical'
            'plugin-path-backslash' = 'canonical'
            'plugin-path-rooted-windows' = 'canonical'
            'plugin-path-dot' = 'canonical'
            'plugin-path-colon' = 'canonical'
            'plugin-path-noncanonical-root' = 'canonical'
            'plugin-path-nested' = 'canonical'
            'plugin-duplicate-field' = 'duplicate object key'
            'plugin-empty-capability' = 'capability'
            'plugin-empty-skills' = 'capability'
            'plugin-empty-mcp' = 'capability'
            'mcp-unapproved-endpoint' = 'endpoint'
            'app-unknown-mcp-server' = 'not a declared MCP server identity'
            'plugin-manifest-case-alias' = 'alias'
            'mcp-manifest-case-alias' = 'alias'
            'app-manifest-case-alias' = 'alias'
            'marketplace-manifest-case-alias' = 'alias'
            'marketplace-mutable-ref' = 'ref|immutable'
            'marketplace-duplicate-name' = 'duplicate plugin identity'
            'marketplace-duplicate-nested-field' = 'duplicate object key'
            'marketplace-unknown-field' = 'unknown field'
            'marketplace-source-subpath' = 'source\.path|root'
            'marketplace-unapproved-repository' = 'approved central provenance'
            'marketplace-repository-case-variant' = 'approved central provenance'
            'marketplace-unapproved-endpoint' = 'source type|github'
            'app-duplicate-name' = 'duplicate app identity'
            'plugin-hook-bypass' = 'hook'
            'plugin-hook-case-variant' = 'hook|alias'
        }
        foreach ($case in $cases) {
            $caseRoot = Join-Path $TestDrive ([string]$case.id)
            Copy-Item -LiteralPath $fixtureRoot -Destination $caseRoot -Recurse -Force
            & $case.mutate $caseRoot
            $errorMessage = $null
            try {
                & $script:UpstreamAdapterValidatorPath `
                    -PackageRoot $caseRoot `
                    -PolicyPath $script:UpstreamAdapterPolicyPath `
                    -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
                    -SourceRevision ('a' * 40) `
                    -ArchiveSha256 ('b' * 64) `
                    -OutputPath (Join-Path $caseRoot 'report.json') | Out-Null
            }
            catch { $errorMessage = $_.Exception.Message }
            Assert-True ($expectedErrorPatterns.ContainsKey([string]$case.id)) "SYP-193 case '$($case.id)' must declare a case-specific failure pattern."
            Assert-Match $errorMessage $expectedErrorPatterns[[string]$case.id] "SYP-193 case '$($case.id)' must be blocked by its intended executable-adapter validation."
        }

        $duplicatePolicyPath = Join-Path $TestDrive 'upstream-adapter-duplicate-policy.json'
        $duplicatePolicyText = (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UpstreamAdapterPolicyPath).Replace(
            '"allowedRemoteMcpEndpoints": [],',
            '"allowedRemoteMcpEndpoints": [],"allowedRemoteMcpEndpoints": [],'
        )
        Write-TestUtf8File -Path $duplicatePolicyPath -Text $duplicatePolicyText
        $duplicatePolicyError = $null
        try { & $script:UpstreamAdapterValidatorPath -PackageRoot $fixtureRoot -PolicyPath $duplicatePolicyPath | Out-Null }
        catch { $duplicatePolicyError = $_.Exception.Message }
        Assert-Match $duplicatePolicyError 'duplicate object key' 'Duplicate keys in the adapter policy must be rejected before ConvertFrom-Json deserialization.'

        $exactEndpointPolicyPath = Join-Path $TestDrive 'upstream-adapter-exact-endpoint-policy.json'
        $exactEndpointPolicyText = (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UpstreamAdapterPolicyPath).Replace(
            '"allowedRemoteMcpEndpoints": [],',
            '"allowedRemoteMcpEndpoints": ["https://approved.example.test/mcp"],'
        )
        Write-TestUtf8File -Path $exactEndpointPolicyPath -Text $exactEndpointPolicyText
        $exactEndpointRoot = Join-Path $TestDrive 'upstream-adapter-exact-endpoint'
        Copy-Item -LiteralPath $fixtureRoot -Destination $exactEndpointRoot -Recurse -Force
        Write-TestUtf8File -Path (Join-Path $exactEndpointRoot '.mcp.json') -Text '{"mcpServers":{"approved":{"url":"https://approved.example.test/mcp"}}}'
        Write-TestUtf8File -Path (Join-Path $exactEndpointRoot '.app.json') -Text '{"apps":[{"name":"fixture-app","mcpServer":"approved"}]}'
        & $script:UpstreamAdapterValidatorPath `
            -PackageRoot $exactEndpointRoot `
            -PolicyPath $exactEndpointPolicyPath `
            -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
            -SourceRevision ('a' * 40) `
            -ArchiveSha256 ('b' * 64) | Out-Null
        Write-TestUtf8File -Path (Join-Path $exactEndpointRoot '.mcp.json') -Text '{"mcpServers":{"trailing":{"url":"https://approved.example.test/mcp/"}}}'
        $trailingEndpointError = $null
        try {
            & $script:UpstreamAdapterValidatorPath `
                -PackageRoot $exactEndpointRoot `
                -PolicyPath $exactEndpointPolicyPath `
                -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
                -SourceRevision ('a' * 40) `
                -ArchiveSha256 ('b' * 64) | Out-Null
        }
        catch { $trailingEndpointError = $_.Exception.Message }
        Assert-Match $trailingEndpointError 'canonical' 'An MCP endpoint with a trailing slash must not be silently canonicalized to the allowlisted path.'
        Write-TestUtf8File -Path (Join-Path $exactEndpointRoot '.mcp.json') -Text '{"mcpServers":{"unapproved":{"url":"https://approved.example.test/other"}}}'
        $endpointError = $null
        try { & $script:UpstreamAdapterValidatorPath -PackageRoot $exactEndpointRoot -PolicyPath $exactEndpointPolicyPath | Out-Null }
        catch { $endpointError = $_.Exception.Message }
        Assert-Match $endpointError 'endpoint' 'An endpoint with an unapproved path must fail exact endpoint authorization.'

        $crossSurfaceAppRoot = Join-Path $TestDrive 'upstream-adapter-cross-surface-app'
        Copy-Item -LiteralPath $fixtureRoot -Destination $crossSurfaceAppRoot -Recurse -Force
        Write-TestUtf8File -Path (Join-Path $crossSurfaceAppRoot '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["./skills/fixture-skill"],"apps":[{"name":"fixture-app","mcpServer":"local"}]}'
        $crossSurfaceAppError = $null
        try {
            & $script:UpstreamAdapterValidatorPath `
                -PackageRoot $crossSurfaceAppRoot `
                -PolicyPath $script:UpstreamAdapterPolicyPath `
                -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
                -SourceRevision ('a' * 40) `
                -ArchiveSha256 ('b' * 64) | Out-Null
        }
        catch { $crossSurfaceAppError = $_.Exception.Message }
        Assert-Match $crossSurfaceAppError 'duplicate app identity' 'The same app identity must be rejected across Plugin and standalone app surfaces.'

        $mcpCommandCollisionRoot = Join-Path $TestDrive 'upstream-adapter-mcp-command-collision'
        Copy-Item -LiteralPath $fixtureRoot -Destination $mcpCommandCollisionRoot -Recurse -Force
        [void](New-Item -ItemType Directory -Path (Join-Path $mcpCommandCollisionRoot 'scripts') -Force)
        Write-TestUtf8File -Path (Join-Path $mcpCommandCollisionRoot 'scripts/A.ps1') -Text 'Write-Output command'
        Write-TestUtf8File -Path (Join-Path $mcpCommandCollisionRoot '.mcp.json') -Text '{"mcpServers":{"upper":{"command":"./scripts/A.ps1"},"lower":{"command":"./scripts/a.ps1"}}}'
        $mcpCommandCollisionError = $null
        try {
            & $script:UpstreamAdapterValidatorPath `
                -PackageRoot $mcpCommandCollisionRoot `
                -PolicyPath $script:UpstreamAdapterPolicyPath `
                -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
                -SourceRevision ('a' * 40) `
                -ArchiveSha256 ('b' * 64) | Out-Null
        }
        catch { $mcpCommandCollisionError = $_.Exception.Message }
        Assert-Match $mcpCommandCollisionError 'collision' 'MCP command paths that collide under portable case rules must be blocked before component hashing.'

        $marketplaceRepositoryPolicyPath = Join-Path $TestDrive 'upstream-adapter-marketplace-repository-policy.json'
        $marketplaceRepositoryPolicyText = (Get-Content -Raw -Encoding UTF8 -LiteralPath $script:UpstreamAdapterPolicyPath).Replace(
            '"approvedMarketplaceRepositories": ["SyuanTsai/SyuanTsai-AI-Instructions"],',
            '"approvedMarketplaceRepositories": ["SyuanTsai/SyuanTsai-AI-Instructions","Other/approved"],'
        )
        Write-TestUtf8File -Path $marketplaceRepositoryPolicyPath -Text $marketplaceRepositoryPolicyText
        $marketplaceRepositoryRoot = Join-Path $TestDrive 'upstream-adapter-marketplace-repository'
        Copy-Item -LiteralPath $fixtureRoot -Destination $marketplaceRepositoryRoot -Recurse -Force
        Write-TestUtf8File -Path (Join-Path $marketplaceRepositoryRoot '.agents/plugins/marketplace.json') -Text ('{"plugins":[{"name":"fixture-marketplace-entry","source":{"source":"github","repo":"Other/approved","path":"./","sha":"' + ('a' * 40) + '"}}]}')
        $marketplaceRepositoryError = $null
        try {
            & $script:UpstreamAdapterValidatorPath `
                -PackageRoot $marketplaceRepositoryRoot `
                -PolicyPath $marketplaceRepositoryPolicyPath `
                -SourceRepository 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' `
                -SourceRevision ('a' * 40) `
                -ArchiveSha256 ('b' * 64) | Out-Null
        }
        catch { $marketplaceRepositoryError = $_.Exception.Message }
        Assert-Match $marketplaceRepositoryError 'must match adapter source repository' 'A marketplace repository must match the immutable adapter SourceRepository candidate.'

        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $reparseRoot = Join-Path $TestDrive 'upstream-adapter-reparse'
            $reparseOutside = Join-Path $TestDrive 'upstream-adapter-reparse-outside'
            Copy-Item -LiteralPath $fixtureRoot -Destination $reparseRoot -Recurse -Force
            [void](New-Item -ItemType Directory -Path $reparseOutside -Force)
            Write-TestUtf8File -Path (Join-Path $reparseOutside 'adapter-command.ps1') -Text "Write-Output 'outside'`n"
            [void](New-Item -ItemType Junction -Path (Join-Path $reparseRoot 'linked') -Target $reparseOutside)
            Write-TestUtf8File -Path (Join-Path $reparseRoot '.mcp.json') -Text '{"mcpServers":{"linked":{"command":"./linked/adapter-command.ps1"}}}'
            $reparseError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $reparseRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $reparseError = $_.Exception.Message }
            Assert-Match $reparseError 'reparse|regular' 'A Windows reparse-backed package-local command must be blocked before reading the target.'
        }
        else {
            $mkfifo = Get-Command mkfifo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $mkfifo) { Set-TestInconclusive 'mkfifo is unavailable on this Unix host.'; return }
            $fifoRoot = Join-Path $TestDrive 'upstream-adapter-fifo'
            Copy-Item -LiteralPath $fixtureRoot -Destination $fifoRoot -Recurse -Force
            $fifoPath = Join-Path $fifoRoot 'adapter-command.pipe'
            & $mkfifo.Source $fifoPath
            if ($LASTEXITCODE -ne 0) { throw 'Could not create the upstream adapter FIFO fixture.' }
            Write-TestUtf8File -Path (Join-Path $fifoRoot '.mcp.json') -Text '{"mcpServers":{"fifo":{"command":"./adapter-command.pipe"}}}'
            $fifoError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $fifoRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $fifoError = $_.Exception.Message }
            Assert-Match $fifoError 'regular file' 'A Unix FIFO must be blocked without opening or reading it.'
        }

        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $nestedReparseRoot = Join-Path $TestDrive 'upstream-adapter-nested-reparse'
            $nestedReparseOutside = Join-Path $TestDrive 'upstream-adapter-nested-reparse-outside'
            Copy-Item -LiteralPath $fixtureRoot -Destination $nestedReparseRoot -Recurse -Force
            [void](New-Item -ItemType Directory -Path $nestedReparseOutside -Force)
            Write-TestUtf8File -Path (Join-Path $nestedReparseOutside 'resource.txt') -Text 'outside nested resource'
            [void](New-Item -ItemType Junction -Path (Join-Path $nestedReparseRoot 'skills/fixture-skill/assets') -Target $nestedReparseOutside)
            $nestedReparseError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $nestedReparseRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $nestedReparseError = $_.Exception.Message }
            Assert-Match $nestedReparseError 'reparse|regular' 'A Windows reparse-backed nested Skill resource must be blocked.'
        }
        else {
            $nestedMkfifo = Get-Command mkfifo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $nestedMkfifo) {
                $nestedFifoRoot = Join-Path $TestDrive 'upstream-adapter-nested-fifo'
                Copy-Item -LiteralPath $fixtureRoot -Destination $nestedFifoRoot -Recurse -Force
                $nestedFifoPath = Join-Path $nestedFifoRoot 'skills/fixture-skill/assets/resource.pipe'
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $nestedFifoPath) -Force)
                & $nestedMkfifo.Source $nestedFifoPath
                if ($LASTEXITCODE -ne 0) { throw 'Could not create the nested upstream adapter FIFO fixture.' }
                $nestedFifoError = $null
                try { & $script:UpstreamAdapterValidatorPath -PackageRoot $nestedFifoRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
                catch { $nestedFifoError = $_.Exception.Message }
                Assert-Match $nestedFifoError 'regular file' 'A Unix FIFO nested inside a declared Skill must be blocked.'
            }
        }

        if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
            $portableResourceRoot = Join-Path $TestDrive 'upstream-adapter-portable-resource'
            Copy-Item -LiteralPath $fixtureRoot -Destination $portableResourceRoot -Recurse -Force
            [void](New-Item -ItemType Directory -Path (Join-Path $portableResourceRoot 'skills/fixture-skill/assets') -Force)
            Write-TestUtf8File -Path (Join-Path $portableResourceRoot 'skills/fixture-skill/assets/CON.txt') -Text 'device alias'
            $portableResourceError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $portableResourceRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $portableResourceError = $_.Exception.Message }
            Assert-Match $portableResourceError 'portable|device' 'A Windows-invalid or device-name nested Skill resource must be blocked on Unix.'

            $wildcardRoot = Join-Path $TestDrive 'upstream-adapter-wildcard-resource'
            Copy-Item -LiteralPath $fixtureRoot -Destination $wildcardRoot -Recurse -Force
            [void](New-Item -ItemType Directory -Path (Join-Path $wildcardRoot 'skills/fixture-skill/assets') -Force)
            Write-TestUtf8File -Path (Join-Path $wildcardRoot 'skills/fixture-skill/assets/bad*name.txt') -Text 'invalid wildcard'
            $wildcardError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $wildcardRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $wildcardError = $_.Exception.Message }
            Assert-Match $wildcardError 'portable' 'A Windows-invalid wildcard nested Skill resource must be blocked on Unix.'

            $collisionRoot = Join-Path $TestDrive 'upstream-adapter-resource-collision'
            Copy-Item -LiteralPath $fixtureRoot -Destination $collisionRoot -Recurse -Force
            [void](New-Item -ItemType Directory -Path (Join-Path $collisionRoot 'skills/fixture-skill/assets') -Force)
            Write-TestUtf8File -Path (Join-Path $collisionRoot 'skills/fixture-skill/assets/A.txt') -Text 'upper'
            Write-TestUtf8File -Path (Join-Path $collisionRoot 'skills/fixture-skill/assets/a.txt') -Text 'lower'
            $collisionError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $collisionRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $collisionError = $_.Exception.Message }
            Assert-Match $collisionError 'collision' 'Case-colliding nested Skill resources must be blocked before inventory hashing.'

            $deviceAliasRoot = Join-Path $TestDrive 'upstream-adapter-device-alias-resource'
            Copy-Item -LiteralPath $fixtureRoot -Destination $deviceAliasRoot -Recurse -Force
            [void](New-Item -ItemType Directory -Path (Join-Path $deviceAliasRoot 'skills/fixture-skill/assets') -Force)
            $deviceAliasName = 'COM' + [char]0x00B9 + '.txt'
            Write-TestUtf8File -Path (Join-Path $deviceAliasRoot ('skills/fixture-skill/assets/' + $deviceAliasName)) -Text 'superscript device alias'
            $deviceAliasError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $deviceAliasRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $deviceAliasError = $_.Exception.Message }
            Assert-Match $deviceAliasError 'device' 'Windows superscript device-name aliases must be blocked on Unix.'

            $skillRootCollisionRoot = Join-Path $TestDrive 'upstream-adapter-skill-root-collision'
            Copy-Item -LiteralPath $fixtureRoot -Destination $skillRootCollisionRoot -Recurse -Force
            [void](New-Item -ItemType Directory -Path (Join-Path $skillRootCollisionRoot 'skills/Fixture-Skill') -Force)
            Write-TestUtf8File -Path (Join-Path $skillRootCollisionRoot 'skills/Fixture-Skill/SKILL.md') -Text "---`nname: fixture-skill`ndescription: A second case-colliding Skill root.`n---`n`n# Fixture`n"
            Write-TestUtf8File -Path (Join-Path $skillRootCollisionRoot '.codex-plugin/plugin.json') -Text '{"name":"fixture-plugin","skills":["./skills/fixture-skill","./skills/Fixture-Skill"]}'
            $skillRootCollisionError = $null
            try { & $script:UpstreamAdapterValidatorPath -PackageRoot $skillRootCollisionRoot -PolicyPath $script:UpstreamAdapterPolicyPath | Out-Null }
            catch { $skillRootCollisionError = $_.Exception.Message }
            Assert-Match $skillRootCollisionError 'collision' 'Declared Skill roots that collide under portable case rules must be blocked.'
        }
    }

    # Scenario: Validation and security policy semantics are weakened, or the ordinary authority gate claims the retired lifecycle chain.
    # Purpose: Bind SYP-192's policy contract to its validator while keeping the ordinary gate's retained Pester boundary explicit.
    It 'UnitT90_binds_canonical_validation_security_order_and_fail_closed_severity' {
        Assert-True (Test-Path -LiteralPath $script:ValidationSecurityGatePath -PathType Leaf) 'Canonical validation/security gate policy is missing.'
        Assert-True (Test-Path -LiteralPath $script:ValidationSecurityGateSchemaPath -PathType Leaf) 'Canonical validation/security gate schema is missing.'
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGateSchemaPath | ConvertFrom-Json
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $matrix = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:MatrixPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        . $script:AuthorityGatePath -DefineFunctionsOnly

        Assert-AuthoritySchemaInstance -Value $policy -Schema $schema -SchemaPath $script:ValidationSecurityGateSchemaPath -Expected $true -Message 'Canonical validation/security gate policy must be schema-valid.'
        Assert-AuthorityValidationSecurityGate -Policy $policy | Out-Null
        Assert-Equal $policy.schemaVersion 1 'Canonical validation/security gate policy must remain v1.'
        Assert-Equal $policy.policy 'canonical-validation-security-gate-v1' 'Canonical validation/security gate policy identity changed.'
        $expectedIds = @(
            'controlled-acquisition',
            'integrity-verification',
            'package-validation',
            'skillspector-static',
            'repository-tests',
            'conditional-semantic-scan',
            'ai-review',
            'human-approval',
            'publish-or-install',
            'post-install-verification'
        )
        $expectedNames = @(
            'Controlled Acquisition',
            'Integrity Verification',
            'Package Validation',
            'SkillSpector Static',
            'Repository Tests',
            'Conditional Semantic Scan',
            'AI Review',
            'Human Approval',
            'Publish / Install',
            'Post-install Verification'
        )
        $expectedEvidence = @(
            ,@('candidateIdentity', 'authoritySnapshot', 'sourcePin')
            ,@('archiveSha256', 'contentSha256', 'provenance')
            ,@('packageInventory', 'packageSchema', 'packageValidatorResult', 'adapterResult', 'skillToolsResult')
            ,@('scannerIdentity', 'analyzerCompleteness', 'staticReport')
            ,@('testInventory', 'testResult', 'domainAdapterResult')
            ,@('triggerDecision', 'semanticReport', 'semanticCompleteness')
            ,@('reviewFindings', 'findingDisposition', 'reviewedCandidate')
            ,@('approver', 'approvalTimestamp', 'approvedCandidate')
            ,@('releaseIdentity', 'publishOrInstallResult', 'authorization', 'attestation')
            ,@('installedInventory', 'installedManifest', 'postInstallIntegrity', 'attestation')
        )
        Assert-ExactStringSequence ($policy.stages | ForEach-Object { [string]$_.id }) $expectedIds 'Canonical validation/security stage IDs must remain ordered.'
        Assert-ExactStringSequence ($policy.stages | ForEach-Object { [string]$_.name }) $expectedNames 'Canonical validation/security stage names must remain ordered.'
        Assert-ExactStringSequence ($policy.stages | ForEach-Object { [string]$_.order }) (@(1..10 | ForEach-Object { [string]$_ })) 'Canonical validation/security stage order numbers must be contiguous.'
        foreach ($stage in @($policy.stages)) {
            $stageIndex = [int]$stage.order - 1
            Assert-Equal $stage.failureAction 'BLOCK' "Stage '$($stage.id)' must fail closed."
            Assert-ExactStringSequence $stage.evidence $expectedEvidence[$stageIndex] "Stage '$($stage.id)' must declare the exact canonical evidence sequence."
        }
        foreach ($mutation in @(
            @{ Name='placeholder'; Mutate={ param($item) $item.stages[0].evidence=@('placeholder') } },
            @{ Name='reordered'; Mutate={ param($item) $item.stages[0].evidence=@('authoritySnapshot', 'candidateIdentity', 'sourcePin') } }
        )) {
            $weakened = Copy-TestJsonObject -Value $policy
            & $mutation.Mutate $weakened
            Assert-AuthoritySchemaInstance -Value $weakened -Schema $schema -SchemaPath $script:ValidationSecurityGateSchemaPath -Expected $false -Message "Weakened evidence '$($mutation.Name)' must fail schema validation."
            $errorMessage = $null
            try { Assert-AuthorityValidationSecurityGate -Policy $weakened | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'exact canonical evidence set|evidence 1' "Weakened evidence '$($mutation.Name)' must fail the executable authority gate."
        }
        Assert-Equal $policy.security.scannerFailure 'BLOCK' 'Scanner failure must block.'
        Assert-Equal $policy.security.analyzerIncomplete 'BLOCK' 'Analyzer incompleteness must block.'
        Assert-Equal $policy.security.unparsableResult 'BLOCK' 'Unparsable results must block.'
        Assert-Equal $policy.security.unknownSeverity 'BLOCK' 'Unknown severity must block.'
        $severity = @($policy.security.severity)
        Assert-Equal $severity.Count 5 'Canonical security severity mapping must contain five levels.'
        foreach ($expected in @(
            @{ level='critical'; action='BLOCK' },
            @{ level='high'; action='BLOCK' },
            @{ level='medium'; action='HUMAN_REVIEW_REQUIRED' },
            @{ level='low'; action='RECORD_AND_TRACK' },
            @{ level='informational'; action='RECORD_AND_TRACK' }
        )) {
            $actual = @($severity | Where-Object { [string]$_.level -ceq $expected.level })
            Assert-Equal $actual.Count 1 "Severity '$($expected.level)' must have one mapping."
            Assert-Equal $actual[0].action $expected.action "Severity '$($expected.level)' has the wrong action."
        }
        Assert-True ([bool]$policy.security.aiReviewCannotReplaceHumanApproval) 'AI Review must not replace Human Approval.'
        Assert-Equal $policy.security.aiReview.authentication 'trusted-supervisor-signed-ai-review-v1' 'AI review must require trusted-supervisor authentication.'
        Assert-ExactStringSequence $policy.security.aiReview.digestFields @('reviewFindingsSha256', 'findingDispositionSha256') 'AI review must bind both complete result digests.'
        Assert-Equal $policy.security.aiReview.attestation 'trusted-supervisor-ai-review-v1' 'AI review must use the canonical attestation type.'
        Assert-Equal $policy.security.semanticPreflight.artifactType 'semantic-scan-preflight-v1' 'Semantic preflight must use the canonical unsigned artifact type.'
        Assert-Equal $policy.security.semanticPreflight.authentication 'unsigned-provider-output' 'Semantic preflight must remain explicitly unsigned.'
        Assert-Equal $policy.security.semanticPreflight.sourceBinding 'llm-input-equals-strict-utf8-decoding-of-verified-source-bytes' 'Semantic provider input must be bound to verified source bytes.'
        Assert-Equal $policy.security.semanticPreflight.providerInventoryBinding 'full-byte-manifest-plus-authenticated-provider-text-subset-with-strict-utf8-v1-digest' 'Semantic provider inventory must separate complete package bytes from provider text.'
        Assert-Equal $policy.security.semanticPreflight.workBinding 'one-successful-provider-call-per-planned-work-item-with-matching-analyzer-path-and-interval' 'Every planned semantic work item must bind to its own provider call.'
        Assert-Equal $policy.security.semanticPreflight.jsonPropertyBinding 'reject-decoded-duplicate-properties-with-ordinal-ignore-case-semantics-before-deserialization' 'Scanner JSON must reject property names that the supported PowerShell parser would collapse.'
        Assert-ExactStringSequence $policy.security.semanticPreflight.nonAuthority @('cannot-satisfy-semantic-evidence', 'cannot-authorize-release') 'Semantic preflight must not become release authority.'
        Assert-ExactStringSequence $policy.security.samePassBlockSemantics @('local', 'pre-push', 'ci') 'Local, pre-push and CI must share pass/block semantics.'

        $semanticBridge = $policy.security.semanticBridgeV2
        Assert-ExactPropertySet $semanticBridge @('schemaVersion', 'schemaPath', 'artifactClassification', 'artifactTypes', 'mode', 'callbackTrust', 'filesystemIsolation', 'callerSupplied', 'nonSelected', 'production', 'v1Compatibility') 'The v2 local semantic bridge policy property set changed.'
        Assert-Equal $semanticBridge.schemaVersion 2 'The local semantic bridge must remain schema version 2.'
        Assert-Equal $semanticBridge.schemaPath 'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json' 'The v2 local semantic bridge must reference the versioned schema.'
        Assert-Equal $semanticBridge.artifactClassification 'local-semantic-bridge-v2' 'The v2 local semantic bridge classification changed.'
        Assert-ExactStringSequence $semanticBridge.artifactTypes @('semantic-consent-request-v2', 'semantic-consent-decision-v2', 'semantic-evidence-v2') 'The v2 local semantic bridge artifact types must remain versioned.'
        Assert-Equal $semanticBridge.mode 'development-harness-local-simulation-only' 'The v2 local semantic bridge must remain development/local-only.'
        Assert-Equal $semanticBridge.callbackTrust 'caller-trusted-local-code' 'The v2 semantic bridge must only run caller-trusted local callback code.'
        Assert-False ([bool]$semanticBridge.filesystemIsolation) 'The v2 callback process boundary must not claim filesystem isolation.'
        Assert-True ([bool]$semanticBridge.callerSupplied.providerRoute) 'Provider route selection must remain caller-supplied.'
        Assert-True ([bool]$semanticBridge.callerSupplied.verificationKey) 'The v2 verification key must remain caller-supplied.'
        Assert-True ([bool]$semanticBridge.callerSupplied.providerCallback) 'Provider callback selection must remain caller-supplied.'
        Assert-True ([bool]$semanticBridge.callerSupplied.signerCallback) 'Signer callback selection must remain caller-supplied.'
        Assert-ExactStringSequence $semanticBridge.nonSelected @('provider', 'accountOrTenant', 'model', 'endpoint', 'signer') 'The v2 bridge must not select provider, account, model, endpoint, or signer.'
        Assert-False ([bool]$semanticBridge.production.active) 'The v2 local semantic bridge must not be production-active.'
        Assert-False ([bool]$semanticBridge.production.releaseEligible) 'The v2 local semantic bridge must never make a release eligible result.'
        Assert-Equal $semanticBridge.production.failureAction 'BLOCK' 'The v2 production boundary must fail closed.'
        Assert-ExactStringSequence $semanticBridge.production.pending @('protected-trust-anchor', 'trusted-supervisor-authorization') 'The v2 production boundary must remain pending protected trust and supervisor authorization.'
        Assert-Equal $semanticBridge.v1Compatibility.canonicalAuthentication 'trusted-supervisor-signed-semantic-v1' 'The existing semantic v1 authentication contract must remain canonical.'
        Assert-True ([bool]$semanticBridge.v1Compatibility.preserved) 'Semantic v1 compatibility must remain preserved.'
        Assert-False ([bool]$semanticBridge.v1Compatibility.v2SatisfiesV1) 'A local v2 bridge result must not satisfy the semantic v1 contract.'

        Assert-Match $index 'validation-security-gate\.json' 'Standards index must expose the canonical validation/security gate policy.'
        Assert-Match $standard 'validation-security-gate\.json' 'Normative Standard must bind the canonical validation/security gate policy.'
        Assert-Match $standard 'strict-utf8-v1' 'Normative Standard must bind provider text to the versioned deterministic decoding of verified source bytes.'
        Assert-Match $standard 'binary.*provider text inventory' 'Normative Standard must keep binary assets byte-bound outside the provider text inventory.'
        Assert-Match $standard 'planned work item.*provider call' 'Normative Standard must bind provider telemetry to every planned work item.'
        Assert-Match $standard 'OrdinalIgnoreCase' 'Normative Standard must define supported PowerShell JSON property-collision semantics.'
        Assert-Match $standard 'semantic-scan-preflight-v1' 'Normative Standard must define the unsigned semantic preflight boundary.'
        Assert-Match $standard 'standard-semantic-consent-evidence-v2\.schema\.json' 'Normative Standard must reference the versioned v2 local semantic bridge schema.'
        Assert-Match $standard 'caller.*provider.*account/tenant.*model.*endpoint.*signer' 'Normative Standard must prohibit central selection of v2 provider route and signer values.'
        Assert-Match $standard 'filesystemIsolation=false' 'Normative Standard must state that v2 callbacks are not filesystem-isolated.'
        Assert-Match $standard 'invoking OS account' 'Normative Standard must state which filesystem permissions v2 callbacks retain.'
        Assert-Match $standard 'caller-supplied/unverified' 'Normative Standard must keep unauthenticated local authority/tool/provider metadata explicitly unverified.'
        Assert-Match $standard 'run ID' 'Normative Standard must distinguish current-run ID verification from production authentication.'
        Assert-Match $standard 'production launch, authority, or tool authentication' 'Normative Standard must keep current-run binding distinct from production authentication.'
        Assert-Match $standard 'releaseEligible=false' 'Normative Standard must keep the local v2 bridge ineligible for release.'
        Assert-Match $standard 'protected trust anchor.*trusted-supervisor authorization' 'Normative Standard must keep production v2 fail-closed pending protected authority.'
        Assert-Match $matrix 'Canonical validation / security gate' 'Cross-repository matrix must record the SYP-192 gate boundary.'
        Assert-Match $gate 'Assert-AuthorityValidationSecurityGate' 'The canonical policy validator must remain available to the retained policy regression checks.'
        $normalMain = $gate.Substring($gate.IndexOf('if ($BindingOnly) {'))
        Assert-NotMatch $normalMain 'validation-security-gate\.json|Assert-AuthorityValidationSecurityGate|Context ''upstream adapter validation''|Context ''skill-validator package validation''|Context ''skill-tools package validation''|Context ''SkillSpector static scan''|tenStageCompletionClaim' 'The ordinary gate must not run policy-controlled providers, package validators, scanners, or the ten-stage lifecycle.'
        Assert-Match $normalMain 'Invoke-Pester -Script \$authorityTestPaths -Strict -PassThru' 'The ordinary gate must execute its retained Pester checks with strict result handling.'
        Assert-Match $normalMain "name = 'Standard v1 authority gate'" 'The ordinary result must claim only the retained Standard v1 authority gate check.'
    }

    # Scenario: The central policy, v1 runner contract, v1 evidence schema, and new v2 schema expose the same local-only bridge boundary.
    # Purpose: Keep v2 caller-supplied verification explicitly non-authoritative while preserving the production semantic v1 contract.
    It 'UnitT93_binds_the_v2_local_bridge_reference_without_promoting_it_to_production' {
        Assert-True (Test-Path -LiteralPath $script:StandardSemanticConsentEvidenceV2SchemaPath -PathType Leaf) 'The versioned v2 local semantic bridge schema is missing.'
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json
        $policySchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGateSchemaPath | ConvertFrom-Json
        $contract = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardValidationContractPath | ConvertFrom-Json
        $evidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardValidationEvidenceSchemaPath | ConvertFrom-Json
        $v2Schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardSemanticConsentEvidenceV2SchemaPath | ConvertFrom-Json

        Assert-Equal $v2Schema.'$id' 'urn:syuan-tsai-ai-instructions:standard-semantic-consent-evidence:v2' 'The v2 schema identity must remain explicit and versioned.'
        Assert-Equal @($v2Schema.oneOf).Count 3 'The v2 schema must distinguish request, decision, and evidence artifacts.'
        Assert-True ([string]$v2Schema.description -match 'does not select a production provider.*account.*model.*endpoint.*signer') 'The v2 schema must document its provider-agnostic non-selection boundary.'
        Assert-True (@($v2Schema.'$defs'.executionEvidence.required) -contains 'providerCalls') 'The v2 execution evidence must carry a recomputable per-work provider-call ledger.'
        Assert-Equal $v2Schema.'$defs'.executionEvidence.properties.providerCalls.items.'$ref' '#/$defs/providerCallEvidence' 'The v2 provider-call ledger must use its closed typed row schema.'
        Assert-Equal $v2Schema.'$defs'.providerCallEvidence.properties.workItemId.pattern '^semantic-work-item-[0-9]{4,}$' 'The v2 provider-call schema must accept the implementation format after index 9999.'

        Assert-AuthoritySchemaInstance -Value $policy -Schema $policySchema -SchemaPath $script:ValidationSecurityGateSchemaPath -Expected $true -Message 'The policy with the v2 local bridge boundary must remain schema-valid.'
        Assert-Equal $contract.semanticBridgeV2.schemaVersion 2 'The central v1 runner contract must reference v2 explicitly.'
        Assert-Equal $contract.semanticBridgeV2.schemaPath 'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json' 'The central runner contract must reference the v2 schema path.'
        Assert-Equal $contract.semanticBridgeV2.mode 'development-harness-local-simulation-only' 'The central runner contract must keep v2 local-only.'
        Assert-Equal $contract.semanticBridgeV2.callbackTrust 'caller-trusted-local-code' 'The central runner contract must require caller-trusted local callbacks.'
        Assert-False ([bool]$contract.semanticBridgeV2.filesystemIsolation) 'The central runner contract must not claim callback filesystem isolation.'
        Assert-False ([bool]$contract.semanticBridgeV2.production.active) 'The central runner contract must not activate v2 in production.'
        Assert-False ([bool]$contract.semanticBridgeV2.production.releaseEligible) 'The central runner contract must keep v2 release-ineligible.'
        Assert-ExactStringSequence $contract.semanticBridgeV2.production.pending @('protected-trust-anchor', 'trusted-supervisor-authorization') 'The central runner contract must preserve the v2 production prerequisites.'
        Assert-Equal $contract.semanticBridgeV2.v1Compatibility.canonicalAuthentication 'trusted-supervisor-signed-semantic-v1' 'The central runner contract must preserve semantic v1 authentication.'
        Assert-False ([bool]$contract.semanticBridgeV2.v1Compatibility.v2SatisfiesV1) 'The v2 local bridge must not satisfy semantic v1 evidence.'

        Assert-Equal $evidenceSchema.properties.semanticBridgeV2.'$ref' '#/$defs/semanticBridgeV2Reference' 'The v1 evidence schema must expose v2 only through an explicit reference descriptor.'
        Assert-Equal $evidenceSchema.'$defs'.stage.properties.semanticBridgeV2Evidence.anyOf[0].'$ref' '#/$defs/semanticBridgeV2VerifiedEvidenceReference' 'A verified local v2 artifact must use a distinct stage reference instead of the production semantic v1 slot.'
        $reference = [pscustomobject][ordered]@{
            schemaVersion = 2
            schemaPath = 'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json'
            artifactClassification = 'local-semantic-bridge-v2'
            mode = 'development-harness-local-simulation-only'
            verificationKey = 'caller-supplied-development-harness-local-simulation-only'
            productionStatus = 'fail-closed-pending-protected-trust-anchor-and-supervisor-authorization'
            releaseEligible = $false
            v1Compatibility = [pscustomobject][ordered]@{
                canonicalAuthentication = 'trusted-supervisor-signed-semantic-v1'
                preserved = $true
                v2SatisfiesV1 = $false
            }
        }
        Assert-True (Test-AuthorityJsonSchemaValue -Value $reference -Schema $evidenceSchema.properties.semanticBridgeV2 -RootSchema $evidenceSchema) 'The v1 evidence schema v2 reference descriptor must be schema-valid.'
        $invalidReference = Copy-TestJsonObject -Value $reference
        $invalidReference.releaseEligible = $true
        Assert-False (Test-AuthorityJsonSchemaValue -Value $invalidReference -Schema $evidenceSchema.properties.semanticBridgeV2 -RootSchema $evidenceSchema) 'A v2 reference descriptor that claims release eligibility must fail closed.'
    }

    # Scenario: The ordinary runner defaults to v2 while the historical full lifecycle remains available only through explicit v1 modes.
    # Purpose: Bind the v2 core boundary and evidence schema while retaining direct coverage for the v1 advanced contract.
    It 'UnitT94_preserves_v1_advanced_contract_and_binds_v2_default_core' {
        foreach ($path in @($script:StandardValidationAdapterSchemaPath, $script:StandardValidationEvidenceSchemaPath, $script:StandardValidationContractPath)) {
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing central runner contract file '$path'."
            $null = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
        }
        $contract = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardValidationContractPath | ConvertFrom-Json
        $runnerPath = Join-Path $script:RepositoryRoot 'scripts\Invoke-StandardValidation.ps1'
        $runner = Get-Content -Raw -Encoding UTF8 -LiteralPath $runnerPath
        Assert-Equal $contract.contract 'standard-validation-contract-v1' 'Central runner contract identity changed.'
        Assert-Equal @($contract.stages).Count 10 'Central runner contract must retain all ten canonical stages.'
        Assert-True ([bool]$contract.execution.packageBeforeStatic) 'Package tools must be a Static prerequisite.'
        Assert-True ([bool]$contract.execution.staticBeforeRepositoryTests) 'Static must be a repository-test prerequisite.'
        Assert-False ([bool]$contract.execution.candidateCodeBeforeStatic) 'Candidate code must not execute before Static.'
        Assert-Match $runner 'Invoke-StandardValidationProcess' 'Central runner must record actual child process execution.'
        Assert-Match $runner 'Assert-StandardValidationToolEnvelope' 'Central runner must validate actual tool output envelopes.'
        Assert-Match $runner 'toolRole\s*=\s*if \(\$test\.kind -ceq ''pester''\)' 'Repository-test typed records must derive role from the validated adapter dispatch kind.'
        Assert-Match $runner 'SemanticConsent' 'Central runner must expose explicit semantic consent.'
        Assert-Match $runner 'CompleteLifecycle' 'Central runner must keep release lifecycle evidence separate from validation-only runs.'

        $coreContractPath = Join-Path $script:StandardsRoot 'standard-core-validation-v2.json'
        $coreAdapterSchemaPath = Join-Path $script:StandardsRoot 'schemas/standard-core-adapter-v2.schema.json'
        $coreEvidenceSchemaPath = Join-Path $script:StandardsRoot 'schemas/standard-core-evidence-v2.schema.json'
        foreach ($path in @($coreContractPath, $coreAdapterSchemaPath, $coreEvidenceSchemaPath)) {
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing ordinary core contract file '$path'."
            $null = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
        }
        $coreContract = Get-Content -Raw -Encoding UTF8 -LiteralPath $coreContractPath | ConvertFrom-Json
        $coreAdapterSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $coreAdapterSchemaPath | ConvertFrom-Json
        $coreEvidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $coreEvidenceSchemaPath | ConvertFrom-Json
        Assert-Equal $coreContract.contract 'standard-core-validation-v2' 'Ordinary core contract identity changed.'
        Assert-Equal $coreContract.ordinaryCli.defaultMode 'core-v2' 'The ordinary CLI must default to the v2 core.'
        Assert-Equal (@($coreContract.ordinaryCli.eventNames) -join ',') 'local,pre-push,pull_request,push,workflow_dispatch' 'Core event values must match the v2 evidence schema.'
        Assert-False ([bool]$coreContract.releaseEligible) 'Core validation must remain release-ineligible.'
        Assert-Match $runner 'if \(-not \$DevelopmentHarness -and -not \$CompleteLifecycle\)' 'The runner must route the ordinary invocation through v2 before entering legacy gates.'
        Assert-Match $runner 'Ordinary core mode accepts only standard-core-adapter-v2' 'An ordinary v1 adapter must fail with a versioned mode error.'
        $coreStart = $runner.IndexOf('function Invoke-StandardCoreValidationRun', [StringComparison]::Ordinal)
        $coreEnd = if ($coreStart -ge 0) { $runner.IndexOf('function Invoke-StandardValidationRun', $coreStart, [StringComparison]::Ordinal) } else { -1 }
        Assert-True ($coreStart -ge 0 -and $coreEnd -gt $coreStart) 'The ordinary core runner function boundary must remain explicit.'
        $coreRunner = $runner.Substring($coreStart, $coreEnd - $coreStart)
        Assert-Match $coreRunner 'Get-StandardCoreTrackedInventory' 'The ordinary core must bind candidate files through Git tracked inventory.'
        Assert-Match $coreRunner 'Copy-StandardCoreTrackedSnapshot' 'The ordinary core must copy only its verified tracked inventory.'
        Assert-Match $coreRunner 'Get-StandardValidationSkillSet -CandidateRoot \$snapshotRoot' 'Active Skills must be discovered from the verified tracked-only snapshot.'
        Assert-False ($coreRunner -match 'Get-StandardValidationInventory|Copy-StandardValidationSnapshot') 'The ordinary core must not use recursive whole-root inventory or copy helpers.'
        Assert-Match $coreRunner "EventName -cnotin @\('local', 'pre-push', 'pull_request', 'push', 'workflow_dispatch'\)" 'Core preflight must reject event names outside the evidence enum.'
        $coreEvidenceWriteAt = $coreRunner.IndexOf('Write-StandardValidationJsonReserved -Path $outputFull', [StringComparison]::Ordinal)
        Assert-True ($coreEvidenceWriteAt -ge 0) 'The core must reserve and publish its final evidence exactly once.'
        $coreLockReleaseAt = $coreRunner.IndexOf('$lockStream.Dispose()', $coreEvidenceWriteAt, [StringComparison]::Ordinal)
        Assert-True ($coreLockReleaseAt -gt $coreEvidenceWriteAt) 'The owned execution lock must remain held through final evidence publication.'
        Assert-False ($coreRunner.Substring($coreLockReleaseAt) -match '\$state\s*=') 'Post-publication lock cleanup must not change the state already written to evidence.'

        $coreAdapter = [pscustomobject][ordered]@{
            schemaVersion = 2
            adapter = 'standard-core-adapter-v2'
            skillsRoot = 'skills'
            activeSkills = @('alpha')
            checks = @([pscustomobject][ordered]@{
                    id = 'repo-tests'; kind = 'general'; executable = (Join-Path $PSHOME 'pwsh.exe')
                    executableSha256 = '0' * 64; arguments = @('-NoLogo')
                })
        }
        Assert-AuthoritySchemaInstance -Value $coreAdapter -Schema $coreAdapterSchema -SchemaPath $coreAdapterSchemaPath -Expected $true -Message 'A minimal ordinary v2 adapter must be schema-valid.'
        $coreAdapterWithLegacySlot = Copy-TestJsonObject -Value $coreAdapter
        Add-Member -InputObject $coreAdapterWithLegacySlot -MemberType NoteProperty -Name externalScanner -Value ([pscustomobject]@{ command = 'unexpected' })
        Assert-AuthoritySchemaInstance -Value $coreAdapterWithLegacySlot -Schema $coreAdapterSchema -SchemaPath $coreAdapterSchemaPath -Expected $false -Message 'A v2 adapter must reject legacy external-tool slots.'

        $coreNow = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $coreRunId = 'a' * 32
        $coreEvidence = [pscustomobject][ordered]@{
            schemaVersion = 2; evidence = 'standard-core-validation-evidence-v2'; generatedAt = $coreNow
            runId = $coreRunId; state = 'PASS'; exitCode = 0; releaseEligible = $false; contentMode = 'development'
            candidate = [pscustomobject][ordered]@{
                repository = 'https://example.com/example/skills.git'; sourceRevision = 'b' * 40; baseRevision = 'c' * 40
                contentSha256 = 'd' * 64; inventory = @([pscustomobject][ordered]@{ path = 'skills/alpha/SKILL.md'; sha256 = 'e' * 64; length = 1 })
                activeSkills = @('alpha'); contentMode = 'development'; eventName = 'local'
            }
            authority = [pscustomobject][ordered]@{
                repository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'; revision = 'f' * 40
                runnerSha256 = '1' * 64; contractSha256 = '2' * 64; contentMode = 'development'
            }
            adapter = [pscustomobject][ordered]@{ schemaVersion = 2; identity = 'standard-core-adapter-v2'; sha256 = '3' * 64 }
            checks = @([pscustomobject][ordered]@{
                    id = 'repo-tests'; kind = 'general'; executableSha256 = '4' * 64; argumentsSha256 = '5' * 64
                    processId = 123; startedAt = $coreNow; endedAt = $coreNow; exitCode = 0; status = 'passed'; cleanedUp = $true
                    stdoutPath = 'C:\core-artifacts\runs\raw\stdout.txt'; stdoutSha256 = '6' * 64
                    stderrPath = 'C:\core-artifacts\runs\raw\stderr.txt'; stderrSha256 = '7' * 64; testCounts = $null
                })
            artifacts = [pscustomobject][ordered]@{
                runId = $coreRunId; root = 'C:\core-artifacts'; outputPath = 'C:\core-artifacts\result.json'
                runRoot = 'C:\core-artifacts\runs\a'; snapshotRoot = 'C:\core-artifacts\runs\a\candidate'
            }
            failure = $null
        }
        Assert-AuthoritySchemaInstance -Value $coreEvidence -Schema $coreEvidenceSchema -SchemaPath $coreEvidenceSchemaPath -Expected $true -Message 'A v2 PASS record with an executed and cleaned check must be schema-valid.'
        foreach ($mutation in @(
                @{ Name = 'nonzero-pass-exit'; Field = 'exitCode'; Value = 20 },
                @{ Name = 'nonpassed-check'; Field = 'status'; Value = 'failed' },
                @{ Name = 'unclean-pass-check'; Field = 'cleanedUp'; Value = $false }
            )) {
            $invalidCoreEvidence = Copy-TestJsonObject -Value $coreEvidence
            $invalidCoreEvidence.checks[0] | Add-Member -NotePropertyName ([string]$mutation.Field) -NotePropertyValue $mutation.Value -Force
            Assert-AuthoritySchemaInstance -Value $invalidCoreEvidence -Schema $coreEvidenceSchema -SchemaPath $coreEvidenceSchemaPath -Expected $false -Message "A v2 PASS record with '$($mutation.Name)' must fail schema validation."
        }
        $invalidCoreEvidence = Copy-TestJsonObject -Value $coreEvidence
        $invalidCoreEvidence.checks[0].stdoutSha256 = 'not-a-sha256'
        Assert-AuthoritySchemaInstance -Value $invalidCoreEvidence -Schema $coreEvidenceSchema -SchemaPath $coreEvidenceSchemaPath -Expected $false -Message 'A v2 PASS check without a valid stdout raw hash must fail schema validation.'
        $invalidCoreEvidence = Copy-TestJsonObject -Value $coreEvidence
        $invalidCoreEvidence.checks[0].PSObject.Properties.Remove('stderrSha256')
        Assert-AuthoritySchemaInstance -Value $invalidCoreEvidence -Schema $coreEvidenceSchema -SchemaPath $coreEvidenceSchemaPath -Expected $false -Message 'A v2 PASS check without a stderr raw hash must fail schema validation.'
        $invalidCoreEvidence = Copy-TestJsonObject -Value $coreEvidence
        $invalidCoreEvidence.candidate.eventName = 'manual'
        Assert-AuthoritySchemaInstance -Value $invalidCoreEvidence -Schema $coreEvidenceSchema -SchemaPath $coreEvidenceSchemaPath -Expected $false -Message 'A v2 candidate event outside the core allowlist must fail schema validation.'

        $invalidEventCandidateRoot = Join-Path $TestDrive 'invalid-event-candidate'
        $invalidEventAdapterPath = Join-Path $TestDrive 'invalid-event-adapter.json'
        $invalidEventArtifactsRoot = Join-Path $TestDrive 'invalid-event-artifacts'
        . $runnerPath `
            -CandidateRoot $invalidEventCandidateRoot `
            -AdapterPath $invalidEventAdapterPath `
            -ArtifactsRoot $invalidEventArtifactsRoot `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'local' `
            -DefineFunctionsOnly
        $invalidEventEvidence = Invoke-StandardValidationRun `
            -CandidateRoot $invalidEventCandidateRoot `
            -AdapterPath $invalidEventAdapterPath `
            -ArtifactsRoot $invalidEventArtifactsRoot `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -EventName 'manual'
        Assert-Equal $invalidEventEvidence.state 'INVALID' 'The core must reject unsupported event names before producing candidate evidence.'
        Assert-Equal $invalidEventEvidence.exitCode 30 'Unsupported events must use INVALID=30.'
        Assert-False ([bool]$invalidEventEvidence.releaseEligible) 'Unsupported event evidence must remain release-ineligible.'
        Assert-False (Test-Path -LiteralPath $invalidEventArtifactsRoot) 'Unsupported events must fail preflight without creating an artifacts root.'

        $evidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardValidationEvidenceSchemaPath | ConvertFrom-Json
        Assert-True (@($evidenceSchema.allOf).Count -ge 6) 'Validation evidence schema must declare all terminal-state consistency rules.'
        $proposalPolicy = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:StandardsRoot 'pr12-source-merge-exception-proposal.json') | ConvertFrom-Json
        Assert-Equal $proposalPolicy.status 'proposed' 'The PR12 source merge exception must remain inactive pending exact-head policy review.'
        Assert-Equal $contract.evidence.sourceMergeExceptionProposal.policyPath 'docs/standards/pr12-source-merge-exception-proposal.json' 'The proposal must have one central policy path.'
        Assert-True ($null -ne $evidenceSchema.properties.sourceMergeExceptionProposal) 'The proposed decision must have a separate schema property.'
        $proposalDecision = [pscustomobject][ordered]@{
            schemaVersion = 1; contract = 'proposed-source-merge-exception-v1'; status = 'eligible-for-policy-review'
            sourceRepository = $proposalPolicy.sourceRepository; sourceRevision = $proposalPolicy.sourceRevision
            candidateId = 'b' * 64; contentSha256 = $proposalPolicy.contentSha256
            scannerReportSha256 = $proposalPolicy.scannerReportSha256; canonicalState = 'FAILED'; canonicalExitCode = 20
            otherScannerReportSha256 = @($proposalPolicy.otherSkillReports | ForEach-Object { $_.sha256 })
            sourceConformanceStatus = 'failed'; supplementalStage = 'supplemental-repository-tests'
            releaseEligible = $false; testFixtureOnly = $false; failureReasons = @()
        }
        Assert-True (Test-AuthorityJsonSchemaValue -Value $proposalDecision -Schema $evidenceSchema.properties.sourceMergeExceptionProposal -RootSchema $evidenceSchema) 'The narrow technical proposal must be schema-valid.'
        $selfApproved = Copy-TestJsonObject -Value $proposalDecision
        $selfApproved.status = 'approved-exception'
        Assert-False (Test-AuthorityJsonSchemaValue -Value $selfApproved -Schema $evidenceSchema.properties.sourceMergeExceptionProposal -RootSchema $evidenceSchema) 'A proposal cannot self-assert approval.'
        $released = Copy-TestJsonObject -Value $proposalDecision
        $released.releaseEligible = $true
        Assert-False (Test-AuthorityJsonSchemaValue -Value $released -Schema $evidenceSchema.properties.sourceMergeExceptionProposal -RootSchema $evidenceSchema) 'A proposed source exception cannot authorize release.'
        Assert-Equal ([regex]::Matches($runner, 'New-StandardValidationProposedSourceMergeExceptionDecision').Count) 3 'The review runner and inactive bridge must share the one technical proposal helper.'
        Assert-Match $contract.evidence.protectedSourceMergeBridgeCandidate.status 'adopted merge-only record' 'The merge-only bridge must require the distinct protected adoption record.'
        Assert-Equal $contract.evidence.protectedSourceMergeBridgeCandidate.schemaProperty 'sourceMergeDecision; canonical state and sourceConformance remain FAILED/20 and failed' 'The merge-only decision must remain separate from canonical validation.'
        Assert-True ($null -ne $evidenceSchema.properties.sourceMergeDecision) 'The protected decision must have a separate schema property.'
        $mergeDecision = [pscustomobject][ordered]@{
            contract = 'protected-source-merge-decision-v1'; status = 'eligible-for-protected-check'
            fixtureRoute = 'rejected'; requiredContexts = @('repository-contract', 'skill-validator', 'skill-tools')
            sourceRevision = $proposalPolicy.sourceRevision; centralRevision = 'a' * 40
            workflowRevision = 'b' * 40; archiveSha256 = 'c' * 64
            releaseEligible = $false; failureReasons = @()
        }
        Assert-True (Test-AuthorityJsonSchemaValue -Value $mergeDecision -Schema $evidenceSchema.properties.sourceMergeDecision -RootSchema $evidenceSchema) 'An exact merge-only decision must be schema-valid.'
        $releasedMerge = Copy-TestJsonObject -Value $mergeDecision
        $releasedMerge.releaseEligible = $true
        Assert-False (Test-AuthorityJsonSchemaValue -Value $releasedMerge -Schema $evidenceSchema.properties.sourceMergeDecision -RootSchema $evidenceSchema) 'A protected source decision cannot authorize release.'
        $otherSourceMerge = Copy-TestJsonObject -Value $mergeDecision
        $otherSourceMerge.sourceRevision = 'd' * 40
        Assert-False (Test-AuthorityJsonSchemaValue -Value $otherSourceMerge -Schema $evidenceSchema.properties.sourceMergeDecision -RootSchema $evidenceSchema) 'A protected source decision cannot extend to another source revision.'
        Assert-Match $runner 'protected-authority-unavailable' 'The bridge must fail closed without a protected authority.'
        Assert-Equal ($contract.evidence.protectedSourceMergeBridgeCandidate.requiredContexts -join ',') 'repository-contract,skill-validator,skill-tools' 'The bridge scope must name only the source contexts.'
        Assert-Match $runner 'if \(\$SourceMergeExceptionReview -and \$null -ne \$candidateEvidence\)' 'The proposal must be absent from ordinary canonical validation.'
        . $runnerPath `
            -CandidateRoot (Join-Path $TestDrive 'schema-candidate') `
            -AdapterPath (Join-Path $TestDrive 'schema-adapter.json') `
            -ArtifactsRoot (Join-Path $TestDrive 'schema-artifacts') `
            -SourceRepository 'https://example.com/example/skills.git' `
            -SourceRevision ('a' * 40) `
            -BaseRevision ('b' * 40) `
            -DefineFunctionsOnly
        $schemaStageIds = @('controlled-acquisition', 'integrity-verification', 'package-validation', 'skillspector-static', 'repository-tests', 'conditional-semantic-scan', 'ai-review', 'human-approval', 'publish-or-install', 'post-install-verification')
        $schemaStages = @(1..10 | ForEach-Object {
                [pscustomobject][ordered]@{
                    order = $_
                    id = $schemaStageIds[$_ - 1]
                    condition = @(
                        'always'
                        'always'
                        'always'
                        'always'
                        'always'
                        'when-triggered'
                        'lifecycle-evidence'
                        'lifecycle-evidence'
                        'approved-release-or-authorized-install'
                        'after-install'
                    )[$_ - 1]
                    status = 'not-applicable'
                    startedAt = $null
                    endedAt = $null
                    events = @()
                }
            })
        $schemaRunId = [guid]::NewGuid()
        $schemaBinding = [pscustomobject][ordered]@{
            status = 'verified'
            verified = $true
            path = $null
            sha256 = ('0' * 64)
            resolutionRunId = $schemaRunId.ToString('N')
            issuedAt = $null
            expiresAt = $null
            consumptionPath = $null
            consumptionSha256 = ('0' * 64)
        }
        $schemaEvidence = New-StandardValidationCandidateEvidence `
            -RunId $schemaRunId `
            -State 'PASS' `
            -ExitCode 0 `
            -ReleaseEligible $false `
            -Stages $schemaStages `
            -ArtifactRoot 'unavailable' `
            -LockPath 'unavailable' `
            -DevelopmentHarness $false `
            -LaunchBinding $schemaBinding
        $schemaEvidenceSourceConformance = New-StandardValidationSourceConformanceResult `
            -Report $schemaEvidence `
            -ExpectedSourceRevision ('a' * 40) `
            -RepositoryTestEvidence @()
        $schemaEvidence | Add-Member -NotePropertyName sourceConformance -NotePropertyValue $schemaEvidenceSourceConformance -Force
        $schemaEvidence = $schemaEvidence | ConvertTo-Json -Depth 50 | ConvertFrom-Json
        Assert-Equal $schemaEvidence.launchBinding.resolutionRunId $schemaRunId.ToString() 'Evidence must serialize the authenticated launch-binding run ID in canonical UUID format.'
        Assert-False ([string]$schemaEvidence.launchBinding.resolutionRunId -match '^[0-9a-f]{32}$') 'Evidence must not expose the internal N-format launch-binding run ID.'
        Assert-AuthoritySchemaInstance -Value $schemaEvidence -Schema $evidenceSchema -SchemaPath $script:StandardValidationEvidenceSchemaPath -Expected $true -Message 'A consistent validation evidence envelope must be schema-valid.'
        foreach ($terminal in @(
            @{ state = 'PASS'; exitCode = 0; releaseEligible = $true },
            @{ state = 'BLOCKED'; exitCode = 10; releaseEligible = $false },
            @{ state = 'FAILED'; exitCode = 20; releaseEligible = $false },
            @{ state = 'INVALID'; exitCode = 30; releaseEligible = $false },
            @{ state = 'CANCELLED'; exitCode = 40; releaseEligible = $false }
        )) {
            $consistent = Copy-TestJsonObject -Value $schemaEvidence
            $consistent.state = $terminal.state
            $consistent.exitCode = $terminal.exitCode
            $consistent.releaseEligible = $terminal.releaseEligible
            $consistent.sourceConformance.canonicalValidation.state = $terminal.state
            $consistent.sourceConformance.canonicalValidation.exitCode = $terminal.exitCode
            $consistent.sourceConformance.canonicalValidation.releaseEligible = $terminal.releaseEligible
            $consistent.sourceConformance.canonicalValidation.stage6Status = if ($terminal.state -ceq 'BLOCKED') { 'blocked' } else { 'not-applicable' }
            if ($terminal.releaseEligible) {
                $consistent.adapter.mode = 'production'
                $consistent.candidate.acquisition.status = 'verified'
                $consistent.candidate.acquisition.verified = $true
                $consistent.authority.binding.status = 'verified'
                $consistent.authority.binding.verified = $true
                $consistent.authority.binding.selectedFiles = @(1..22 | ForEach-Object {
                        [pscustomobject][ordered]@{ path = "authority/file-$_.json"; sha256 = ('0' * 64) }
                    })
                $consistent.launchBinding.status = 'verified'
                $consistent.launchBinding.verified = $true
                $consistent.launchBinding.consumptionPath = 'C:\supervisor-state\launch-consumption.json'
                $consistent.launchBinding.consumptionSha256 = ('1' * 64)
                for ($stageIndex = 0; $stageIndex -lt 10; $stageIndex++) {
                    $consistent.stages[$stageIndex].status = if ($stageIndex -eq 5) { 'not-applicable' } else { 'passed' }
                }
            }
            Assert-AuthoritySchemaInstance -Value $consistent -Schema $evidenceSchema -SchemaPath $script:StandardValidationEvidenceSchemaPath -Expected $true -Message "A consistent '$($terminal.state)' validation evidence envelope must be schema-valid."
        }
        foreach ($contradiction in @(
            @{ Name = 'blocked-with-zero'; state = 'BLOCKED'; exitCode = 0; releaseEligible = $false },
            @{ Name = 'pass-with-failure-code'; state = 'PASS'; exitCode = 20; releaseEligible = $false },
            @{ Name = 'failed-release-eligible'; state = 'FAILED'; exitCode = 20; releaseEligible = $true },
            @{ Name = 'blocked-release-eligible'; state = 'BLOCKED'; exitCode = 10; releaseEligible = $true }
        )) {
            $contradictory = Copy-TestJsonObject -Value $schemaEvidence
            $contradictory.state = $contradiction.state
            $contradictory.exitCode = $contradiction.exitCode
            $contradictory.releaseEligible = $contradiction.releaseEligible
            Assert-AuthoritySchemaInstance -Value $contradictory -Schema $evidenceSchema -SchemaPath $script:StandardValidationEvidenceSchemaPath -Expected $false -Message "Contradictory '$($contradiction.Name)' validation evidence must fail schema validation."
        }
        $sourceStage6Contradiction = Copy-TestJsonObject -Value $schemaEvidence
        $sourceStage6Contradiction.sourceConformance.canonicalValidation.stage6Status = 'blocked'
        Assert-AuthoritySchemaInstance -Value $sourceStage6Contradiction -Schema $evidenceSchema -SchemaPath $script:StandardValidationEvidenceSchemaPath -Expected $false -Message 'A canonical PASS projection with a blocked Stage 6 must fail schema validation.'
        $sourcePesterFailureCount = Copy-TestJsonObject -Value $schemaEvidence
        $sourcePesterFailureCount.sourceConformance.status = 'passed'
        $sourcePesterFailureCount.sourceConformance.sourceRevision = 'a' * 40
        $sourcePesterFailureCount.sourceConformance.candidateId = 'b' * 64
        $sourcePesterFailureCount.sourceConformance.contentSha256 = 'c' * 64
        $sourcePesterFailureCount.sourceConformance.canonicalValidation.state = 'PASS'
        $sourcePesterFailureCount.sourceConformance.canonicalValidation.exitCode = 0
        $sourcePesterFailureCount.sourceConformance.canonicalValidation.stage6Status = 'not-applicable'
        $sourcePesterFailureCount.sourceConformance.pester.eventCount = 1
        $sourcePesterFailureCount.sourceConformance.pester.events = @([pscustomobject][ordered]@{
                eventId = $schemaRunId.ToString()
                toolId = 'custom-repository-test'
                outputSha256 = 'd' * 64
                testInventoryCount = 1
                testInventorySha256 = 'e' * 64
                total = 1
                passed = 1
                skipped = 0
                failed = 0
            })
        $sourcePesterFailureCount.sourceConformance.pester.outputSha256 = 'f' * 64
        $sourcePesterFailureCount.sourceConformance.pester.testInventoryCount = 1
        $sourcePesterFailureCount.sourceConformance.pester.testInventorySha256 = '1' * 64
        $sourcePesterFailureCount.sourceConformance.pester.total = 1
        $sourcePesterFailureCount.sourceConformance.pester.passed = 1
        $sourcePesterFailureCount.sourceConformance.pester.skipped = 0
        $sourcePesterFailureCount.sourceConformance.pester.failed = 1
        Assert-AuthoritySchemaInstance -Value $sourcePesterFailureCount -Schema $evidenceSchema -SchemaPath $script:StandardValidationEvidenceSchemaPath -Expected $false -Message 'A passed source projection with a nonzero aggregate failed count must fail schema validation.'
    }

    # Scenario: A consumer adds a renamed workflow, hook, or public command that runs a component validator directly.
    # Purpose: Keep one canonical validation execution per event/candidate while making the central authority workflow exceptions explicit.
    It 'UnitT95_binds_the_consumer_entry_point_inventory_and_authority_workflow_exceptions' {
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json
        $schema = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGateSchemaPath | ConvertFrom-Json
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardPath
        $validationContract = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardValidationContractPath | ConvertFrom-Json
        $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:IndexPath
        $matrix = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:MatrixPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        . $script:AuthorityGatePath -DefineFunctionsOnly

        Assert-True ($null -ne $policy.entryPointContract) 'Canonical validation/security policy must declare the consumer entry-point contract.'
        Assert-AuthoritySchemaInstance -Value $policy -Schema $schema -SchemaPath $script:ValidationSecurityGateSchemaPath -Expected $true -Message 'Entry-point contract policy must be schema-valid.'
        Assert-AuthorityValidationSecurityGate -Policy $policy | Out-Null

        $contract = $policy.entryPointContract
        Assert-ExactPropertySet $contract @('canonicalExecution', 'releaseAffectingSurfaces', 'publicCommandDocumentation', 'componentScripts', 'compatibilityLane', 'triggerAdapters', 'authorityWorkflowRoles') 'Entry-point contract property set changed.'
        Assert-Equal $contract.canonicalExecution.maxPerEventCandidate 1 'A consumer must have at most one canonical execution per event/candidate.'
        Assert-Equal $contract.canonicalExecution.route 'canonical-validator' 'All release-affecting consumer surfaces must route to the canonical validator.'
        Assert-True ([bool]$contract.canonicalExecution.sameCandidateBinding) 'Trigger adapters must bind the same event candidate.'
        Assert-True ([bool]$contract.canonicalExecution.samePassBlockSemantics) 'Trigger adapters must share canonical pass/block semantics.'
        Assert-Equal $contract.releaseAffectingSurfaces.workflowGlob '.github/workflows/*.{yml,yaml}' 'Consumer workflow inventory must cover both YAML extensions.'
        Assert-ExactStringSequence $contract.releaseAffectingSurfaces.hookRoots @('.git/hooks', '.githooks') 'Consumer hook inventory must list versioned and local hook roots.'
        Assert-ExactStringSequence $contract.releaseAffectingSurfaces.publicCommandFiles @('README.md', 'RELEASING.md', 'RELEASE.md', 'docs/RELEASE.md', 'docs/RELEASING.md') 'Public release command inventory must cover the documented entry-point files.'
        Assert-Equal $contract.releaseAffectingSurfaces.mustRouteTo 'canonical-validator' 'Release-affecting surfaces must route to the canonical validator.'
        Assert-Equal $contract.releaseAffectingSurfaces.alternateGateAction 'BLOCK' 'Consumer alternate gates must block closed.'
        Assert-True ([bool]$contract.releaseAffectingSurfaces.requiresFailurePropagation) 'Release-affecting surfaces must preserve canonical failure propagation.'
        Assert-ExactStringSequence $contract.releaseAffectingSurfaces.forbiddenFailureSuppression @('|| true', '|| :', 'continue-on-error: true', 'if: always()') 'Release-affecting surfaces must reject failure suppression.'
        Assert-ExactPropertySet $contract.publicCommandDocumentation @('mode', 'commandScope', 'unrelatedCanonicalAuthorizesRelease', 'setupAndDiagnosticsAreReleaseGates') 'Public command documentation policy shape changed.'
        Assert-Equal $contract.publicCommandDocumentation.mode 'consistency-only' 'Public command Markdown must remain a consistency check.'
        Assert-Equal $contract.publicCommandDocumentation.commandScope 'local-markdown-command-section' 'Public command consistency must stay within a local Markdown command section.'
        Assert-False ([bool]$contract.publicCommandDocumentation.unrelatedCanonicalAuthorizesRelease) 'A canonical command in an unrelated section must not authorize a release command.'
        Assert-False ([bool]$contract.publicCommandDocumentation.setupAndDiagnosticsAreReleaseGates) 'Setup and diagnostics must not become release gates.'
        Assert-True ([bool]$contract.componentScripts.mayExist) 'Component/diagnostic scripts must remain allowed.'
        Assert-False ([bool]$contract.componentScripts.mayBeTopLevelReleaseGate) 'Component scripts must not become public release gates.'
        Assert-True ([bool]$contract.compatibilityLane.allowed) 'Compatibility lanes must remain available for explicit legacy coverage.'
        Assert-True ([bool]$contract.compatibilityLane.requiresCanonicalDependency) 'Consumer compatibility status jobs must depend on the canonical result.'
        Assert-True ([bool]$contract.compatibilityLane.requiresRestrictedPurpose) 'Compatibility lanes must have a restricted purpose.'
        Assert-True ([bool]$contract.compatibilityLane.mayMirrorCanonicalResult) 'Compatibility status jobs may mirror the canonical result.'
        Assert-False ([bool]$contract.compatibilityLane.mayRunIndependentPassBlockPolicy) 'Consumer compatibility lanes must not own an independent pass/block policy.'
        Assert-False ([bool]$contract.compatibilityLane.mayBeCanonicalReleaseGate) 'Compatibility lanes must never become the canonical release gate.'
        Assert-ExactStringSequence $contract.triggerAdapters.allowedEvents @('pull_request', 'push', 'workflow_dispatch') 'Protected PR, trusted push, and manual trigger adapters must be explicit.'
        Assert-True ([bool]$contract.triggerAdapters.mustShareCanonicalValidator) 'Trigger adapters must share the canonical validator.'
        Assert-True ([bool]$contract.triggerAdapters.mustShareCandidateBinding) 'Trigger adapters must share candidate binding.'
        Assert-False ([bool]$contract.triggerAdapters.duplicateEventCandidateExecution) 'The same event/candidate must not execute the canonical validator twice.'

        $roles = @($contract.authorityWorkflowRoles)
        Assert-Equal $roles.Count 4 'The authority workflow exception inventory must contain exactly four roles.'
        Assert-ExactStringSequence ($roles | ForEach-Object { [string]$_.path }) @(
            '.github/workflows/standards-conformance.yml',
            '.github/workflows/pr8-powershell-validation.yml',
            '.github/workflows/syp86-production-lock.yml',
            '.github/workflows/syp101-production-smoke.yml'
        ) 'The authority workflow exception inventory must preserve all four workflow paths.'
        Assert-ExactStringSequence ($roles | ForEach-Object { [string]$_.role }) @(
            'canonical-authority-regression',
            'windows-core-authority',
            'production-lock-contract',
            'windows-install-smoke'
        ) 'The authority workflow exception roles must remain explicit and ordered.'
        foreach ($role in $roles) {
            Assert-False ([bool]$role.consumerAlternateGate) "Authority workflow '$($role.path)' must not be treated as a consumer alternate gate."
        }

        Assert-Match $standard 'one canonical validation execution per event/candidate' 'Normative Standard must prohibit duplicate canonical validation execution.'
        Assert-Match $standard 'workflow.*hook.*public' 'Normative Standard must define the release-affecting entry-point inventory.'
        Assert-Match $standard 'Public command Markdown.*local Markdown section' 'Normative Standard must scope public command documentation consistency to a local Markdown section.'
        Assert-Match $standard 'component.*MUST NOT.*release path' 'Normative Standard must keep component scripts non-authoritative.'
        Assert-Match $standard 'compatibility.*needs.*canonical|compatibility.*canonical.*result' 'Normative Standard must constrain compatibility lanes to the canonical result.'
        Assert-Match $index 'entry-point|canonical validation execution' 'Standards index must expose the entry-point contract.'
        Assert-Match $matrix 'entry-point|alternate gate|canonical validation execution' 'Review matrix must record the entry-point boundary.'
        Assert-Match $gate 'Assert-AuthorityConsumerEntryPointContract' 'The executable authority must expose the consumer entry-point contract checker.'
        Assert-Match $gate 'Get-AuthorityConsumerReleaseAffectingMatch -Text \$releaseExecutableText' 'Release ordering must use the same release-surface matcher as release detection.'

        Assert-ExactPropertySet $validationContract.entryPointContract @('policyPath', 'publicCommandDocumentationPolicyPath', 'documentationSemantics', 'executionBinding') 'Standard validation contract must link the prior entry-point fields and the versioned execution binding without defining another policy.'
        Assert-Equal $validationContract.entryPointContract.policyPath 'docs/standards/validation-security-gate.json#/entryPointContract' 'Standard validation contract must link to the canonical entry-point policy.'
        Assert-Equal $validationContract.entryPointContract.publicCommandDocumentationPolicyPath 'docs/standards/validation-security-gate.json#/entryPointContract/publicCommandDocumentation' 'Standard validation contract must link to the canonical public command documentation policy.'
        Assert-Equal $validationContract.entryPointContract.documentationSemantics 'consistency-only within each local Markdown command section; an unrelated canonical command does not authorize a release command; setup and diagnostics are not release gates' 'Standard validation contract must summarize the canonical documentation semantics.'

        $executionBinding = $validationContract.entryPointContract.executionBinding
        Assert-ExactPropertySet $executionBinding @('schemaVersion', 'bindingSchemaPath', 'resultSchemaPath', 'modulePath', 'commandPath', 'publicFunctions', 'bindingFields', 'inputInventoryRoots', 'resultSemantics', 'platformArtifactTrustBoundary', 'fixtureQualification', 'gatePreflightCommandPath', 'gatePreflightSemantics') 'Execution binding contract shape must remain explicit and versioned.'
        Assert-Equal $executionBinding.schemaVersion 1 'Execution binding contract must remain schema version 1.'
        Assert-Equal $executionBinding.bindingSchemaPath 'docs/standards/schemas/standard-entry-binding-v1.schema.json' 'Binding schema path must match the implementation contract.'
        Assert-Equal $executionBinding.resultSchemaPath 'docs/standards/schemas/standard-entry-result-v1.schema.json' 'Result schema path must match the implementation contract.'
        Assert-Equal $executionBinding.modulePath 'scripts/StandardEntryPointContract.psm1' 'Binding module path must match the implementation contract.'
        Assert-Equal $executionBinding.commandPath 'scripts/Test-StandardEntryPointResult.ps1' 'Result command path must match the implementation contract.'
        Assert-ExactStringSequence $executionBinding.publicFunctions @('Get-StandardEntryPointRuntime', 'New-StandardEntryPointBinding', 'Assert-StandardEntryPointBinding', 'Assert-StandardEntryPointResult') 'Only the fixed binding/result API must be public.'
        Assert-ExactStringSequence $executionBinding.bindingFields @('schemaVersion', 'entryId', 'eventName', 'candidateRevision', 'authorityRevision', 'runtime', 'configSha256', 'requiredChecks', 'resultArtifact', 'contentMode', 'inputFileManifest') 'The binding field inventory must remain exact.'
        Assert-ExactStringSequence $executionBinding.inputInventoryRoots @('scripts/', 'tests/', 'docs/standards/', '.github/workflows/') 'The bound input inventory roots must remain exact.'
        Assert-Match $executionBinding.resultSemantics 'releaseEligible is always false' 'A verified result must remain validation-only.'
        Assert-Match $executionBinding.platformArtifactTrustBoundary 'does not prove provider execution|does not prove' 'The local result must not be described as platform proof.'
        Assert-Match $executionBinding.fixtureQualification 'not release certification|not.*release certification' 'Fixture PASS must not become release certification.'

        $bindingSchemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-entry-binding-v1.schema.json'
        $resultSchemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-entry-result-v1.schema.json'
        $modulePath = Join-Path $script:RepositoryRoot 'scripts/StandardEntryPointContract.psm1'
        $commandPath = Join-Path $script:RepositoryRoot 'scripts/Test-StandardEntryPointResult.ps1'
        foreach ($requiredPath in @($bindingSchemaPath, $resultSchemaPath, $modulePath, $commandPath)) {
            Assert-True (Test-Path -LiteralPath $requiredPath -PathType Leaf) "Execution binding contract target must exist: $requiredPath"
        }
        $bindingSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $bindingSchemaPath | ConvertFrom-Json
        $resultSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath $resultSchemaPath | ConvertFrom-Json
        $bindingShape = ConvertTo-Json -InputObject $bindingSchema.'$defs'.entryBinding -Depth 24 -Compress
        $resultBindingShape = ConvertTo-Json -InputObject $resultSchema.'$defs'.entryBinding -Depth 24 -Compress
        Assert-Equal $bindingShape $resultBindingShape 'The result schema must inline the exact binding shape so local schema validation uses one shared contract.'
        Assert-ExactPropertySet $bindingSchema.'$defs'.entryBinding @('title', 'description', 'type', 'additionalProperties', 'required', 'properties') 'Binding schema object shape changed.'
        Assert-ExactPropertySet $resultSchema.properties @('schemaVersion', 'binding', 'status', 'executed', 'releaseEligible', 'checks') 'Result schema property inventory changed.'
        Assert-Match $standard '8\.1\.3 Versioned execution binding and result core' 'Normative Standard must document the versioned binding/result core.'
        Assert-Match $standard 'does not independently prove provider execution' 'Normative Standard must preserve the platform-artifact trust boundary.'
        Assert-Match $standard 'Repository fixtures verify only the declared local contract' 'Normative Standard must qualify fixture evidence.'

        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'gh api repos/{owner}/{repo}/releases -f tag_name=v1.0.0') 'A gh api release creation with fields must be release-affecting.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'gh api repos/{owner}/{repo}/releases --method PATCH --raw-field name=v1.0.0') 'An explicit mutating gh api release request must be release-affecting.'
        Assert-False (Test-AuthorityConsumerReleaseAffectingCommand -Text 'gh api repos/{owner}/{repo}/releases') 'A read-only gh api release lookup must not be classified as a mutation.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'git push origin v1.2.3') 'A direct tag refspec passed to git push must be release-affecting.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'git push origin') 'An explicit git push whose ref type cannot be established must fail closed.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'git push --mirror') 'A mirror push must be release-affecting because it can publish tag refs.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text "uses: docker/build-push-action@0123456789012345678901234567890123456789`nwith:`n  push: true") 'A Docker build-push action must be release-affecting because its push input can publish an image.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'uses: vendor/release-action@v1') 'A release action with an explicit ref must remain release-affecting.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text "uses: 'vendor/publish-action@v2'") 'A quoted publish action with an explicit ref must remain release-affecting.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'uses: vendor/action/deploy@v3') 'A nested deploy action with an explicit ref must remain release-affecting.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'uses: vendor/release-action/dist@v1') 'A release-marked action repository with a nested action path must remain release-affecting.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text "uses: 'vendor/publish-action/subdir@v2'") 'A quoted publish-marked action repository with a nested action path must remain release-affecting.'
        Assert-False (Test-AuthorityConsumerReleaseAffectingCommand -Text 'uses: vendor/release-action/dist') 'A release-marked action repository without an explicit ref must not be treated as a complete action identity.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'docker buildx build --platform linux/amd64 --push .') 'A Docker buildx build with --push must be release-affecting because it publishes an image.'
        $quotedStableRuntimeUrl = @'
- shell: pwsh
  run: |
    Invoke-WebRequest -Uri 'https://aka.ms/powershell-release?tag=stable'
'@
        $quotedStableRuntimeExecutable = Get-AuthorityConsumerExecutableText -Text $quotedStableRuntimeUrl
        Assert-False (Test-AuthorityConsumerReleaseAffectingCommand -Text $quotedStableRuntimeExecutable) 'A stable PowerShell release URL used as download data must not be classified as a release command.'
        $interpolatedUrlWithPublish = 'Invoke-WebRequest -Uri "https://example.test/$(npm publish)"'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text $interpolatedUrlWithPublish) 'A publish command inside a double-quoted URL subexpression must remain release-affecting.'
        $backtickUrlWithTagPush = 'curl "https://example.test/`git push --tags`"'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text $backtickUrlWithTagPush) 'A tag push inside a double-quoted URL command substitution must remain release-affecting.'
        $quotedExecutableWithTagPush = "Invoke-Expression 'https://example.test/foo; git push --tags'"
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text $quotedExecutableWithTagPush) 'A tag push after a URL inside executable quoted text must remain release-affecting.'
        $publishAfterUrl = "Invoke-WebRequest -Uri 'https://aka.ms/powershell-release?tag=stable'; npm publish"
        $publishAfterUrlMatch = Get-AuthorityConsumerReleaseAffectingMatch -Text $publishAfterUrl
        Assert-True $publishAfterUrlMatch.Success 'A real npm publish command after a release-looking URL must remain release-affecting.'
        Assert-Equal $publishAfterUrlMatch.Index $publishAfterUrl.IndexOf('npm publish') 'Filtering URL data must preserve release-command source offsets.'
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'make deploy') 'A real deploy command must remain release-affecting.'
        $unquotedUrlBeforePublish = 'Invoke-WebRequest -Uri https://aka.ms/powershell-release?tag=stable;npm publish'
        $adjacentPublishMatch = Get-AuthorityConsumerReleaseAffectingMatch -Text $unquotedUrlBeforePublish
        Assert-True $adjacentPublishMatch.Success 'An adjacent semicolon must end an unquoted URL before a real publish command.'
        Assert-Equal $adjacentPublishMatch.Index $unquotedUrlBeforePublish.IndexOf('npm publish') 'An adjacent semicolon and URL mask must preserve the publish command offset.'
        $unquotedUrlBeforeDeploy = 'Invoke-WebRequest -Uri https://aka.ms/powershell-release?tag=stable|make deploy'
        $pipedDeployMatch = Get-AuthorityConsumerReleaseAffectingMatch -Text $unquotedUrlBeforeDeploy
        Assert-True $pipedDeployMatch.Success 'A pipeline separator must end an unquoted URL before a real deploy command.'
        Assert-Equal $pipedDeployMatch.Index $unquotedUrlBeforeDeploy.IndexOf('make deploy') 'A pipeline separator and URL mask must preserve the deploy command offset.'
        Assert-True ([bool](Test-AuthorityConsumerCanonicalInvocation -Text './scripts/Validate.ps1' -CanonicalRelativePath 'scripts/Validate.ps1')) 'A direct canonical validator command must count as an invocation.'
        Assert-True ([bool](Test-AuthorityConsumerCanonicalInvocation -Text 'pwsh -File ./scripts/Validate.ps1' -CanonicalRelativePath 'scripts/Validate.ps1')) 'A canonical validator launched through pwsh -File must count as an invocation.'
        Assert-False ([bool](Test-AuthorityConsumerCanonicalInvocation -Text 'Get-Item ./scripts/Validate.ps1' -CanonicalRelativePath 'scripts/Validate.ps1')) 'Reading the canonical validator path must not count as executing it.'

        $implicitSuccessJob = @'
  release:
    needs: canonical
    run: gh release create v1.0.0
'@
        Assert-True (Test-AuthorityConsumerJobNeedsCanonical -JobText $implicitSuccessJob -CanonicalJobId 'canonical') 'A release job without an override condition must inherit canonical success gating.'
        $explicitSuccessJob = @'
  release:
    needs: canonical
    if: ${{ needs.canonical.result == 'success' }}
    run: gh release create v1.0.0
'@
        Assert-True (Test-AuthorityConsumerJobNeedsCanonical -JobText $explicitSuccessJob -CanonicalJobId 'canonical') 'A release job may use an explicit canonical-success condition.'
        $failureConditionJob = @'
  release:
    needs: canonical
    if: ${{ needs.canonical.result == 'failure' }}
    run: gh release create v1.0.0
'@
        Assert-False (Test-AuthorityConsumerJobNeedsCanonical -JobText $failureConditionJob -CanonicalJobId 'canonical') 'A release job must not run when the canonical validator fails.'

        $weakened = Copy-TestJsonObject -Value $policy
        $weakened.entryPointContract.canonicalExecution.maxPerEventCandidate = 2
        Assert-AuthoritySchemaInstance -Value $weakened -Schema $schema -SchemaPath $script:ValidationSecurityGateSchemaPath -Expected $false -Message 'A policy allowing two canonical executions per event/candidate must fail schema validation.'
        $errorMessage = $null
        try { Assert-AuthorityValidationSecurityGate -Policy $weakened | Out-Null }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'entry-point|canonical execution|event/candidate' 'The executable authority must reject a weakened entry-point contract.'
    }

    # Scenario: Cleanup retains artifacts after a canonical/release job, without changing either command's exit behavior.
    # Purpose: Scope failure suppression to authoritative commands rather than unrelated cleanup steps or jobs.
    It 'UnitT96_scopes_workflow_failure_propagation_to_canonical_and_release_steps' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $workflow = @'
on: push
jobs:
  canonical:
    steps:
      - run: ./scripts/Validate.ps1
      - name: Retain diagnostics
        if: ${{ always() }}
        run: echo retained
  release:
    needs: canonical
    steps:
      - run: gh release create v1.0.0
  cleanup:
    if: ${{ always() }}
    steps:
      - run: echo cleanup
  observer:
    if: ${{ always() }}
    steps:
      - name: Observe Stage 4 scanner evidence (diagnostic)
        shell: pwsh
        run: |
          $inventory = @(
            'references/publish-plan.schema.json',
            'scripts/ConfluencePublish.psm1'
          )
          Write-Output ($inventory -join ', ')
'@
        Assert-AuthorityConsumerReleaseFailurePropagation -WorkflowPath 'fixture.yml' -Text $workflow -CanonicalRelativePath 'scripts/Validate.ps1'
        foreach ($unsafe in @(
            $workflow.Replace('- run: ./scripts/Validate.ps1', "- continue-on-error: true`n        run: ./scripts/Validate.ps1"),
            $workflow.Replace('- run: gh release create v1.0.0', "- if: `${{ always() }}`n        run: gh release create v1.0.0"),
            $workflow.Replace('- run: gh release create v1.0.0', "- uses: vendor/release-action@v1`n        if: `${{ always() }}"),
            $workflow.Replace('- run: gh release create v1.0.0', "- uses: vendor/release-action/dist@v1`n        if: `${{ always() }}"),
            $workflow.Replace('- run: gh release create v1.0.0', "- uses: 'vendor/publish-action/subdir@v2'`n        if: `${{ always() }}"),
            $workflow.Replace('- run: gh release create v1.0.0', "- continue-on-error: true`n        uses: 'vendor/publish-action@v2'"),
            $workflow.Replace('run: ./scripts/Validate.ps1', 'run: ./scripts/Validate.ps1 || true'),
            $workflow.Replace('  canonical:', "  canonical:`n    continue-on-error: true"),
            $workflow.Replace('  release:', "  release:`n    if: `${{ always() }}")
        )) {
            $failure = $null
            try { Assert-AuthorityConsumerReleaseFailurePropagation -WorkflowPath 'fixture.yml' -Text $unsafe -CanonicalRelativePath 'scripts/Validate.ps1' }
            catch { $failure = $_.Exception.Message }
            Assert-True (-not [string]::IsNullOrWhiteSpace($failure)) 'Canonical/release suppression must remain blocked.'
        }

        foreach ($helperStep in @(
            '      - run: ./scripts/publish.ps1',
            "      - shell: pwsh`n        run: ./scripts/publish.ps1",
            "      - shell: pwsh`n        run: & './scripts/publish.ps1'",
            "      - shell: custom-shell {0}`n        run: ./scripts/publish.ps1"
        )) {
            $helperWorkflow = "on: push`njobs:`n  publish:`n    steps:`n$helperStep`n"
            $helperFailure = $null
            try { Assert-AuthorityConsumerReleaseFailurePropagation -WorkflowPath 'fixture.yml' -Text $helperWorkflow -CanonicalRelativePath 'scripts/Validate.ps1' }
            catch { $helperFailure = $_.Exception.Message }
            Assert-Match $helperFailure 'opaque local release helper' 'Existing direct, PowerShell, quoted, and unknown-runner publish helpers must remain fail-closed.'
        }
    }

    # Scenario: A head-bound check reporter derives success solely from every required dependency result.
    # Purpose: Distinguish verified check-runs reporting from arbitrary API mutations and fake-success reports.
    It 'UnitT97_recognizes_only_complete_head_bound_check_reporting' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $job = @'
  report:
    needs: [canonical]
    if: ${{ always() }}
    steps:
      - shell: bash
        env:
          HEAD_SHA: ${{ github.event_name == 'pull_request_target' && github.event.pull_request.head.sha || github.event_name == 'push' && github.sha || '' }}
          CANONICAL_RESULT: ${{ needs['canonical'].result }}
        run: |
          set -euo pipefail
          if [[ ! "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
            echo 'Invalid head.' >&2
            exit 1
          fi
          conclusion='failure'
          if [[ "$CANONICAL_RESULT" == 'success' ]]; then
            conclusion='success'
          fi
          details_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
          for check_name in \
            'required-check'; do
            gh api --method POST "repos/$GITHUB_REPOSITORY/check-runs" \
              -f name="$check_name" \
              -f head_sha="$HEAD_SHA" \
              -f status=completed \
              -f conclusion="$conclusion" \
              -f details_url="$details_url" >/dev/null
          done
'@
        Assert-True (Test-AuthorityConsumerHeadCheckReport -JobText $job) 'Exact head/result-bound check reporting must be recognized.'
        Assert-True (Test-AuthorityConsumerHeadCheckReport -JobText $job.Replace("`r`n", "`n").Replace("`n", "`r`n")) 'CRLF check-report metadata must preserve the exact same head/result binding.'
        Assert-True (Test-AuthorityConsumerHeadCheckReport -JobText $job.Replace('needs: [canonical]', "needs:`n      - canonical")) 'Multiline needs must preserve the same exact result binding.'
        foreach ($unsafe in @(
            $job.Replace('/check-runs', '/releases'),
            $job.Replace('head_sha="$HEAD_SHA"', 'head_sha="unbound"'),
            $job.Replace("conclusion='failure'", "conclusion='success'"),
            $job.Replace('needs[''canonical''].result', '''success'''),
            $job.Replace('gh api --method POST', 'HEAD_SHA=fake; gh api --method POST'),
            $job.Replace('>/dev/null', '>/dev/null || true'),
            $job.Replace('env:', "env:`n          BASH_ENV: malicious.sh"),
            $job.Replace('    steps:', "    env:`n      BASH_ENV: malicious.sh`n    steps:"),
            $job.Replace('- shell: bash', "- continue-on-error: true`n        shell: bash"),
            $job.Replace('conclusion="$conclusion"', 'conclusion=success')
        )) {
            Assert-False (Test-AuthorityConsumerHeadCheckReport -JobText $unsafe) 'Wrong endpoint/head/result or swallowed API failure must remain unverified.'
        }
        Assert-True (Test-AuthorityConsumerReleaseAffectingCommand -Text 'gh api --method POST "repos/$GITHUB_REPOSITORY/check-runs" -f conclusion=success') 'A bare unverified check-runs request must still fail closed.'
    }

    # Scenario: A supervisor materialized from event-bound Git blobs invokes the canonical path via a local PowerShell variable.
    # Purpose: Count real dynamic execution once while rejecting changed provenance, path overwrite, inspection, and duplicate calls.
    It 'UnitT98_counts_verified_base_owned_dynamic_canonical_invocations' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $workflow = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/PR41-protected-workflow.yml')
        Assert-Equal (Get-AuthorityConsumerVerifiedDynamicCanonicalCount -Text $workflow -CanonicalRelativePath 'scripts/Validate.ps1') 1 'Reviewed dynamic canonical execution must count once.'
        foreach ($unsafe in @(
            $workflow.Replace("ref: `${{ github.event_name == 'pull_request_target' && github.event.pull_request.head.sha || github.sha }}", 'ref: ${{ github.sha }}'),
            $workflow.Replace("          ref: `${{ github.event_name == 'pull_request_target' && github.event.pull_request.head.sha || github.sha }}`r`n", '').Replace("          ref: `${{ github.event_name == 'pull_request_target' && github.event.pull_request.head.sha || github.sha }}`n", ''),
            $workflow.Replace('TRUSTED_SUPERVISOR_COMMIT: ${{ github.sha }}', "PATH: `${{ github.workspace }}/bin:/usr/bin:/bin`n          TRUSTED_SUPERVISOR_COMMIT: `${{ github.sha }}"),
            $workflow.Replace('        shell: pwsh', '        shell: candidate-shell {0}'),
            $workflow.Replace('TRUSTED_SUPERVISOR_COMMIT: ${{ github.sha }}', 'TRUSTED_SUPERVISOR_COMMIT: ${{ github.event.pull_request.head.sha }}'),
            $workflow.Replace('      - name: Set up approved Go runtime', "      - shell: bash`n        run: echo 'exit 0' > `"`$RUNNER_TEMP/standard-v1-trusted-supervisor/scripts/Validate.ps1`"`n`n      - name: Set up approved Go runtime"),
            $workflow.Replace('TRUSTED_SUPERVISOR_COMMIT: ${{ github.sha }}', "GITHUB_ENV: ignored.env`n          TRUSTED_SUPERVISOR_COMMIT: `${{ github.sha }}"),
            $workflow.Replace('      - name: Materialize protected validation supervisor', "      - if: false`n        name: Materialize protected validation supervisor"),
            $workflow.Replace('      - name: Materialize protected validation supervisor', "      - shell: bash`n        run: echo candidate/bin >> `"`$GITHUB_PATH`"`n`n      - name: Materialize protected validation supervisor"),
            $workflow.Replace('PUSH_BEFORE_SHA: ${{ github.event.before }}', 'push_before_sha: ${{ github.event.before }}'),
            $workflow.Replace('        id: canonical-validation', "        id: canonical-validation`n        if: false"),
            $workflow.Replace('    name: Darktide Translate Standard v1', "    name: Darktide Translate Standard v1`n    env:`n      TRUSTED_SUPERVISOR_ROOT: candidate"),
            $workflow.Replace("Join-Path `$env:TRUSTED_SUPERVISOR_ROOT 'scripts/Validate.ps1'", "Join-Path `$env:GITHUB_WORKSPACE 'scripts/Validate.ps1'"),
            $workflow.Replace('& $trustedValidator @validatorArguments', '$trustedValidator = ''candidate.ps1''; & $trustedValidator @validatorArguments'),
            $workflow.Replace('& $trustedValidator @validatorArguments', "`$validatorArguments['RepositoryRoot']='other'; & `$trustedValidator @validatorArguments"),
            $workflow.Replace('& $trustedValidator @validatorArguments', "Set-Variable trustedValidator 'candidate.ps1'; & `$trustedValidator @validatorArguments"),
            $workflow.Replace('& $trustedValidator @validatorArguments', "Set-Item variable:trustedValidator 'candidate.ps1'; & `$trustedValidator @validatorArguments"),
            $workflow.Replace('"STANDARD_GO_RUNTIME_VERSION=$($Matches.version)"', ('$Matches.version = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''MS4yLjMKVFJVU1RFRF9TVVBFUlZJU09SX1JPT1Q9Y2FuZGlkYXRl''))' + "`n          " + '"STANDARD_GO_RUNTIME_VERSION=$($Matches.version)"')),
            $workflow.Replace('          cgroup_delegated="$cgroup_parent/delegated"', "          cgroup_delegated='injected'`n          cgroup_delegated=`"`$cgroup_parent/delegated`""),
            $workflow.Replace('& $trustedValidator @validatorArguments', 'Get-Item $trustedValidator'),
            $workflow.Replace('& $trustedValidator @validatorArguments', 'if ($false) { & $trustedValidator @validatorArguments }'),
            $workflow.Replace('& $trustedValidator @validatorArguments', '& $trustedValidator @validatorArguments -RepositoryRoot candidate-other'),
            $workflow.Replace(".Add('blob')", ".Add('commit')"),
            $workflow.Replace('[IO.FileMode]::CreateNew', '[IO.FileMode]::Create'),
            $workflow.Replace('& $trustedValidator @validatorArguments', 'echo ''& $trustedValidator @validatorArguments''')
        )) {
            Assert-Equal (Get-AuthorityConsumerVerifiedDynamicCanonicalCount -Text $unsafe -CanonicalRelativePath 'scripts/Validate.ps1') 0 'Unknown or contaminated dynamic construction must not count as canonical.'
        }
        $duplicate = $workflow.Replace('& $trustedValidator @validatorArguments', "& `$trustedValidator @validatorArguments`n          & `$trustedValidator @validatorArguments")
        Assert-Equal (Get-AuthorityConsumerVerifiedDynamicCanonicalCount -Text $duplicate -CanonicalRelativePath 'scripts/Validate.ps1') 2 'Two actual canonical calls must remain visible to the once-only guard.'
        $crlfSource = (Get-Content -Raw -LiteralPath $script:AuthorityGatePath).Replace("`r`n", "`n").Replace("`n", "`r`n")
        . ([scriptblock]::Create($crlfSource)) -DefineFunctionsOnly
        Assert-Equal (Get-AuthorityConsumerVerifiedDynamicCanonicalCount -Text $workflow -CanonicalRelativePath 'scripts/Validate.ps1') 1 'A CRLF checkout of the actual classifier must recognize the same reviewed construction.'
    }

    # Scenario: The full PR41 fixture uses a base-owned supervisor and one PR candidate, while mutations attempt bypass or duplicate routing.
    # Purpose: Verify the actual entry-point contract rather than only individual classifiers.
    It 'UnitT99_preserves_full_protected_PR_candidate_and_failure_propagation_semantics' {
        . $script:AuthorityGatePath -DefineFunctionsOnly
        $workflow = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/PR41-protected-workflow.yml')
        $root = Join-Path $TestDrive 'protected-fixture'
        $inspection = $workflow + "`n  inspect:`n    steps:`n      - shell: pwsh`n        run: Write-Output '& `$alternate'`n"
        Assert-False (Test-AuthorityConsumerWorkflowNonCanonicalValidationCommand -Text $inspection -CanonicalRelativePath 'scripts/Validate.ps1') 'Printing a dynamic command is not an actual invocation.'
        [void](New-Item -ItemType Directory -Path (Join-Path $root '.github/workflows') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force)
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Validate.ps1'), '# canonical fixture path')
        $workflowPath = Join-Path $root '.github/workflows/protected.yml'
        $policy = Get-Content -Raw $script:ValidationSecurityGatePath | ConvertFrom-Json
        [IO.File]::WriteAllText($workflowPath, $workflow)
        Assert-AuthorityConsumerEntryPointContract -RepositoryRoot $root -CanonicalValidatorPath 'scripts/Validate.ps1' -Policy $policy
        $report = @(Get-AuthorityConsumerWorkflowJobs -Text $workflow) | Where-Object id -eq 'publish-head-required-checks'
        $unboundReport = ([string]$report.text).Replace('  publish-head-required-checks:', '  unbound-report:').Replace("HEAD_SHA: `${{ github.event_name == 'pull_request_target' && github.event.pull_request.head.sha || github.event_name == 'push' && github.sha || '' }}", 'HEAD_SHA: unbound')
        foreach ($unsafe in @(
            ($workflow + "`n  duplicate:`n    steps:`n      - shell: pwsh`n        run: |`n          . './scripts/Validate.ps1'`n"),
            ($workflow + "`n  duplicate:`n    steps:`n      - shell: pwsh`n        run: |`n          & './scripts/Validate.ps1'`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          & Invoke-Pester`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          & 'Invoke-Pester'`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          & './tests/AlternateValidation.ps1'`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          `$alternate = './tests/AlternateValidation.ps1'`n          & `"`$alternate`"`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          `$alternate = './tests/AlternateValidation.ps1'`n          & `${alternate}`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          `$alternate = './tests/AlternateValidation.ps1'`n          & `$alternate`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          `$alternate = './tests/AlternateValidation.ps1'`n          `$result = & `$alternate`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          . `$unknownValidator`n"),
            ($workflow + "`n  alternate:`n    steps:`n      - shell: pwsh`n        run: |`n          & (Join-Path `$env:GITHUB_WORKSPACE 'tests/AlternateValidation.ps1')`n"),
            $workflow.Replace('& $windowsPowerShellPath @protectedContractArguments', "`$alternate = './tests/AlternateValidation.ps1'; & `$alternate"),
            ($workflow + "`n" + $unboundReport),
            ($workflow + "`n  unverified-dynamic:`n    steps:`n      - shell: pwsh`n        run: |`n          `$trustedValidator = './candidate.ps1'`n          & `$trustedValidator @validatorArguments`n"),
            $workflow.Replace('& $trustedValidator @validatorArguments', "gh release create v1.0.0`n          & `$trustedValidator @validatorArguments"),
            $workflow.Replace('& $trustedValidator @validatorArguments', "& `$trustedValidator @validatorArguments`n          gh release create v1.0.0"),
            $workflow.Replace('& $trustedValidator @validatorArguments', '& $trustedValidator @validatorArguments || true'),
            $workflow.Replace('id: canonical-validation', "id: canonical-validation`n        continue-on-error: true"),
            $workflow.Replace('  pull_request_target:', "  pull_request_target:`n  pull_request:"),
            $workflow.Replace('TRUSTED_SUPERVISOR_COMMIT: ${{ github.sha }}', 'TRUSTED_SUPERVISOR_COMMIT: ${{ github.event.pull_request.head.sha }}'),
            $workflow.Replace("CANONICAL_RESULT: `${{ needs['canonical-validation'].result }}", "CANONICAL_RESULT: `${{ needs['upload-canonical-validation-evidence'].result }}"),
            $workflow.Replace('& $trustedValidator @validatorArguments', "& `$trustedValidator @validatorArguments`n          ./tests/AlternateValidation.ps1")
        )) {
            [IO.File]::WriteAllText($workflowPath, $unsafe)
            $failure = $null
            try { Assert-AuthorityConsumerEntryPointContract -RepositoryRoot $root -CanonicalValidatorPath 'scripts/Validate.ps1' -Policy $policy }
            catch { $failure = $_.Exception.Message }
            Assert-True (-not [string]::IsNullOrWhiteSpace($failure)) 'A full-workflow bypass must fail the entry-point contract.'
        }
    }

    # Scenario: PowerShell returns JSON integers as Int64 on some Linux/runtime combinations.
    # Purpose: Keep the upstream adapter report contract cross-platform without accepting coercive strings.
    It 'UnitT91_accepts_Int64_upstream_adapter_report_schema_version' {
        . $script:AuthorityGatePath -DefineFunctionsOnly

        $report = [pscustomobject][ordered]@{
            schemaVersion = [int64]1
            policy = 'upstream-interoperability-adapter-v1'
            adapterVersion = 'upstream-interoperability-adapter-v1'
            status = 'not-applicable'
            decision = 'NOT_APPLICABLE'
        }
        Assert-True (Assert-AuthorityUpstreamAdapterReport -Report $report) 'An Int64 schemaVersion=1 adapter report must pass validation.'

        $report.schemaVersion = '1'
        $errorMessage = $null
        try { Assert-AuthorityUpstreamAdapterReport -Report $report | Out-Null }
        catch { $errorMessage = $_.Exception.Message }
        Assert-Match $errorMessage 'invalid result' 'A string schemaVersion must remain fail-closed.'
    }

    Context 'Authority gate preflight contract' {
        # Scenario: The versioned contract advertises the shipped authority gate and its explicit preflight semantics.
        # Purpose: Bind descriptor claims to the actual gate parameters, trusted module path, diagnostic-only branch, and pre-tool ordering.
        It 'UnitT10_binds_the_actual_gate_to_explicit_preflight_semantics' {
            $validationContract = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:StandardValidationContractPath | ConvertFrom-Json
            $executionBinding = $validationContract.entryPointContract.executionBinding
            Assert-ExactPropertySet $executionBinding @('schemaVersion', 'bindingSchemaPath', 'resultSchemaPath', 'modulePath', 'commandPath', 'publicFunctions', 'bindingFields', 'inputInventoryRoots', 'resultSemantics', 'platformArtifactTrustBoundary', 'fixtureQualification', 'gatePreflightCommandPath', 'gatePreflightSemantics') 'Execution binding contract must add only the declared gate preflight descriptor fields.'
            Assert-Equal $executionBinding.gatePreflightCommandPath 'scripts/Invoke-StandardAuthorityGate.ps1' 'Preflight descriptor must name the shipped authority gate.'
            Assert-Equal $executionBinding.gatePreflightSemantics 'Explicit candidate/authority roots and full revisions are required before tools; BindingOnly emits a binding diagnostic, never an executed passed result or a success artifact.' 'Preflight descriptor must preserve the diagnostic-only semantics.'

            $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
            $parameterBlockEnd = $gate.IndexOf('Set-StrictMode', [StringComparison]::Ordinal)
            Assert-True ($parameterBlockEnd -gt 0) 'Authority gate must retain its explicit parameter block.'
            $parameterBlock = $gate.Substring(0, $parameterBlockEnd)
            foreach ($parameterPattern in @(
                    '\[string\]\s+\$CandidateRoot',
                    '\[string\]\s+\$AuthorityRoot',
                    '\[string\]\s+\$CandidateRevision',
                    '\[string\]\s+\$AuthorityRevision',
                    '\[string\]\s+\$EventName',
                    '\[string\]\s+\$ResultArtifact',
                    '\[switch\]\s+\$AllowDevelopmentContent',
                    '\[switch\]\s+\$BindingOnly'
                )) {
                Assert-Match $parameterBlock $parameterPattern 'Authority gate must expose each explicit preflight input.'
            }
            Assert-NotMatch $parameterBlock '\$RequiredChecks' 'Callers must not expand the fixed required-check set.'

            $functionsOnlyReturn = $gate.IndexOf('if ($DefineFunctionsOnly) { return }', [StringComparison]::Ordinal)
            $preflightCall = $gate.IndexOf('$authorityEntryBinding = Get-AuthorityEntryPreflight', [StringComparison]::Ordinal)
            $pesterDiscovery = $gate.IndexOf('$pesterModules = @(Get-Module -ListAvailable -Name Pester', [StringComparison]::Ordinal)
            Assert-True ($functionsOnlyReturn -ge 0 -and $preflightCall -gt $functionsOnlyReturn -and $pesterDiscovery -gt $preflightCall) 'Preflight must follow DefineFunctionsOnly and precede pinned Pester discovery.'
            $ordinaryGate = $gate.Substring($gate.IndexOf('if ($BindingOnly) {', [StringComparison]::Ordinal))
            Assert-NotMatch $ordinaryGate 'expectedGoRuntimeVersion|STANDARD_GO_RUNTIME_VERSION|STANDARD_GO_COMMAND_PATH' 'The ordinary authority gate must not require a Go runtime.'
            Assert-Match $gate 'Join-Path \$candidateFullRoot ''scripts/Invoke-StandardAuthorityGate\.ps1''' 'The running gate must be compared with the claimed candidate path.'
            Assert-Match $gate 'Import-Module -Name \$candidateModulePath -Force -PassThru' 'The binding module must load from the candidate root.'
            Assert-Match $gate '\[string\]::Equals\(\$loadedModulePath, \$candidateModulePath, \$pathComparison\)' 'The loaded binding module path must be verified.'
            Assert-Match $gate 'RequiredChecks = @\(''Standard v1 authority gate''\)' 'The authority entry point must bind its fixed singleton check.'
            Assert-Match $gate '\[void\]\(Assert-StandardEntryPointBinding -Binding \$binding\)' 'Successful binding verification must not leak a Boolean to stdout.'
            Assert-Match $gate 'binding = \$authorityEntryBinding' 'The ordinary result must carry the verified candidate and authority binding.'

            $bindingOnlyStart = $gate.IndexOf('if ($BindingOnly) {', [StringComparison]::Ordinal)
            $mainStart = $gate.IndexOf('$repositoryRoot =', $bindingOnlyStart, [StringComparison]::Ordinal)
            Assert-True ($bindingOnlyStart -ge 0 -and $mainStart -gt $bindingOnlyStart) 'BindingOnly must have a bounded pre-tool return branch.'
            $bindingOnlyBranch = $gate.Substring($bindingOnlyStart, $mainStart - $bindingOnlyStart)
            Assert-Match $bindingOnlyBranch "type = 'standard-entry-point-binding-diagnostic'" 'BindingOnly must emit a typed binding diagnostic.'
            Assert-NotMatch $bindingOnlyBranch 'Set-Content|WriteAllText|New-Item|Move-Item|Copy-Item' 'BindingOnly must not create a result or success artifact.'
        }
    }
}
Describe 'Third-party raw Skill authority contract' {
    # Scenario: Raw third-party ownership is explicitly adapted by central policy.
    # Purpose: Preserve source tools and security gates while avoiding fabricated upstream metadata.
    It 'UnitT10_keeps_raw_ownership_separate_from_source_validation_and_release' {
        $root=Split-Path -Parent $PSScriptRoot
        $standard=Get-Content -Raw (Join-Path $root 'docs/standards/skill-repository-standard.md')
        $raw=Get-Content -Raw (Join-Path $root 'docs/standards/third-party-raw-skill-sources.md')
        $standard | Should Match 'third-party-raw-skill-sources.md'
        $raw | Should Match 'releaseEligible=false'
        $raw | Should Match '-SourceValidation'
        $raw | Should Match 'skill-validator'
        $raw | Should Match 'SkillSpector Static'
        $raw | Should Match 'Human Approval'
        $raw | Should Match 'Source-only checks.*MUST NOT.*require adoption approval before collecting source evidence'
        $raw | Should Match 'candidate/pending descriptor.*MUST.*eligible.*-SourceValidation'
        $raw | Should Match 'adoptionApproved=false'
    }
}
# The same authority regression entry executes actual adapter behavior and negative fixtures.
. (Join-Path $PSScriptRoot 'third-party-skill-source.Tests.ps1')
. (Join-Path $PSScriptRoot 'third-party-source-envelope.Tests.ps1')

Describe 'Third-party source Pester case evidence' {
    BeforeAll {
        $entry=Join-Path $PSScriptRoot '../scripts/Invoke-ThirdPartySourceChecks.ps1'
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
        if (@($errors).Count) {throw 'The source Pester evidence entry must parse.'}
        $function=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-ThirdPartySourcePesterCase'},$true))
        if ($function.Count -ne 1) {throw 'The actual case evidence function must exist exactly once.'}
        . ([scriptblock]::Create($function[0].Extent.Text))
    }
    # Scenario: A discovered Pester test supplies its actual script block and expanded result identity.
    # Purpose: Bind case identity to real file/offset metadata rather than a fixed counter or invented file.
    It 'UnitT10_records_the_actual_source_block_and_expanded_case_identity' {
        $block={ 'inert case fixture' }
        $test=[pscustomobject]@{ScriptBlock=$block;ExpandedPath='Fixture.UnitT10';Result='Passed'}
        $file=[IO.Path]::GetFileName($block.Ast.Extent.File)
        $case=New-ThirdPartySourcePesterCase -Test $test -TestRoot $PSScriptRoot -TestFiles @($file)
        $tuple=[Text.UTF8Encoding]::new($false).GetString([Convert]::FromBase64String($case.identity)) | ConvertFrom-Json
        if ($tuple[0] -cne $file.ToUpperInvariant() -or $tuple[1] -ne $block.Ast.Extent.StartOffset -or $tuple[2] -cne $test.ExpandedPath -or $case.result -cne 'Passed') {throw 'Case identity does not bind the actual Pester result metadata.'}
    }
    # Scenario: A test has an empty expanded name, foreign source root or missing script block.
    # Purpose: Fail source evidence recording instead of assigning fabricated identities to incomplete metadata.
    It 'UnitT20_rejects_missing_or_foreign_Pester_case_metadata' {
        $block={ 'inert case fixture' }
        $file=[IO.Path]::GetFileName($block.Ast.Extent.File)
        foreach ($bad in @(
            @{Test=[pscustomobject]@{ScriptBlock=$block;ExpandedPath='';Result='Passed'};Root=$PSScriptRoot},
            @{Test=[pscustomobject]@{ScriptBlock=$block;ExpandedPath='Fixture';Result='Passed'};Root=$TestDrive},
            @{Test=[pscustomobject]@{ScriptBlock=$null;ExpandedPath='Fixture';Result='Passed'};Root=$PSScriptRoot}
        )) {
            $rejected=$false
            try {New-ThirdPartySourcePesterCase -Test $bad.Test -TestRoot $bad.Root -TestFiles @($file) | Out-Null} catch {$rejected=$true}
            if (-not $rejected) {throw 'Incomplete or foreign case metadata was accepted.'}
        }
    }
}

Describe 'Windows-only support description scope' -Tag 'WindowsOnlyDescriptionScope' {
    # Scenario: The Standard scope omits consumer CI, includes deployment targets, or reaches test and historical source text.
    # Purpose: Keep only the support and owned production Skill description policy that this documentation change establishes.
    It 'UnitT52_binds_windows_local_agent_ci_and_owned_skill_description_scope' {
        $standardPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\standards\skill-repository-standard.md'
        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardPath
        $scopeLines = @($standard -split '\r?\n' | Where-Object { $_ -match '使用其共用 AI-Instructions／Skills runtime' })
        $scopeLines.Count | Should -Be 1

        $scopeLines[0] | Should -Match '(?i)CI host'
        $scopeLines[0] | Should -Match '(?i)Windows'
        $scopeLines[0] | Should -Match '(?i)Linux.*macOS.*WSL'
        $scopeLines[0] | Should -Match '下游產品的 target/deployment OS'
        $scopeLines[0] | Should -Not -Match '(?i)不限制下游(消費)? Repository'
        $scopeLines[0] | Should -Match '遠端 SaaS'

        $scopeLines[0] | Should -Match 'owned production Skills.*active.*dormant.*bundled'
        $scopeLines[0] | Should -Match 'Skill-Darktide-Translate'
        $scopeLines[0] | Should -Match 'Source Repository 宣告的 authority\.commit 與 member hashes'
        $scopeLines[0] | Should -Match 'snapshot 採用的 exact Standard bytes 綁定為固定版本'
        $scopeLines[0] | Should -Match '僅當該 snapshot 的 pinned Standard bytes 包含本 Windows 支援規則時'
        $scopeLines[0] | Should -Match 'source owner MUST 確保該 snapshot 規範的每個 owned production Skill 目前及後續 revision'
        $scopeLines[0] | Should -Match 'local execution 僅支援 Windows.*Linux/macOS/WSL 不支援'
        $scopeLines[0] | Should -Match '並保留既有 capability、trigger 與遠端 SaaS 語意'
        $scopeLines[0] | Should -Match '較早 immutable references 與採用未含此規則之 pinned Standard 的 snapshots 依其原 pinned Standard 判定，不追溯修改'
        $scopeLines[0] | Should -Match '測試 fixtures 與 examples 不屬於此描述更新範圍'
        $scopeLines[0] | Should -Match '不將獨立產品 Skill 加入本 Catalog、profile、lock 或 bootstrap'

        $scopeLines[0] | Should -Match 'selection metadata 的支援描述'
        $scopeLines[0] | Should -Match '不構成 runtime、toolchain、CI enforcement 或 acceptance gate 變更的授權'
        $scopeLines[0] | Should -Match '具體 defect 或明確 requirement.*依既有統一 contracts 另行授權'
    }
}

Describe 'SYP325 selected source integrity' -Tag 'SYP325' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Initialize-SourceGateFixture.ps1')
        $measurementTempRoot=if(-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){$env:RUNNER_TEMP}else{$env:TEMP}
        $script:SourceMeasurementEvidenceRoot=Join-Path $measurementTempRoot ('syp325-source-scope-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:SourceMeasurementEvidenceRoot)
    }

    # Scenario: A resolver receipt remains semantically valid after its bytes change from the setup snapshot.
    # Purpose: Require the same JSON snapshot used for parsing to match its frozen binding before reuse.
    It 'UnitT35_rejects_receipt_bytes_changed_after_setup_binding' {
        $report=New-SourceGateFixture
        $map=Assert-StandardCoreSourceToolReceipts -Bindings $report.sourceValidation.toolReceipts -FrozenFiles $report.sourceValidation.frozenFiles -RunId $report.runId -ReturnReceiptMap
        $binding=$report.sourceValidation.toolReceipts[0]
        $originalBytes=[IO.File]::ReadAllBytes($binding.path)
        $mutatedBytes=New-Object byte[] ($originalBytes.Length+1)
        [Array]::Copy($originalBytes,$mutatedBytes,$originalBytes.Length)
        $mutatedBytes[$mutatedBytes.Length-1]=10
        [IO.File]::WriteAllBytes($binding.path,$mutatedBytes)

        $retainedRejected=$false
        try { Assert-StandardCoreSourceToolReceipts -Bindings $report.sourceValidation.toolReceipts -FrozenFiles $report.sourceValidation.frozenFiles -RunId $report.runId -RetainedReceiptMap $map -ToolNames @('skill-validator') }
        catch { $retainedRejected=$true }
        if(-not $retainedRejected){throw 'A retained resolver receipt must match its setup-time SHA binding before parsed data is reused.'}

        $fullRejected=$false
        try { Assert-StandardCoreSourceToolReceipts -Bindings $report.sourceValidation.toolReceipts -FrozenFiles $report.sourceValidation.frozenFiles -RunId $report.runId }
        catch { $fullRejected=$true }
        if(-not $fullRejected){throw 'A changed resolver receipt must not be parsed as if it were the frozen setup snapshot.'}
    }
    # Scenario: A native resolver receipt contains package-only entryPointPath and nodePath fields.
    # Purpose: Keep those unauthenticated-by-contract extras as shared controls instead of treating them as mapped launch assets.
    It 'UnitT62_keeps_native_entrypoint_and_node_extras_in_shared_controls' {
        $report=New-SourceGateFixture -OutsideArtifactCommand
        $toolsRoot=Split-Path -Parent ([string]((Get-Content -Raw $report.sourceValidation.toolReceipts[0].path | ConvertFrom-Json).installRoot))
        $script:SourceUntrustedEntryPoint=Join-Path $toolsRoot 'untrusted-native-entry.js'
        $script:SourceUntrustedNode=Join-Path $toolsRoot 'untrusted-native-node.exe'
        [IO.File]::WriteAllText($script:SourceUntrustedEntryPoint,'untrusted native entry point',(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($script:SourceUntrustedNode,'untrusted native runtime',(New-Object Text.UTF8Encoding($false)))
        Set-SourceGateReceipt -Report $report -Index 0 -Mutate {
            param($receipt)
            $receipt | Add-Member -NotePropertyName entryPointPath -NotePropertyValue $script:SourceUntrustedEntryPoint
            $receipt | Add-Member -NotePropertyName entryPointSha256 -NotePropertyValue (Get-StandardValidationFileSha256 -Path $script:SourceUntrustedEntryPoint -Context 'untrusted native entry point')
            $receipt | Add-Member -NotePropertyName nodePath -NotePropertyValue $script:SourceUntrustedNode
            $receipt | Add-Member -NotePropertyName nodeSha256 -NotePropertyValue (Get-StandardValidationFileSha256 -Path $script:SourceUntrustedNode -Context 'untrusted native runtime')
        }
        $report.sourceValidation.frozenFiles += [pscustomobject]@{path=$script:SourceUntrustedEntryPoint;sha256=Get-StandardValidationFileSha256 -Path $script:SourceUntrustedEntryPoint -Context 'frozen untrusted native entry point'}
        $report.sourceValidation.frozenFiles += [pscustomobject]@{path=$script:SourceUntrustedNode;sha256=Get-StandardValidationFileSha256 -Path $script:SourceUntrustedNode -Context 'frozen untrusted native runtime'}
        $map=Assert-StandardCoreSourceToolReceipts -Bindings $report.sourceValidation.toolReceipts -FrozenFiles $report.sourceValidation.frozenFiles -RunId $report.runId -ReturnReceiptMap
        $nativeGroup=$map.groups.byTool['skill-validator']
        foreach($path in @($script:SourceUntrustedEntryPoint,$script:SourceUntrustedNode)){
            if(@($nativeGroup.sharedFiles | Where-Object {[string]$_.path -ceq $path}).Count -ne 1){throw "Native receipt extra '$path' must remain in the shared control set."}
            if(@($nativeGroup.externalAssets | Where-Object {[string]$_.path -ceq $path}).Count -ne 0){throw "Native receipt extra '$path' must not be treated as an authenticated external launch asset."}
        }
        if($nativeGroup.roots.Count -ne 1){throw 'Native receipt extras must not merge independent installation closure groups.'}
    }
    # Scenario: Source setup validates every tool root, then each dispatch validates its selected closure and shared controls.
    # Purpose: Observe real SHA-256 paths, bytes, and repeated phase samples while stubbing only child transport.
    It 'UnitT60_compares_same_tool_dispatch_across_unrelated_closure_sizes' {
        $states=New-Object 'System.Collections.Generic.List[object]'
        foreach($variant in @(
            [pscustomobject]@{name='small-unrelated-B';large=$false;report=(New-SourceGateFixture -OutsideArtifactCommand)},
            [pscustomobject]@{name='large-unrelated-B';large=$true;report=(New-SourceGateFixture -LargeSkillToolsClosure -OutsideArtifactCommand)}
        )){
            $report=$variant.report
            $adapter=Get-Content -Raw $report.sourceValidation.adapterSnapshot.path | ConvertFrom-Json
            $sourceSpec=$adapter.sourceValidation
            $map=Assert-StandardCoreSourceToolReceipts -Bindings @($sourceSpec.toolReceipts) -FrozenFiles @($sourceSpec.frozenFiles) -RunId $report.runId -CandidateRoot $report.artifacts.snapshotRoot -ArtifactsRoot $report.artifacts.root -ReturnReceiptMap
            $skillSet=Get-StandardValidationSkillSet -CandidateRoot $report.artifacts.snapshotRoot -SkillsRootRelative 'skills' -DeclaredSkills $report.candidate.activeSkills
            $trustedRoot=Split-Path -Parent ([string]$sourceSpec.packageAdapter.command)
            $states.Add([pscustomobject]@{name=$variant.name;large=[bool]$variant.large;report=$report;sourceSpec=$sourceSpec;map=$map;skillSet=$skillSet;trustedRoot=$trustedRoot})
        }
        $script:SourceSha256Original=(Get-Command Get-StandardValidationFileSha256 -CommandType Function).ScriptBlock
        $script:SourceSha256Reads=New-Object 'System.Collections.Generic.List[object]'
        $script:SourceTransportTool=$null
        $script:SourceObserverForcedPhase=$null
        $script:SourceReceiptsForObserver=@()

        Mock Get-StandardValidationFileSha256 {
            param([string]$Path,[string]$Context)
            $phase='outside-source-run';$tool=$null
            $frames=@(Get-PSCallStack)
            if($null -ne $script:SourceTransportTool){$phase='transport';$tool=[string]$script:SourceTransportTool}
            elseif(-not [string]::IsNullOrWhiteSpace([string]$script:SourceObserverForcedPhase)){$phase=[string]$script:SourceObserverForcedPhase}
            else {
                $sourceFrame=@($frames | Where-Object {$_.FunctionName -match 'Invoke-StandardCoreSourceTools'} | Select-Object -First 1)
                if($sourceFrame.Count -gt 0){
                    $frameVariables=$sourceFrame[0].GetFrameVariables()
                    if($frameVariables.ContainsKey('dispatch') -and $null -ne $frameVariables['dispatch'].Value){
                        $dispatchValue=$frameVariables['dispatch'].Value
                        $tool=[string]$dispatchValue.tool
                        $resultTool=$null
                        if($frameVariables.ContainsKey('result') -and $null -ne $frameVariables['result'].Value -and $null -ne $frameVariables['result'].Value.event){
                            $eventValue=$frameVariables['result'].Value.event
                            if($null -ne $eventValue.PSObject.Properties['tool']){$resultTool=[string]$eventValue.tool}
                        }
                        $phase=if($resultTool -ceq $tool){'post-dispatch'}else{'pre-dispatch'}
                    }
                    else {$phase='setup'}
                }
            }
            $item=Get-Item -Force -LiteralPath $Path -ErrorAction Stop
            $watch=[Diagnostics.Stopwatch]::StartNew()
            try { & $script:SourceSha256Original -Path $Path -Context $Context }
            finally {
                $watch.Stop()
                $script:SourceSha256Reads.Add([pscustomobject]@{path=[string]$Path;bytes=[long]$item.Length;phase=$phase;tool=$tool;elapsedMilliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,3)})
            }
        }
        Mock Invoke-StandardValidationCommandAndRecord {
            param($CommandSpec,[string]$RunRoot,[string]$ChildWorkingRoot,[string]$StageId,[string]$ToolId,[string]$CandidateId,[string]$SkillId,[string[]]$ExpectedActiveSkills)
            $script:SourceTransportTool=[string]$ToolId
            try {
                $nativeReports=@()
                if([string]$ToolId -cin @('skill-validator','skill-tools','static-analyzer')){
                    $nativeName=if([string]$ToolId -ceq 'static-analyzer'){'skillspector'}else{[string]$ToolId}
                    $receiptBinding=@($script:SourceReceiptsForObserver | Where-Object {[IO.Path]::GetFileName([string]$_.path) -ceq ($nativeName+'.json')})[0]
                    $receipt=Get-Content -Raw $receiptBinding.path | ConvertFrom-Json
                    $nativeCommand=if($nativeName -ceq 'skill-tools'){$receipt.nodePath}else{$receipt.executablePath}
                    $nativeCommandHash=if($nativeName -ceq 'skill-tools'){$receipt.nodeSha256}else{$receipt.executableSha256}
                    $nativeSkills=if(-not [string]::IsNullOrEmpty([string]$SkillId)){@([string]$SkillId)}else{@($ExpectedActiveSkills)}
                    foreach($nativeSkill in $nativeSkills){
                        $nativePath=Join-Path $RunRoot (([guid]::NewGuid().ToString('N'))+'-native.json')
                        Write-SourceGateFixtureJson -Path $nativePath -Value ([pscustomobject]@{tool=$ToolId;skillId=$nativeSkill;status='passed'})
                        $nativeArguments=if($nativeName -ceq 'skill-tools'){@($receipt.entryPointPath,'validate',$nativeSkill)}else{@('validate',$nativeSkill)}
                        $nativeReports += [pscustomobject]@{skillId=$nativeSkill;command=$nativeCommand;commandSha256=$nativeCommandHash;arguments=$nativeArguments;exitCode=0;path=$nativePath;sha256=Get-StandardValidationFileSha256 -Path $nativePath -Context 'measurement transport report'}
                    }
                }
                $envelope=[pscustomobject]@{nativeReports=@($nativeReports);findings=@();analyzerCompleteness='complete'}
                return [pscustomobject]@{event=[pscustomobject]@{tool=$ToolId;skill=$SkillId};envelope=$envelope}
            }
            finally {$script:SourceTransportTool=$null}
        }

        $measureClosure={
            param([object[]]$Rows,[string[]]$Roots,[string[]]$Phases)
            $scopeRows=New-Object 'System.Collections.Generic.List[object]'
            foreach($row in $Rows){
                if([string]$row.phase -cnotin $Phases){continue}
                if(@($Roots).Count -eq 0){$scopeRows.Add($row);continue}
                foreach($root in $Roots){
                    if(Test-StandardValidationPathWithin -Path ([string]$row.path) -Root ([string]$root) -IncludeRoot){$scopeRows.Add($row);break}
                }
            }
            $paths=@($scopeRows | ForEach-Object {[string]$_.path} | Select-Object -Unique)
            $bytes=[long]0;$elapsed=[double]0
            foreach($row in $scopeRows){$bytes += [long]$row.bytes;$elapsed += [double]$row.elapsedMilliseconds}
            $uniqueBytes=[long]0
            foreach($pathValue in $paths){$uniqueBytes += [long](Get-Item -Force -LiteralPath $pathValue).Length}
            return [pscustomobject]@{shaReadCount=$scopeRows.Count;shaReadBytes=$bytes;shaElapsedMilliseconds=[Math]::Round($elapsed,3);shaUniquePathCount=$paths.Count;shaUniqueBytes=$uniqueBytes;closurePaths=$paths}
        }
        $normalizePath={
            param([string]$Path,$State)
            $aGroup=$State.map.groups.byTool['skill-validator']
            foreach($root in @($aGroup.roots)){
                if(Test-StandardValidationPathWithin -Path $Path -Root ([string]$root) -IncludeRoot){return 'tool-A/'+([IO.Path]::GetRelativePath([string]$root,$Path).Replace('\','/'))}
            }
            foreach($binding in @($State.sourceSpec.toolReceipts)){
                if([string]::Equals($Path,[string]$binding.path,[StringComparison]::OrdinalIgnoreCase)){return 'receipt/'+[IO.Path]::GetFileName([string]$binding.path)}
            }
            foreach($asset in @($aGroup.externalAssets)){
                if([string]::Equals($Path,[string]$asset.path,[StringComparison]::OrdinalIgnoreCase)){return 'tool-A-external/'+[IO.Path]::GetFileName([string]$asset.path)}
            }
            foreach($shared in @($aGroup.sharedFiles)){
                if([string]::Equals($Path,[string]$shared.path,[StringComparison]::OrdinalIgnoreCase)){return 'shared/'+[IO.Path]::GetFileName([string]$shared.path)}
            }
            if(Test-StandardValidationPathWithin -Path $Path -Root ([string]$State.report.artifacts.snapshotRoot) -IncludeRoot){return 'candidate/'+([IO.Path]::GetRelativePath([string]$State.report.artifacts.snapshotRoot,$Path).Replace('\','/'))}
            foreach($group in @($State.map.groups.groups)){
                if([string]$group.id -ceq [string]$aGroup.id){continue}
                foreach($root in @($group.roots)){
                    if(Test-StandardValidationPathWithin -Path $Path -Root ([string]$root) -IncludeRoot){return 'other/'+[string]$group.id+'/'+([IO.Path]::GetRelativePath([string]$root,$Path).Replace('\','/'))}
                }
            }
            if(Test-StandardValidationPathWithin -Path $Path -Root ([string]$State.report.artifacts.root) -IncludeRoot){
                $relative=[IO.Path]::GetRelativePath([string]$State.report.artifacts.root,$Path).Replace('\','/')
                $relative=[regex]::Replace($relative,'(?i)[0-9a-f]{32}(?=-|\.)','{id}')
                return 'artifacts/'+$relative
            }
            return 'outside/'+[IO.Path]::GetFileName($Path)
        }
        $measureToolPhase={
            param([object[]]$Rows,$State)
            $normalized=@($Rows | ForEach-Object {[pscustomobject]@{path=(& $normalizePath -Path ([string]$_.path) -State $State);bytes=[long]$_.bytes;phase=[string]$_.phase;tool=[string]$_.tool;elapsedMilliseconds=[double]$_.elapsedMilliseconds}})
            $matrix=@($normalized | Group-Object path | Sort-Object Name | ForEach-Object {
                $callBytes=[long]0;$elapsed=[double]0;foreach($row in $_.Group){$callBytes += [long]$row.bytes;$elapsed += [double]$row.elapsedMilliseconds}
                [pscustomobject]@{path=[string]$_.Name;calls=$_.Count;bytes=$callBytes;elapsedMilliseconds=[Math]::Round($elapsed,3)}
            })
            $readBytes=[long]0;$readElapsed=[double]0
            foreach($row in $Rows){$readBytes += [long]$row.bytes;$readElapsed += [double]$row.elapsedMilliseconds}
            $physicalPaths=@($Rows | ForEach-Object {[string]$_.path} | Select-Object -Unique)
            $uniqueBytes=[long]0
            foreach($pathValue in $physicalPaths){$uniqueBytes += [long](Get-Item -Force -LiteralPath $pathValue).Length}
            $signature=ConvertTo-Json -InputObject @($matrix | ForEach-Object {[pscustomobject]@{path=$_.path;calls=$_.calls;bytes=$_.bytes}}) -Depth 4 -Compress
            return [pscustomobject]@{shaReadCount=$Rows.Count;shaReadBytes=$readBytes;shaElapsedMilliseconds=[Math]::Round($readElapsed,3);shaUniquePathCount=$physicalPaths.Count;shaUniqueBytes=$uniqueBytes;normalizedPathClassCount=$matrix.Count;pathMatrix=$matrix;pathSignature=$signature;shaReads=@($Rows | ForEach-Object {[pscustomobject]@{path=[string]$_.path;bytes=[long]$_.bytes;phase=[string]$_.phase;tool=[string]$_.tool;elapsedMilliseconds=[double]$_.elapsedMilliseconds}})}
        }
        $runSample={
            param($State,[int]$Sample)
            $script:SourceSha256Reads.Clear()
            $script:SourceReceiptsForObserver=@($State.sourceSpec.toolReceipts)
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $null=Invoke-StandardCoreSourceTools -Spec $State.sourceSpec -SkillSet $State.skillSet -RunId $State.report.runId `
                -SourceRevision $State.report.candidate.sourceRevision -AuthorityRevision $State.report.authority.revision `
                -SnapshotRoot $State.report.artifacts.snapshotRoot -ContentSha256 $State.report.candidate.contentSha256 `
                -RunRoot $State.report.artifacts.runRoot -AdapterPath $State.report.sourceValidation.adapterSnapshot.path `
                -AdapterSha256 $State.report.sourceValidation.adapterSnapshot.sha256 -ArtifactsRoot $State.report.artifacts.root `
                -TrustedToolRoot $State.trustedRoot -TimeoutSeconds 5 -CancellationPath (Join-Path $State.report.artifacts.root 'cancelled')
            $watch.Stop()
            $rows=@($script:SourceSha256Reads.ToArray())
            $allRoots=@($State.map.groups.groups | ForEach-Object {$_.roots} | Select-Object -Unique)
            $setup=& $measureClosure -Rows $rows -Roots $allRoots -Phases @('setup')
            foreach($root in $allRoots){
                $probe=Join-Path ([string]$root) 'dependency.bin'
                if($setup.closurePaths -notcontains $probe){throw "Full setup did not hash a tool root dependency: $probe"}
            }
            if($State.large){foreach($index in 1..2){$probe=Join-Path ([string]$State.map.groups.byTool['skill-tools'].roots[0]) ("dependency-large-$index.bin");if($setup.closurePaths -notcontains $probe){throw "Full setup omitted the unrelated larger closure file: $probe"}}}
            $dispatchRows=@($rows | Where-Object {$_.phase -cin @('pre-dispatch','post-dispatch') -and $_.tool -ceq 'skill-validator'})
            if(@($dispatchRows | Where-Object {$_.phase -ceq 'pre-dispatch'}).Count -eq 0 -or @($dispatchRows | Where-Object {$_.phase -ceq 'post-dispatch'}).Count -eq 0){throw 'Selected tool A SHA reads were not separated into pre and post dispatch.'}
            $aGroup=$State.map.groups.byTool['skill-validator']
            $aDependency=Join-Path ([string]$aGroup.roots[0]) 'dependency.bin'
            if(@($dispatchRows | Where-Object {$_.path -ceq $aDependency}).Count -eq 0){throw 'Selected tool A dependency was not hashed during its dispatch.'}
            $otherRoots=@($State.map.groups.groups | Where-Object {$_.id -cne $aGroup.id} | ForEach-Object {$_.roots} | Select-Object -Unique)
            foreach($otherRoot in $otherRoots){if(@($dispatchRows | Where-Object {Test-StandardValidationPathWithin -Path ([string]$_.path) -Root ([string]$otherRoot) -IncludeRoot}).Count -gt 0){throw 'Selected tool A dispatch hashed unrelated tool B closure bytes.'}}
            $preRows=@($dispatchRows | Where-Object {$_.phase -ceq 'pre-dispatch'})
            $postRows=@($dispatchRows | Where-Object {$_.phase -ceq 'post-dispatch'})
            if($preRows.Count -eq 0 -or $postRows.Count -eq 0){throw 'Selected tool A must have actual pre and post SHA samples.'}
            $preMetric=& $measureToolPhase -Rows $preRows -State $State
            $postMetric=& $measureToolPhase -Rows $postRows -State $State
            $selectedMetric=& $measureToolPhase -Rows $dispatchRows -State $State
            $setupRows=@($rows | Where-Object {$_.phase -ceq 'setup'})
            $transportRows=@($rows | Where-Object {$_.phase -ceq 'transport'})
            return [pscustomobject]@{variant=$State.name;sample=$Sample;sourceToolsElapsedMilliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,3);setup=$setup;setupShaReads=@($setupRows | ForEach-Object {[pscustomobject]@{path=[string]$_.path;bytes=[long]$_.bytes;elapsedMilliseconds=[double]$_.elapsedMilliseconds}});preDispatch=$preMetric;postDispatch=$postMetric;selectedDispatch=$selectedMetric;transportReadCount=$transportRows.Count;transportShaReads=@($transportRows | ForEach-Object {[pscustomobject]@{path=[string]$_.path;bytes=[long]$_.bytes;tool=[string]$_.tool;elapsedMilliseconds=[double]$_.elapsedMilliseconds}})}
        }

        $results=New-Object 'System.Collections.Generic.List[object]'
        foreach($state in $states){for($sample=1;$sample -le 3;$sample++){$results.Add((& $runSample -State $state -Sample $sample))}}
        $small=@($results | Where-Object {$_.variant -ceq 'small-unrelated-B'})
        $large=@($results | Where-Object {$_.variant -ceq 'large-unrelated-B'})
        if($small.Count -ne 3 -or $large.Count -ne 3){throw 'Expected three samples for each unrelated tool B closure size.'}
        $expectedSignature=[string]$small[0].selectedDispatch.pathSignature
        foreach($sample in @($small)+@($large)){
            if([string]$sample.selectedDispatch.pathSignature -cne $expectedSignature -or
                [long]$sample.selectedDispatch.shaReadCount -ne [long]$small[0].selectedDispatch.shaReadCount -or
                [long]$sample.selectedDispatch.shaReadBytes -ne [long]$small[0].selectedDispatch.shaReadBytes -or
                [long]$sample.selectedDispatch.shaUniquePathCount -ne [long]$small[0].selectedDispatch.shaUniquePathCount -or
                [long]$sample.selectedDispatch.shaUniqueBytes -ne [long]$small[0].selectedDispatch.shaUniqueBytes){throw 'The same selected tool A dispatch read a different path/count/byte scope as unrelated tool B changed size.'}
        }

        foreach($phaseName in @('preDispatch','postDispatch')){
            $expectedPhase=$small[0].$phaseName
            foreach($sample in @($small)+@($large)){
                $actualPhase=$sample.$phaseName
                if([string]$actualPhase.pathSignature -cne [string]$expectedPhase.pathSignature -or
                    [long]$actualPhase.shaReadCount -ne [long]$expectedPhase.shaReadCount -or
                    [long]$actualPhase.shaReadBytes -ne [long]$expectedPhase.shaReadBytes -or
                    [long]$actualPhase.shaUniquePathCount -ne [long]$expectedPhase.shaUniquePathCount -or
                    [long]$actualPhase.shaUniqueBytes -ne [long]$expectedPhase.shaUniqueBytes){throw "Selected tool A $phaseName read scope varied with unrelated tool B closure size or sample."}
            }
        }
        $finalReadResults=New-Object 'System.Collections.Generic.List[object]'
        foreach($state in $states){
            for($sample=1;$sample -le 3;$sample++){
                $script:SourceSha256Reads.Clear();$script:SourceObserverForcedPhase='final-report'
                $watch=[Diagnostics.Stopwatch]::StartNew()
                try {Invoke-SourceGateFixture -Report $state.report | Out-Null}
                finally {$watch.Stop();$script:SourceObserverForcedPhase=$null}
                $finalRows=@($script:SourceSha256Reads.ToArray())
                $allRoots=@($state.map.groups.groups | ForEach-Object {$_.roots} | Select-Object -Unique)
                $finalClosure=& $measureClosure -Rows $finalRows -Roots $allRoots -Phases @('final-report')
                $finalAll=& $measureClosure -Rows $finalRows -Roots @() -Phases @('final-report')
                foreach($root in $allRoots){$probe=Join-Path ([string]$root) 'dependency.bin';if($finalClosure.closurePaths -notcontains $probe){throw "Full final report read omitted a tool root dependency: $probe"}}
                if($state.large){foreach($index in 1..2){$probe=Join-Path ([string]$state.map.groups.byTool['skill-tools'].roots[0]) ("dependency-large-$index.bin");if($finalClosure.closurePaths -notcontains $probe){throw "Full final report read omitted the unrelated larger closure file: $probe"}}}
                $finalReadResults.Add([pscustomobject]@{
                    variant=$state.name;sample=$sample;phase='final-report';readerElapsedMilliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,3)
                    shaReadCount=$finalAll.shaReadCount;shaReadBytes=$finalAll.shaReadBytes;shaElapsedMilliseconds=$finalAll.shaElapsedMilliseconds;shaUniquePathCount=$finalAll.shaUniquePathCount;shaUniqueBytes=$finalAll.shaUniqueBytes
                    finalReader=[pscustomobject]@{readerElapsedMilliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,3);shaReadCount=$finalAll.shaReadCount;shaReadBytes=$finalAll.shaReadBytes;shaElapsedMilliseconds=$finalAll.shaElapsedMilliseconds;shaUniquePathCount=$finalAll.shaUniquePathCount;shaUniqueBytes=$finalAll.shaUniqueBytes}
                    closureShaReadCount=$finalClosure.shaReadCount;closureShaReadBytes=$finalClosure.shaReadBytes;closureShaElapsedMilliseconds=$finalClosure.shaElapsedMilliseconds;closureShaUniquePathCount=$finalClosure.shaUniquePathCount;closureShaUniqueBytes=$finalClosure.shaUniqueBytes;closurePaths=@($finalClosure.closurePaths)
                    shaReads=@($finalRows | ForEach-Object {[pscustomobject]@{path=[string]$_.path;bytes=[long]$_.bytes;elapsedMilliseconds=[double]$_.elapsedMilliseconds}})
                })
            }
        }
        $smallSetup=$small[0].setup;$largeSetup=$large[0].setup
        if($largeSetup.shaUniquePathCount -le $smallSetup.shaUniquePathCount -or $largeSetup.shaUniqueBytes -le $smallSetup.shaUniqueBytes){throw 'Full setup did not measure the expected larger unrelated tool B closure.'}
        $smallFinal=@($finalReadResults | Where-Object {$_.variant -ceq 'small-unrelated-B'})
        $largeFinal=@($finalReadResults | Where-Object {$_.variant -ceq 'large-unrelated-B'})
        if($smallFinal.Count -ne 3 -or $largeFinal.Count -ne 3){throw 'Expected three final-reader samples for each unrelated tool B closure size.'}
        foreach($variantName in @('small-unrelated-B','large-unrelated-B')){
            $sampleGroup=if($variantName -ceq 'small-unrelated-B'){@($smallFinal)}else{@($largeFinal)}
            $first=$sampleGroup[0]
            foreach($sample in $sampleGroup){
                if([long]$sample.shaReadCount -ne [long]$first.shaReadCount -or [long]$sample.shaReadBytes -ne [long]$first.shaReadBytes -or
                    [long]$sample.shaUniquePathCount -ne [long]$first.shaUniquePathCount -or [long]$sample.shaUniqueBytes -ne [long]$first.shaUniqueBytes -or
                    [long]$sample.closureShaUniquePathCount -ne [long]$first.closureShaUniquePathCount -or [long]$sample.closureShaUniqueBytes -ne [long]$first.closureShaUniqueBytes){throw 'Final report reader path/count/byte measurements varied between identical samples.'}
            }
        }
        if($largeFinal[0].closureShaUniquePathCount -le $smallFinal[0].closureShaUniquePathCount -or $largeFinal[0].closureShaUniqueBytes -le $smallFinal[0].closureShaUniqueBytes){throw 'Full final report reader did not measure the expected larger unrelated tool B closure.'}
        $summarizeMetric={
            param([object[]]$Samples,[string]$PropertyName,[string[]]$Fields)
            $summary=[ordered]@{sampleCount=$Samples.Count}
            foreach($field in $Fields){
                $values=New-Object 'System.Collections.Generic.List[double]'
                foreach($sample in $Samples){$metric=$sample.PSObject.Properties[$PropertyName].Value;$values.Add([double]$metric.$field)}
                $stats=$values.ToArray() | Measure-Object -Average -Minimum -Maximum
                $summary[$field]=[pscustomobject]@{min=[Math]::Round([double]$stats.Minimum,3);mean=[Math]::Round([double]$stats.Average,3);max=[Math]::Round([double]$stats.Maximum,3)}
            }
            return [pscustomobject]$summary
        }
        $summarizeValues={
            param([double[]]$Values)
            $stats=@($Values) | Measure-Object -Average -Minimum -Maximum
            return [pscustomobject]@{sampleCount=@($Values).Count;min=[Math]::Round([double]$stats.Minimum,3);mean=[Math]::Round([double]$stats.Average,3);max=[Math]::Round([double]$stats.Maximum,3)}
        }
        $summaries=New-Object 'System.Collections.Generic.List[object]'
        foreach($variantName in @('small-unrelated-B','large-unrelated-B')){
            $variantSamples=@($results | Where-Object {$_.variant -ceq $variantName})
            $variantFinal=@($finalReadResults | Where-Object {$_.variant -ceq $variantName})
            $summaries.Add([pscustomobject]@{
                variant=$variantName
                sourceToolsBindingElapsedMilliseconds=& $summarizeValues -Values @($variantSamples | ForEach-Object {[double]$_.sourceToolsElapsedMilliseconds})
                setup=& $summarizeMetric -Samples $variantSamples -PropertyName 'setup' -Fields @('shaReadCount','shaReadBytes','shaElapsedMilliseconds','shaUniquePathCount','shaUniqueBytes')
                preDispatch=& $summarizeMetric -Samples $variantSamples -PropertyName 'preDispatch' -Fields @('shaReadCount','shaReadBytes','shaElapsedMilliseconds','shaUniquePathCount','shaUniqueBytes')
                postDispatch=& $summarizeMetric -Samples $variantSamples -PropertyName 'postDispatch' -Fields @('shaReadCount','shaReadBytes','shaElapsedMilliseconds','shaUniquePathCount','shaUniqueBytes')
                finalReader=& $summarizeMetric -Samples $variantFinal -PropertyName 'finalReader' -Fields @('readerElapsedMilliseconds','shaReadCount','shaReadBytes','shaElapsedMilliseconds','shaUniquePathCount','shaUniqueBytes')
            })
        }
        $evidenceRoot=$script:SourceMeasurementEvidenceRoot
        $evidence=[pscustomobject]@{test='UnitT60_compares_same_tool_dispatch_across_unrelated_closure_sizes';evidenceRoot=$evidenceRoot;toolA='skill-validator';unrelatedToolB='skill-tools';smallClosureSamples=@($small);largeClosureSamples=@($large);finalReaderSamples=@($finalReadResults.ToArray());minMeanMaxSummaries=@($summaries.ToArray())}
        [IO.File]::WriteAllText((Join-Path $evidenceRoot 'dispatch-read-scope-samples.json'),($evidence | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    }
    # Scenario: An earlier package adapter mutates a different tool's installed closure before Skillspector dispatch.
    # Purpose: Prove real pre-dispatch hashing rejects the changed closure before that child transport starts.
    It 'UnitT61_rejects_changed_other_tool_closure_before_its_child_launch' {
        $report=New-SourceGateFixture -OutsideArtifactCommand
        $adapter=Get-Content -Raw $report.sourceValidation.adapterSnapshot.path | ConvertFrom-Json
        $sourceSpec=$adapter.sourceValidation
        $trustedRoot=Split-Path -Parent ([string]$sourceSpec.packageAdapter.command)
        $skillRecords=@()
        foreach($id in @($report.candidate.activeSkills)){
            $skillRoot=Join-Path $report.artifacts.snapshotRoot ('skills/'+$id)
            $inventory=Get-StandardValidationInventory -Root $skillRoot -Context 'dispatch tamper fixture skill'
            $skillRecords += [pscustomobject]@{id=$id;inventorySha256=Get-StandardValidationInventorySha256 -Inventory $inventory}
        }
        $skillSet=[pscustomobject]@{ids=@($report.candidate.activeSkills);records=$skillRecords;root=(Join-Path $report.artifacts.snapshotRoot 'skills');relative='skills'}
        $receiptBindings=@($sourceSpec.toolReceipts)
        $skillSpectorBinding=@($receiptBindings | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ceq 'skillspector.json' })[0]
        $skillSpectorReceipt=Get-Content -Raw $skillSpectorBinding.path | ConvertFrom-Json
        $script:SourceTamperFile=Join-Path ([string]$skillSpectorReceipt.installRoot) 'dependency.bin'
        $script:SourceToolLaunches=New-Object 'System.Collections.Generic.List[string]'
        $script:SourceFakeReceipts=$receiptBindings
        Mock Invoke-StandardValidationCommandAndRecord {
            param($CommandSpec,[string]$RunRoot,[string]$ChildWorkingRoot,[string]$StageId,[string]$ToolId,[string]$CandidateId,[string]$SkillId,[string[]]$ExpectedActiveSkills)
            $script:SourceToolLaunches.Add([string]$ToolId)
            if([string]$ToolId -ceq 'package-adapter'){
                [IO.File]::WriteAllText($script:SourceTamperFile,'changed after setup and before Skillspector dispatch',(New-Object Text.UTF8Encoding($false)))
            }
            $nativeReports=@()
            if([string]$ToolId -cin @('skill-validator','skill-tools','static-analyzer')){
                $nativeName=if([string]$ToolId -ceq 'static-analyzer'){'skillspector'}else{[string]$ToolId}
                $binding=@($script:SourceFakeReceipts | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ceq ($nativeName+'.json') })[0]
                $receipt=Get-Content -Raw $binding.path | ConvertFrom-Json
                $nativeCommand=if($nativeName -ceq 'skill-tools'){$receipt.nodePath}else{$receipt.executablePath}
                $nativeCommandHash=if($nativeName -ceq 'skill-tools'){$receipt.nodeSha256}else{$receipt.executableSha256}
                $nativeSkills=if(-not [string]::IsNullOrEmpty([string]$SkillId)){@([string]$SkillId)}else{@($ExpectedActiveSkills)}
                foreach($nativeSkill in $nativeSkills){
                    $nativePath=Join-Path $RunRoot (([guid]::NewGuid().ToString('N'))+'-native.json')
                    Write-SourceGateFixtureJson -Path $nativePath -Value ([pscustomobject]@{tool=$ToolId;skillId=$nativeSkill;status='passed'})
                    $nativeArguments=if($nativeName -ceq 'skill-tools'){@($receipt.entryPointPath,'validate',$nativeSkill)}else{@('validate',$nativeSkill)}
                    $nativeReports += [pscustomobject]@{skillId=$nativeSkill;command=$nativeCommand;commandSha256=$nativeCommandHash;arguments=$nativeArguments;exitCode=0;path=$nativePath;sha256=Get-StandardValidationFileSha256 -Path $nativePath -Context 'dispatch tamper native report'}
                }
            }
            $envelope=[pscustomobject]@{nativeReports=@($nativeReports);findings=@();analyzerCompleteness='complete'}
            return [pscustomobject]@{event=[pscustomobject]@{tool=$ToolId;skill=$SkillId};envelope=$envelope}
        }

        $rejected=$false
        try {
            Invoke-StandardCoreSourceTools -Spec $sourceSpec -SkillSet $skillSet -RunId $report.runId -SourceRevision $report.candidate.sourceRevision -AuthorityRevision $report.authority.revision -SnapshotRoot $report.artifacts.snapshotRoot -ContentSha256 $report.candidate.contentSha256 -RunRoot $report.artifacts.runRoot -AdapterPath $report.sourceValidation.adapterSnapshot.path -AdapterSha256 $report.sourceValidation.adapterSnapshot.sha256 -ArtifactsRoot $report.artifacts.root -TrustedToolRoot $trustedRoot -TimeoutSeconds 5 -CancellationPath (Join-Path $report.artifacts.root 'cancelled')
        }
        catch { $rejected=$true }
        if(-not $rejected){throw 'A changed Skillspector closure must reject dispatch before its child launch.'}
        if($script:SourceToolLaunches -contains 'static-analyzer'){throw 'Static analyzer child was launched after its pre-dispatch closure check failed.'}
        if($script:SourceToolLaunches.Count -ne 5){throw "Expected five earlier child launches; observed $($script:SourceToolLaunches.Count)."}

        $evidenceRoot=$script:SourceMeasurementEvidenceRoot
        $evidence=[pscustomobject]@{test='UnitT61_rejects_changed_other_tool_closure_before_its_child_launch';mutatedTool='skillspector';mutatedPath=$script:SourceTamperFile;launchedTools=@($script:SourceToolLaunches.ToArray());staticAnalyzerChildLaunchCount=@($script:SourceToolLaunches | Where-Object {$_ -ceq 'static-analyzer'}).Count;rejectionObserved=$rejected}
        [IO.File]::WriteAllText((Join-Path $evidenceRoot 'other-tool-tamper-before-launch.json'),($evidence | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    }

    # Scenario: A selected tool's own dependency, executable, package payload, runtime, or closure inventory changes during its child.
    # Purpose: Require the post-dispatch guard to reject each change before accepting native reports or launching later tools.
    It 'UnitT63_rejects_same_tool_mutation_and_new_file_after_child_exit' {
        $cases=@(
            [pscustomobject]@{name='validator dependency';tool='skill-validator';field='dependency';receipt='skill-validator'},
            [pscustomobject]@{name='validator executable';tool='skill-validator';field='executable';receipt='skill-validator'},
            [pscustomobject]@{name='skill-tools payload';tool='skill-tools';field='payload';receipt='skill-tools'},
            [pscustomobject]@{name='skill-tools runtime';tool='skill-tools';field='runtime';receipt='skill-tools'},
            [pscustomobject]@{name='new file';tool='skill-validator';field='new-file';receipt='skill-validator'}
        )
        $outcomes=New-Object 'System.Collections.Generic.List[object]'
        foreach($case in $cases){
            $report=New-SourceGateFixture -OutsideArtifactCommand
            $adapter=Get-Content -Raw $report.sourceValidation.adapterSnapshot.path | ConvertFrom-Json
            $spec=$adapter.sourceValidation
            $binding=@($spec.toolReceipts | Where-Object {[IO.Path]::GetFileName([string]$_.path) -ceq ($case.receipt+'.json')})[0]
            $receipt=Get-Content -Raw $binding.path | ConvertFrom-Json
            $script:SourceTamperTargetTool=[string]$case.tool
            $script:SourceTamperDone=$false
            $script:SourceTamperKind=[string]$case.field
            $script:SourceTamperPath=switch([string]$case.field){
                'dependency' {Join-Path ([string]$receipt.installRoot) 'dependency.bin'}
                'executable' {[string]$receipt.executablePath}
                'payload' {[string]$receipt.entryPointPath}
                'runtime' {[string]$receipt.nodePath}
                'new-file' {Join-Path ([string]$receipt.installRoot) 'injected-during-child.bin'}
            }
            Set-SourceGateToolTransportMock -Receipts @($spec.toolReceipts) -AfterChild {
                param($ToolId,$SkillId,$CommandSpec,$RunRoot,$Receipts)
                if([string]$ToolId -ceq $script:SourceTamperTargetTool -and -not $script:SourceTamperDone){
                    if($script:SourceTamperKind -ceq 'new-file'){
                        [IO.File]::WriteAllText($script:SourceTamperPath,'new file added during tool child',(New-Object Text.UTF8Encoding($false)))
                    }
                    else {[IO.File]::WriteAllText($script:SourceTamperPath,'tool bytes changed during its child',(New-Object Text.UTF8Encoding($false)))}
                    $script:SourceTamperDone=$true
                }
            }
            $rejected=$false
            try { Invoke-SourceGateDispatchFixture -Report $report | Out-Null }
            catch { $rejected=$true }
            if(-not $script:SourceTamperDone){throw "The $($case.name) mutation did not occur during its selected child."}
            if(-not $rejected){throw "The post-dispatch guard accepted a changed $($case.name) closure."}
            $targetLaunchCount=@($script:SourceToolLaunches | Where-Object {$_ -ceq [string]$case.tool}).Count
            if($targetLaunchCount -ne 1){throw "The changed $($case.name) tool should launch once, then fail before its next dispatch."}
            $outcomes.Add([pscustomobject]@{case=[string]$case.name;mutatedPath=[string]$script:SourceTamperPath;targetLaunchCount=$targetLaunchCount;rejectionObserved=$rejected})
        }
        [IO.File]::WriteAllText((Join-Path $script:SourceMeasurementEvidenceRoot 'same-tool-post-dispatch-tamper.json'),(@($outcomes.ToArray()) | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    }

    # Scenario: A later child changes an authenticated external runtime or an unmapped shared control before another tool uses it.
    # Purpose: Keep external assets scoped to their owning tool while rechecking common controls for every dispatch.
    It 'UnitT64_rechecks_shared_controls_and_external_runtime_before_use' {
        foreach($scenario in @('unowned-shared-control','skill-tools-runtime')){
            $report=if($scenario -ceq 'unowned-shared-control'){New-SourceGateFixture -OutsideArtifactCommand -UnownedSharedControl}else{New-SourceGateFixture -OutsideArtifactCommand}
            $adapter=Get-Content -Raw $report.sourceValidation.adapterSnapshot.path | ConvertFrom-Json
            $spec=$adapter.sourceValidation
            $skillToolsBinding=@($spec.toolReceipts | Where-Object {[IO.Path]::GetFileName([string]$_.path) -ceq 'skill-tools.json'})[0]
            $skillToolsReceipt=Get-Content -Raw $skillToolsBinding.path | ConvertFrom-Json
            $script:SourceSharedMutationPath=if($scenario -ceq 'unowned-shared-control'){[string]$report.unownedSharedControlPath}else{[string]$skillToolsReceipt.nodePath}
            $script:SourceSharedMutationDone=$false
            Set-SourceGateToolTransportMock -Receipts @($spec.toolReceipts) -AfterChild {
                param($ToolId,$SkillId,$CommandSpec,$RunRoot,$Receipts)
                if([string]$ToolId -ceq 'package-adapter' -and -not $script:SourceSharedMutationDone){
                    [IO.File]::WriteAllText($script:SourceSharedMutationPath,'changed after setup before tool use',(New-Object Text.UTF8Encoding($false)))
                    $script:SourceSharedMutationDone=$true
                }
            }
            $rejected=$false
            try { Invoke-SourceGateDispatchFixture -Report $report | Out-Null }
            catch { $rejected=$true }
            if(-not $script:SourceSharedMutationDone -or -not $rejected){throw "The $scenario change must be rejected by its owning pre-dispatch integrity check."}
            $validatorLaunchCount=@($script:SourceToolLaunches | Where-Object {$_ -ceq 'skill-validator'}).Count
            $skillToolsLaunchCount=@($script:SourceToolLaunches | Where-Object {$_ -ceq 'skill-tools'}).Count
            if($scenario -ceq 'unowned-shared-control' -and ($validatorLaunchCount -ne 0 -or $skillToolsLaunchCount -ne 0)){throw 'An unmapped shared control must be checked before any subsequent tool child starts.'}
            if($scenario -ceq 'skill-tools-runtime' -and ($validatorLaunchCount -ne 1 -or $skillToolsLaunchCount -ne 0)){throw 'The external runtime must remain scoped to skill-tools and be checked before that tool launches.'}
            [IO.File]::WriteAllText((Join-Path $script:SourceMeasurementEvidenceRoot ($scenario+'.json')),(ConvertTo-Json -InputObject ([pscustomobject]@{scenario=$scenario;path=$script:SourceSharedMutationPath;launchedTools=@($script:SourceToolLaunches.ToArray());rejectionObserved=$rejected}) -Depth 5),(New-Object Text.UTF8Encoding($false)))
        }
    }

    # Scenario: A tool installation root or its ancestor is replaced with a reparse point after setup.
    # Purpose: Prove canonical-root checks reject root and ancestor substitution before selected child launch.
    It 'UnitT65_rejects_root_and_ancestor_reparse_substitution' {
        foreach($scope in @('root','ancestor')){
            $report=New-SourceGateFixture -OutsideArtifactCommand
            $adapter=Get-Content -Raw $report.sourceValidation.adapterSnapshot.path | ConvertFrom-Json
            $spec=$adapter.sourceValidation
            $validatorBinding=@($spec.toolReceipts | Where-Object {[IO.Path]::GetFileName([string]$_.path) -ceq 'skill-validator.json'})[0]
            $validatorReceipt=Get-Content -Raw $validatorBinding.path | ConvertFrom-Json
            $installRoot=[string]$validatorReceipt.installRoot
            $script:SourceJunctionPath=if($scope -ceq 'root'){$installRoot}else{Split-Path -Parent $installRoot}
            $script:SourceJunctionBackup=$script:SourceJunctionPath+'.original'
            $script:SourceJunctionCreated=$false
            if(Test-Path -LiteralPath $script:SourceJunctionBackup){throw 'The isolated fixture already contains a junction backup path.'}
            Set-SourceGateToolTransportMock -Receipts @($spec.toolReceipts) -AfterChild {
                param($ToolId,$SkillId,$CommandSpec,$RunRoot,$Receipts)
                if([string]$ToolId -ceq 'package-adapter' -and -not $script:SourceJunctionCreated){
                    Move-Item -LiteralPath $script:SourceJunctionPath -Destination $script:SourceJunctionBackup
                    New-Item -ItemType Junction -Path $script:SourceJunctionPath -Target $script:SourceJunctionBackup | Out-Null
                    $script:SourceJunctionCreated=$true
                }
            }
            $rejected=$false
            try { Invoke-SourceGateDispatchFixture -Report $report | Out-Null }
            catch { $rejected=$true }
            finally {
                if($script:SourceJunctionCreated -and (Test-Path -LiteralPath $script:SourceJunctionPath)){
                    Remove-Item -LiteralPath $script:SourceJunctionPath -Force
                    Move-Item -LiteralPath $script:SourceJunctionBackup -Destination $script:SourceJunctionPath
                }
            }
            if(-not $script:SourceJunctionCreated -or -not $rejected){throw "A substituted $scope reparse path must be rejected before tool launch."}
            if(@($script:SourceToolLaunches | Where-Object {$_ -ceq 'skill-validator'}).Count -ne 0){throw "The validator child must not launch when its $scope path is reparse-substituted."}
        }
    }

    # Scenario: A later analyzer child changes a validator closure whose tool already ran.
    # Purpose: Require the independent full final reader to reject cross-tool contamination after all dispatches complete.
    It 'UnitT66_final_full_reader_rejects_later_tool_contamination' {
        $report=New-SourceGateFixture -OutsideArtifactCommand
        $adapter=Get-Content -Raw $report.sourceValidation.adapterSnapshot.path | ConvertFrom-Json
        $spec=$adapter.sourceValidation
        $validatorBinding=@($spec.toolReceipts | Where-Object {[IO.Path]::GetFileName([string]$_.path) -ceq 'skill-validator.json'})[0]
        $validatorReceipt=Get-Content -Raw $validatorBinding.path | ConvertFrom-Json
        $script:SourceFinalMutationPath=Join-Path ([string]$validatorReceipt.installRoot) 'dependency.bin'
        $script:SourceFinalMutationDone=$false
        Set-SourceGateToolTransportMock -Receipts @($spec.toolReceipts) -AfterChild {
            param($ToolId,$SkillId,$CommandSpec,$RunRoot,$Receipts)
            if([string]$ToolId -ceq 'static-analyzer' -and -not $script:SourceFinalMutationDone){
                [IO.File]::WriteAllText($script:SourceFinalMutationPath,'changed after validator execution',(New-Object Text.UTF8Encoding($false)))
                $script:SourceFinalMutationDone=$true
            }
        }
        Invoke-SourceGateDispatchFixture -Report $report | Out-Null
        if(-not $script:SourceFinalMutationDone){throw 'The later analyzer child must mutate the already-executed validator closure.'}
        if(@($script:SourceToolLaunches).Count -ne 6){throw "Expected every source child to complete before final-reader validation; observed $($script:SourceToolLaunches.Count)."}
        $rejected=$false
        try { Invoke-SourceGateFixture -Report $report | Out-Null }
        catch { $rejected=$true }
        if(-not $rejected){throw 'The final full reader must reject an earlier tool closure contaminated by a later child.'}
    }

    # Scenario: The process-tree cleanup boundary completes, fails a required namespace proof, or completes because of cancellation.
    # Purpose: Measure actual owned-child cleanup spans and preserve the bool result and terminal timing state.
    It 'UnitT67_times_real_owned_process_cleanup_and_preserves_results' {
        $oldTimingEnabled=$script:StandardValidationTimingEnabled
        $oldConsoleError=[Console]::Error
        $writer=New-Object IO.StringWriter
        $script:StandardValidationTimingEnabled=$true
        [Console]::SetError($writer)
        $sentinelStart=New-Object Diagnostics.ProcessStartInfo
        $sentinelStart.FileName=Join-Path $PSHOME 'pwsh.exe'
        foreach($argument in @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60')){[void]$sentinelStart.ArgumentList.Add($argument)}
        $sentinelStart.UseShellExecute=$false;$sentinelStart.CreateNoWindow=$true;$sentinelStart.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
        $sentinel=$null
        $owned=New-Object 'System.Collections.Generic.List[Diagnostics.Process]'
        $startSleeper={
            $start=New-Object Diagnostics.ProcessStartInfo
            $start.FileName=Join-Path $PSHOME 'pwsh.exe'
            foreach($argument in @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 60')){[void]$start.ArgumentList.Add($argument)}
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
            return [Diagnostics.Process]::Start($start)
        }
        try {
            $sentinel=[Diagnostics.Process]::Start($sentinelStart)
            Start-Sleep -Milliseconds 100
            for($sample=0;$sample -lt 3;$sample++){
                $first=& $startSleeper;$owned.Add($first);Start-Sleep -Milliseconds 100
                $completed=Stop-StandardValidationProcessTree -RootProcessId $first.Id -RootProcess $first -WaitMilliseconds 1000
                if(-not $completed){throw 'A live owned child should clean up successfully with no required namespace proof.'}
                if($sentinel.HasExited){throw 'Cleanup must not terminate a process outside the owned root tree.'}
            }

            $second=& $startSleeper;$owned.Add($second);Start-Sleep -Milliseconds 100
            $failed=Stop-StandardValidationProcessTree -RootProcessId $second.Id -RootProcess $second -PidNamespaceRequired $true -WaitMilliseconds 1000
            if($failed){throw 'A missing required PID namespace must preserve the false cleanup result.'}
            if($sentinel.HasExited){throw 'A failed owned cleanup probe must not terminate the unrelated sentinel process.'}

            $third=& $startSleeper;$owned.Add($third);Start-Sleep -Milliseconds 100
            $cancelled=Stop-StandardValidationProcessTree -RootProcessId $third.Id -RootProcess $third -CancellationRequested $true -WaitMilliseconds 1000
            if(-not $cancelled){throw 'Successful cancellation cleanup must preserve the true cleanup result.'}
            if($sentinel.HasExited){throw 'Cancellation cleanup must not terminate the unrelated sentinel process.'}

            $cleanupRows=@($writer.ToString() -split "`r?`n" | Where-Object {$_ -match '^\[StandardValidation timing\] ' -and $_ -match '"phase":"child-cleanup"' } | ForEach-Object { ($_ -replace '^\[StandardValidation timing\] ','') | ConvertFrom-Json })
            $terminal=@($cleanupRows | Where-Object {$_.state -cin @('completed','failed','cancelled')})
            $completedSamples=@($terminal | Where-Object {$_.state -ceq 'completed'})
            if($terminal.Count -ne 5 -or (@($terminal.state | Sort-Object -Unique) -join ';') -cne 'cancelled;completed;failed'){throw "Expected five actual cleanup terminal observations including completed, failed, and cancelled; got $($terminal.state -join ',')."}
            if($completedSamples.Count -lt 3){throw "Expected at least three independent successful cleanup samples; got $($completedSamples.Count)."}
            if(@($terminal | Where-Object {$_.calls -ne 1 -or $_.files -ne 0 -or $_.bytes -ne 0 -or $_.elapsedSeconds -lt 0}).Count -ne 0){throw 'Cleanup timing must record one actual cleanup call and zero filesystem-file counts.'}
            $cleanupEvidencePath=Join-Path $script:SourceMeasurementEvidenceRoot 'child-cleanup-samples.json'
            [IO.File]::WriteAllText($cleanupEvidencePath,(ConvertTo-Json -InputObject $terminal -Depth 5),(New-Object Text.UTF8Encoding($false)))
            if(-not [IO.File]::Exists($cleanupEvidencePath)){throw 'Owned process cleanup observations must be saved under the task-run evidence root.'}
        }
        finally {
            foreach($process in $owned){
                try {if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(2000)}} catch {}
                try {$process.Dispose()} catch {}
            }
            if($null -ne $sentinel){try {if(-not $sentinel.HasExited){$sentinel.Kill();[void]$sentinel.WaitForExit(2000)}} catch {};try {$sentinel.Dispose()} catch {}}
            [Console]::SetError($oldConsoleError)
            $script:StandardValidationTimingEnabled=$oldTimingEnabled
        }
    }

    # Scenario: Final source-report binding returns normally or throws after reading report bytes while an outer collector is already active.
    # Purpose: Verify whole-reader wall time while counters cover only successful SHA/JSON snapshots (excluding direct ReadAllText calls), then preserve the outcome and restore the prior observer.
    It 'UnitT68_times_full_report_reads_and_restores_observer_on_success_and_failure' {
        $oldTimingEnabled=$script:StandardValidationTimingEnabled
        $oldConsoleError=[Console]::Error
        $writer=New-Object IO.StringWriter
        $sentinel=New-StandardValidationPhase -Stage 'test' -Phase 'observer-sentinel' -Aggregate -Silent
        $script:StandardValidationTimingEnabled=$true
        $script:StandardValidationReadObserver=$sentinel
        [Console]::SetError($writer)
        try {
            $successReport=New-SourceGateFixture
            $result=Invoke-SourceGateFixture -Report $successReport
            if($result -ne $true){throw 'Successful source report validation must preserve its true result.'}
            if(-not [object]::ReferenceEquals($script:StandardValidationReadObserver,$sentinel)){throw 'The report reader must restore the caller observer after success.'}

            $failedReport=New-SourceGateFixture
            Set-SourceGateCases -Report $failedReport -Mutate {param($cases) $cases.shardIdentity='wrong-after-read'}
            $failed=$false;$failureMessage=''
            try {Invoke-SourceGateFixture -Report $failedReport | Out-Null}
            catch {$failed=$true;$failureMessage=$_.Exception.Message}
            if(-not $failed -or $failureMessage -notmatch 'Source Pester snapshot or full case union differs'){throw "The original report validation failure must be preserved; observed '$failureMessage'."}
            if(-not [object]::ReferenceEquals($script:StandardValidationReadObserver,$sentinel)){throw 'The report reader must restore the caller observer after failure.'}

            $records=@($writer.ToString() -split "`r?`n" | Where-Object {$_ -match '^\[StandardValidation timing\] ' -and $_ -match '"phase":"source-report-binding"' } | ForEach-Object { ($_ -replace '^\[StandardValidation timing\] ','') | ConvertFrom-Json })
            $terminal=@($records | Where-Object {$_.state -in @('completed','failed')})
            if(@($terminal | Where-Object {$_.state -ceq 'completed' -and $_.files -gt 0 -and $_.bytes -gt 0 -and $_.calls -gt 0}).Count -ne 1 -or
                @($terminal | Where-Object {$_.state -ceq 'failed' -and $_.files -gt 0 -and $_.bytes -gt 0 -and $_.calls -gt 0}).Count -ne 1){throw 'The full report phase must report actual SHA/JSON reader calls, files, and bytes for success and failure.'}
            $reportEvidencePath=Join-Path $script:SourceMeasurementEvidenceRoot 'source-report-binding-samples.json'
            [IO.File]::WriteAllText($reportEvidencePath,(ConvertTo-Json -InputObject $terminal -Depth 5),(New-Object Text.UTF8Encoding($false)))
            if(-not [IO.File]::Exists($reportEvidencePath)){throw 'Full report binding observations must be saved under the task-run evidence root.'}
        }
        finally {
            [Console]::SetError($oldConsoleError)
            $script:StandardValidationTimingEnabled=$oldTimingEnabled
            $script:StandardValidationReadObserver=$null
        }
    }

    # Scenario: The same real frozen-file validator reports one outer call and one path/hash call per input file.
    # Purpose: Verify diagnostic counters reflect actual work rather than the default zero-call phase values.
    It 'UnitT69_counts_real_frozen_file_path_and_hash_operations' {
        $report=New-SourceGateFixture
        $files=@($report.sourceValidation.frozenFiles)
        if($files.Count -eq 0){throw 'The source fixture must include frozen files for counter validation.'}
        $expectedBytes=[long]0
        foreach($file in $files){$expectedBytes += [long](Get-Item -Force -LiteralPath ([string]$file.path)).Length}
        $oldTimingEnabled=$script:StandardValidationTimingEnabled
        $oldConsoleError=[Console]::Error
        $writer=New-Object IO.StringWriter
        $script:StandardValidationTimingEnabled=$true
        [Console]::SetError($writer)
        try {
            Assert-StandardCoreFrozenFiles -Files $files
            $records=@($writer.ToString() -split "`r?`n" | Where-Object {$_ -match '^\[StandardValidation timing\] ' -and $_ -match '"phase":"frozen-(files|file-paths|file-hashes)"' } | ForEach-Object { ($_ -replace '^\[StandardValidation timing\] ','') | ConvertFrom-Json })
            $terminal=@($records | Where-Object {$_.state -ceq 'completed'})
            $outer=@($terminal | Where-Object {$_.phase -ceq 'frozen-files'})
            $paths=@($terminal | Where-Object {$_.phase -ceq 'frozen-file-paths'})
            $hashes=@($terminal | Where-Object {$_.phase -ceq 'frozen-file-hashes'})
            if($outer.Count -ne 1 -or $outer[0].calls -ne 1 -or $outer[0].files -ne $files.Count -or $outer[0].bytes -ne $expectedBytes){throw 'The outer frozen-file validation phase must report one call and the observed file and byte totals.'}
            if($paths.Count -ne 1 -or $paths[0].calls -ne $files.Count -or $paths[0].files -ne $files.Count){throw 'Frozen-file path diagnostics must report one call per actual input path.'}
            if($hashes.Count -ne 1 -or $hashes[0].calls -ne $files.Count -or $hashes[0].files -ne $files.Count -or $hashes[0].bytes -ne $expectedBytes){throw 'Frozen-file hash diagnostics must report one call per actual file hash and the observed byte total.'}
            $evidencePath=Join-Path $script:SourceMeasurementEvidenceRoot 'frozen-file-operation-samples.json'
            [IO.File]::WriteAllText($evidencePath,(ConvertTo-Json -InputObject $terminal -Depth 5),(New-Object Text.UTF8Encoding($false)))
            if(-not [IO.File]::Exists($evidencePath)){throw 'Frozen-file operation observations must be saved under the task-run evidence root.'}
        }
        finally {
            [Console]::SetError($oldConsoleError)
            $script:StandardValidationTimingEnabled=$oldTimingEnabled
        }
    }
    }

Describe 'SYP171 internal source continuation authority binding' {
    # Scenario: a production consumer authenticates a central authority snapshot before evaluating internal continuation.
    # Purpose: bind the allowlist and both decision schemas to the signed authority inventory and its fixed evidence cardinality.
    It 'UnitT10_binds_internal_continuation_files_to_the_authenticated_authority_snapshot' {
        $root = Split-Path -Parent $PSScriptRoot
        $runnerPath = Join-Path $root 'scripts/Invoke-StandardValidation.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) { throw 'The central validation runner must remain parseable.' }
        $snapshotFunctions = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -ceq 'Assert-StandardValidationAuthoritySnapshot'
                }, $true))
        if ($snapshotFunctions.Count -ne 1) { throw 'The authority snapshot verifier must have exactly one definition.' }
        $snapshotFunction = $snapshotFunctions[0].Extent.Text
        foreach ($requiredPath in @(
                'docs/standards/internal-source-continuation.json',
                'docs/standards/schemas/internal-source-review-assessment-v1.schema.json',
                'docs/standards/schemas/internal-source-continuation-v1.schema.json',
                'docs/standards/static-parser-host-ownership.json',
                'docs/standards/schemas/static-parser-host-ownership-v1.schema.json',
                'docs/standards/schemas/static-parser-profile-execution-v1.schema.json',
                'scripts/Get-StandardPowerShellSyntaxProof.ps1',
                'scripts/Invoke-StandardStaticScan.ps1',
                'scripts/standard_static_powershell.py'
            )) {
            if ([regex]::Matches($snapshotFunction, [regex]::Escape($requiredPath)).Count -ne 1) {
                throw "The authenticated authority inventory must contain '$requiredPath' exactly once."
            }
        }

        $evidenceSchema = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'docs/standards/schemas/standard-validation-evidence-v1.schema.json') | ConvertFrom-Json
        $selectedFilesSchema = $evidenceSchema.allOf[5].then.properties.authority.properties.binding.properties.selectedFiles
        if ($selectedFilesSchema.minItems -ne 22 -or $selectedFilesSchema.maxItems -ne 22) {
            throw 'The authority evidence schema must require the complete 22-file authenticated inventory.'
        }
        $verifiedBindingSchema = $evidenceSchema.'$defs'.authorityBinding.allOf[0].then.properties.selectedFiles
        if ($verifiedBindingSchema.minItems -ne 22 -or $verifiedBindingSchema.maxItems -ne 22) {
            throw 'Every verified authority binding must retain the complete 22-file authenticated inventory.'
        }

        $standard = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'docs/standards/skill-repository-standard.md')
        if ($standard -notmatch 'authenticated authority snapshot' -or
            $standard -notmatch 'internal-source-review-assessment-v1\.schema\.json' -or
            $standard -notmatch 'internal-source-continuation-v1\.schema\.json') {
            throw 'The normative Standard must require the continuation policy and schemas to come from the authenticated authority snapshot.'
        }
        $profile = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'docs/standards/static-parser-host-ownership.json') | ConvertFrom-Json
        if ($profile.officialScannerVersion -cne '2.13.0' -or
            $profile.officialScannerReleaseCommit -cne '091a509b3d6ba8ff5be528966e1f43c2e68cf214' -or
            $profile.officialScannerReleaseAssetSha256 -cne '41e097b4127c0aa0732ad31cc909f8aee0b907d97816c866a55b8e782a6ca6dc' -or
            $profile.officialAnalyzerSha256 -cne 'c799169f9ad716f8dbbbec5892ef76affd0f9974433709ed0c1cfc3bcd0b66a4' -or
            $standard -notmatch 'SkillSpector 2\.13\.0') {
            throw 'The normative Standard and parser profile must bind the reviewed SkillSpector 2.13.0 release.'
        }
    }
    # Scenario: the central security descriptor references the internal review assessment.
    # Purpose: keep the active gate policy/schema consistent with zero authorization and inactive integration metadata.
    It 'UnitT20_keeps_internal_review_descriptor_non_authorizing' {
        $root = Split-Path -Parent $PSScriptRoot
        $gatePath = Join-Path $root 'docs/standards/validation-security-gate.json'
        $schema = Join-Path $root 'docs/standards/schemas/validation-security-gate-v1.schema.json'
        $gate = Get-Content -LiteralPath $gatePath -Raw | ConvertFrom-Json
        if (-not ((Get-Content -LiteralPath $gatePath -Raw) | Test-Json -SchemaFile $schema)) { throw 'Security descriptor schema mismatch.' }
        $review = $gate.security.internalSourceContinuation
        if ($review.technicalResult -cne 'evidence-consistency-only' -or $review.scope -cne 'internal-review-only' -or
            $review.authorizationGranted -isnot [bool] -or $review.authorizationGranted -or $review.authorizedOperations.Count -ne 0 -or
            $review.applicabilityStatus -cne 'not-verified' -or $review.executionProvenanceStatus -cne 'not-verified' -or
            $review.deferredIntegration.status -cne 'inactive' -or $review.deferredIntegration.consumerAuthority) { throw 'Security descriptor grants authority or upgrades assurance.' }
        foreach ($mutation in @('authorization', 'legacy', 'integration', 'integration-extra', 'integration-missing')) {
            $changed = $gate | ConvertTo-Json -Depth 40 | ConvertFrom-Json
            switch ($mutation) {
                authorization { $changed.security.internalSourceContinuation.authorizedOperations = @('source-merge') }
                legacy { $changed.security.internalSourceContinuation | Add-Member -NotePropertyName permittedOperationAfterProtectedAdoption -NotePropertyValue 'source-merge' }
                integration { $changed.security.internalSourceContinuation.deferredIntegration.consumerAuthority = $true }
                'integration-extra' { $changed.security.internalSourceContinuation.deferredIntegration | Add-Member -NotePropertyName authorized -NotePropertyValue $true }
                'integration-missing' { $changed.security.internalSourceContinuation.deferredIntegration.PSObject.Properties.Remove('consumerAuthority') }
            }
            if (($changed | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue) { throw "Security schema accepted $mutation." }
        }
    }

}
