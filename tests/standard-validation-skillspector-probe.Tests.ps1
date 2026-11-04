# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Runner observed SkillSpector native compatibility' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-StandardValidation.ps1') -CandidateRoot $TestDrive -AdapterPath 'unused' -ArtifactsRoot $TestDrive -SourceRepository 'https://example.test/skills.git' -SourceRevision ('a'*40) -BaseRevision ('b'*40) -DefineFunctionsOnly
        function New-ProbeClassifierFixture {
            [pscustomobject]@{ status='failed'; naturalExit=$true; exitCode=1; stdout=''; stderr='ImportError: /fixture/native.so: wrong ELF class: ELFCLASS32'; cleanedUp=$true; outputQuotaExceeded=$false; outputTruncated=$false; startupFailure=$null; processOwnership=[pscustomobject]@{terminationReason='cancelled'} }
        }
    }
    # Scenario: Captured native loader diagnostics are classified without claiming a real host probe.
    # Purpose: Only approved native incompatibility signatures qualify; Windows never qualifies.
    It 'UnitT10_classifies_native_loader_fixtures_and_rejects_Windows' {
        $p=New-ProbeClassifierFixture
        Get-StandardValidationNativeProbeFailureKind -Process $p -Platform linux | Should Be 'executable-format-unsupported'
        Get-StandardValidationNativeProbeFailureKind -Process $p -Platform windows | Should BeNullOrEmpty
        $p.stderr='ImportError: dlopen(/fixture/native.so, 0x0002): incompatible architecture (have ''x86_64'', need ''arm64'')'
        Get-StandardValidationNativeProbeFailureKind -Process $p -Platform macos | Should Be 'executable-format-unsupported'
    }
    # Scenario: A probe fails for an ordinary operational reason or has incomplete capture/cleanup.
    # Purpose: Neither generic failure nor uncertain ownership can authorize an exception.
    It 'UnitT20_rejects_non_native_errors_and_incomplete_process_evidence' {
        foreach($message in @('unsupported platform','ModuleNotFoundError: No module named skillspector','missing configuration','download failed','critical finding','exit 1')) {
            $p=New-ProbeClassifierFixture; $p.stderr=$message
            Get-StandardValidationNativeProbeFailureKind -Process $p -Platform linux | Should BeNullOrEmpty
        }
        foreach($state in @('timeout','cancelled','cleanup-failed','passed')) {
            $p=New-ProbeClassifierFixture; $p.status=$state
            Get-StandardValidationNativeProbeFailureKind -Process $p -Platform linux | Should BeNullOrEmpty
        }
        foreach($field in @('outputQuotaExceeded','outputTruncated')) {
            $p=New-ProbeClassifierFixture; $p.$field=$true
            Get-StandardValidationNativeProbeFailureKind -Process $p -Platform linux | Should BeNullOrEmpty
        }
        $p=New-ProbeClassifierFixture; $p.cleanedUp=$false
        Get-StandardValidationNativeProbeFailureKind -Process $p -Platform linux | Should BeNullOrEmpty
        $p=New-ProbeClassifierFixture; $p.naturalExit=$false
        Get-StandardValidationNativeProbeFailureKind -Process $p -Platform linux | Should BeNullOrEmpty
    }

    # Scenario: An owned PowerShell child naturally emits an approved loader diagnostic and exits nonzero.
    # Purpose: Preserve the pre-cleanup natural-exit fact even when lease cleanup records cancellation.
    Context 'Natural process exit classifier' {
        It 'InterT25_classifies_an_approved_loader_error_from_a_real_naturally_exited_process' {
            $powerShellPath=(Get-Process -Id $PID).Path
            $arguments=@('-NoProfile','-NonInteractive','-Command','[Console]::Error.WriteLine("ImportError: /tmp/x/_native.so: wrong ELF class: ELFCLASS32"); exit 1')
            $process=Invoke-StandardValidationProcess -Command $powerShellPath -Arguments $arguments -WorkingDirectory $TestDrive -Environment @{} -TimeoutSeconds 30

            $process.naturalExit | Should Be $true
            $process.status | Should Be 'failed'
            Get-StandardValidationNativeProbeFailureKind -Process $process -Platform linux | Should Be 'executable-format-unsupported'
        }
    }

    # Scenario: Only an OS failure at the owned-process launch boundary identifies executable incompatibility.
    # Purpose: A missing executable, access denial, or preflight error cannot become a platform waiver.
    It 'UnitT30_accepts_only_native_startup_codes_at_the_launch_boundary' {
        foreach ($platform in @('linux','macos')) {
            $p=New-ProbeClassifierFixture; $p.status='startup-failed'; $p.exitCode=-1
            $p.PSObject.Properties.Remove('naturalExit')
            $p.startupFailure=[pscustomobject]@{phase='start-owned-process';operation='posix_spawn';nativeErrorCode=8}
            Get-StandardValidationNativeProbeFailureKind -Process $p -Platform $platform | Should Be 'executable-format-unsupported'
            foreach ($code in @(2,5,13,126,127)) {
                $p.startupFailure.nativeErrorCode=$code
                Get-StandardValidationNativeProbeFailureKind -Process $p -Platform $platform | Should BeNullOrEmpty
            }
            $p.startupFailure.nativeErrorCode=8; $p.startupFailure.phase='open-executable'
            Get-StandardValidationNativeProbeFailureKind -Process $p -Platform $platform | Should BeNullOrEmpty
        }
    }

    # Scenario: Native probe raw output contains a fractional ISO-8601 timestamp.
    # Purpose: P2 readback preserves the exact timestamp representation for binding.
    It 'UnitT32_preserves_native_probe_timestamp_strings' {
        $path = Join-Path $TestDrive 'native-probe-timestamp.json'
        $startedAt = '2026-11-04T01:02:03.4567890+00:00'
        [IO.File]::WriteAllText($path, ('{"startedAt":"' + $startedAt + '"}'), [Text.UTF8Encoding]::new($false))

        $snapshot = Get-StandardValidationNativeProbeSnapshot -Path $path

        $snapshot.value.startedAt | Should BeOfType ([string])
        $snapshot.value.startedAt | Should Be $startedAt
    }

    Context 'Receipt freshness reference time' {
        It 'UnitT33_accepts_a_receipt_five_minutes_old_at_the_reference_time' {
            $timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-60)

            { Assert-StandardValidationFreshTimestamp -Value $timestamp.ToString('o') -Context 'fixture receipt' -MaxAgeMinutes 15 -ReferenceTime $timestamp.AddMinutes(5) } | Should Not Throw
        }

        It 'UnitT34_rejects_a_receipt_twenty_minutes_old_at_the_reference_time' {
            $timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-60)

            { Assert-StandardValidationFreshTimestamp -Value $timestamp.ToString('o') -Context 'fixture receipt' -MaxAgeMinutes 15 -ReferenceTime $timestamp.AddMinutes(20) } | Should Throw 'older than the allowed'
        }

        It 'UnitT36_preserves_current_time_freshness_when_no_reference_is_supplied' {
            $timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-60)

            { Assert-StandardValidationFreshTimestamp -Value $timestamp.ToString('o') -Context 'fixture receipt' -MaxAgeMinutes 15 } | Should Throw 'older than the allowed'
        }
    }

    Context 'Resolver receipt attestation freshness' {
        It 'UnitT37_uses_the_same_reference_time_for_the_receipt_and_attestation' {
            $resolvedAt = [DateTimeOffset]::UtcNow.AddMinutes(-60)
            $referenceTime = $resolvedAt.AddMinutes(5)
            $resolvedAtText = $resolvedAt.ToString('o')
            $runId = [guid]::NewGuid()
            $receiptPath = Join-Path $TestDrive 'resolver-receipt.json'
            $installRoot = Join-Path $TestDrive 'tool-install'
            $commandPath = Join-Path $installRoot 'skillspector.exe'
            $receipt = [pscustomobject]@{
                schemaVersion = 1
                evidenceType = 'validation-tool-resolution'
                status = 'verified'
                toolName = 'skillspector'
                source = 'fixture'
                channel = 'latest-stable'
                resolvedVersion = '1.0.0'
                resolvedIdentity = 'fixture-identity'
                installRoot = $installRoot
                executablePath = $commandPath
                executableSha256 = 'c' * 64
                installedClosureSha256 = 'd' * 64
                launcher = [pscustomobject]@{}
                launcherDigestSha256 = 'e' * 64
                resolutionRunId = $runId.ToString('N')
                resolvedAtUtc = $resolvedAtText
                attestation = [pscustomobject]@{
                    schemaVersion = 1
                    attestationType = 'trusted-supervisor-validation-tool-v1'
                    toolName = 'skillspector'
                    source = 'fixture'
                    channel = 'latest-stable'
                    status = 'verified'
                    resolvedVersion = '1.0.0'
                    resolvedIdentity = 'fixture-identity'
                    installRoot = $installRoot
                    executablePath = $commandPath
                    executableSha256 = 'c' * 64
                    installedClosureSha256 = 'd' * 64
                    launcherDigestSha256 = 'e' * 64
                    resolutionRunId = $runId.ToString('N')
                    resolvedAtUtc = $resolvedAtText
                    issuedAt = $resolvedAtText
                    signature = 'fixture'
                }
            }
            Mock New-StandardValidationPhase { [pscustomobject]@{ calls = 0 } }
            Mock Complete-StandardValidationPhase {}
            Mock Assert-StandardValidationExactPropertySet {}
            Mock Assert-StandardValidationSha256 {}
            Mock Assert-StandardValidationOutsideRoot {}
            Mock Assert-StandardValidationRegularFile {}
            Mock Get-StandardValidationJsonSnapshot { [pscustomobject]@{ sha256 = 'a' * 64; value = $receipt } }
            Mock Get-StandardValidationFullPath { $Path }
            Mock Test-Path { $true }
            Mock Test-StandardValidationPathWithin { $true }
            Mock Get-StandardValidationFileSha256 { 'c' * 64 }
            Mock Get-StandardValidationDirectoryClosureSha256 { 'd' * 64 }
            Mock Assert-StandardValidationLauncherIntegrity { 'e' * 64 }
            Mock Assert-StandardValidationLifecycleTimestamp { [string]$Value }
            Mock Assert-StandardValidationSignedReceipt {}
            Mock Assert-StandardValidationFreshTimestamp { [string]$Value }

            $provenance = [pscustomobject]@{ toolName = 'skillspector'; receiptPath = $receiptPath; receiptSha256 = 'a' * 64 }
            { Assert-StandardValidationToolReceipt -Provenance $provenance -CommandPath $commandPath -CandidateRoot $TestDrive -ArtifactsRoot $TestDrive -TrustAnchorRoot $TestDrive -RunId $runId -ExpectedToolName 'skillspector' -Context 'fixture' -FreshnessReferenceTime $referenceTime } | Should Not Throw

            Assert-MockCalled Assert-StandardValidationFreshTimestamp -Times 2 -Exactly -Scope It -ParameterFilter {
                $ReferenceTime.UtcTicks -eq $referenceTime.UtcTicks
            }
        }
    }

    Context 'Retained native probe receipt readback' {
        It 'UnitT38_uses_the_retained_event_process_start_time_for_receipt_freshness' {
            $runRoot = Join-Path $TestDrive 'retained-probe'
            $eventTime = [DateTimeOffset]::Parse('2026-11-04T01:02:03.4567890+00:00', [Globalization.CultureInfo]::InvariantCulture)
            $eventRoot = Join-Path $runRoot 'events'
            $eventPath = Join-Path $eventRoot 'static.json'
            $adapterPath = Join-Path $runRoot 'probe-adapter.json'
            $receiptPath = Join-Path $runRoot 'receipt.json'
            [void](New-Item -ItemType Directory -Path $eventRoot -Force)
            [IO.File]::WriteAllText($eventPath, ('{"process":{"startedAt":"' + $eventTime.ToString('o') + '"}}'), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($adapterPath, '{"staticAnalyzer":{"provenance":{},"command":"fixture","arguments":[]}}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($receiptPath, '{}', [Text.UTF8Encoding]::new($false))
            $report = [pscustomobject]@{
                runId = [guid]::NewGuid().ToString('N')
                candidate = [pscustomobject]@{ candidateId = 'a' * 64 }
                artifacts = [pscustomobject]@{ root = $TestDrive }
                adapter = [pscustomobject]@{ mode = 'production'; sha256 = (Get-StandardValidationJsonSnapshot -Path $adapterPath -Context 'fixture adapter').sha256 }
            }
            $event = [pscustomobject]@{
                candidateId = $report.candidate.candidateId
                stageId = 'skillspector-static'
                toolId = 'staticAnalyzer'
                outputPath = $eventPath
                commandSha256 = 'c' * 64
                eventId = [guid]::NewGuid().ToString()
            }
            Mock Assert-StandardValidationToolReceipt { [pscustomobject]@{ path = $receiptPath; executableSha256 = 'c' * 64 } }
            Mock New-StandardValidationNativeProbeContext { [pscustomobject]@{ eventId = $EventId } }
            $expectedTrustAnchorRoot = Join-Path $script:StandardValidationRepositoryRoot 'docs/standards/trust-anchors'

            $result = Get-StandardValidationAdvancedProbeContext -Report $report -Event $event

            $result.eventId | Should Be $event.eventId
            Assert-MockCalled Assert-StandardValidationToolReceipt -Times 1 -Exactly -Scope It -ParameterFilter {
                $FreshnessReferenceTime.UtcTicks -eq $eventTime.UtcTicks -and
                [string]$TrustAnchorRoot -ceq $expectedTrustAnchorRoot
            }
        }

        It 'UnitT39_blocks_development_harness_retained_readback' {
            $candidateId = 'a' * 64
            $report = [pscustomobject]@{
                candidate = [pscustomobject]@{ candidateId = $candidateId }
                artifacts = [pscustomobject]@{ root = $TestDrive }
                adapter = [pscustomobject]@{ mode = 'development-harness' }
            }
            $event = [pscustomobject]@{
                candidateId = $candidateId
                stageId = 'skillspector-static'
                toolId = 'staticAnalyzer'
                outputPath = (Join-Path $TestDrive 'development-harness/events/static.json')
            }

            { Get-StandardValidationAdvancedProbeContext -Report $report -Event $event } | Should Throw 'BLOCKED|Native probe retained readback requires the immutable trust-anchor root.'
        }

        It 'UnitT41_rejects_a_retained_event_without_its_process_start_time' {
            $runRoot = Join-Path $TestDrive 'missing-event-timestamp'
            $eventRoot = Join-Path $runRoot 'events'
            $eventPath = Join-Path $eventRoot 'static.json'
            [void](New-Item -ItemType Directory -Path $eventRoot -Force)
            [IO.File]::WriteAllText($eventPath, '{"process":{}}', [Text.UTF8Encoding]::new($false))
            $candidateId = 'a' * 64
            $report = [pscustomobject]@{
                candidate = [pscustomobject]@{ candidateId = $candidateId }
                artifacts = [pscustomobject]@{ root = $TestDrive }
            }
            $event = [pscustomobject]@{ candidateId = $candidateId; stageId = 'skillspector-static'; toolId = 'staticAnalyzer'; outputPath = $eventPath }

            { Get-StandardValidationAdvancedProbeContext -Report $report -Event $event } | Should Throw 'BLOCKED|Native probe event timestamp is missing.'
        }
    }

    # Scenario: P3 wraps a posix_spawn errno in an invocation exception.
    # Purpose: Preserve the actual native error without interpreting diagnostic text or unrelated P2 errors.
    It 'UnitT35_reads_typed_P3_errno_and_rejects_forged_error_text' {
        Initialize-StandardValidationPlatformRuntime
        $native=New-Object SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException -ArgumentList @('posix_spawn',8)
        $wrapped=[InvalidOperationException]::new('outer',$native)
        (Get-StandardValidationNativeStartupFailure -Exception $wrapped -Phase 'start-owned-process').nativeErrorCode | Should Be 8
        Get-StandardValidationNativeStartupFailure -Exception ([Exception]::new('Native operation posix_spawn failed with errno 8')) -Phase 'start-owned-process' | Should BeNullOrEmpty
        $fileError=New-Object SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException -ArgumentList @('open',8)
        Get-StandardValidationNativeStartupFailure -Exception $fileError -Phase 'start-owned-process' | Should BeNullOrEmpty
    }

    # Scenario: The child supplies plausible incompatibility text and digests without a runner context.
    # Purpose: No wrapper or replayed child claim may establish its own authority.
    It 'UnitT40_rejects_wrapper_claims_without_independent_runner_context' {
        $claim=[pscustomobject]@{nativeProbe=[pscustomobject]@{probeExecuted=$true;binding=[pscustomobject]@{eventId=[guid]::NewGuid().ToString()};outputSha256=('a'*64)}}
        { Assert-StandardValidationNativeProbeEvidence -Evidence $claim -HostPlatform linux } | Should Throw 'runner-observed'
    }

    # Scenario: A retained claim comes from a different run, candidate, event, dispatch argv, or receipt.
    # Purpose: Reject replay and tampering before opening attacker-selected artifact paths.
    It 'UnitT50_rejects_replay_wrong_event_changed_argv_and_receipt_digests' {
        $expected=[pscustomobject][ordered]@{runId=('a'*32);candidateId=('b'*64);eventId=[guid]::NewGuid().ToString();dispatchCommandSha256=('c'*64);dispatchArgumentsSha256=('d'*64);toolReceiptSha256=('e'*64);runtimeReceiptSha256=('f'*64);arguments=@('--help');argumentsSha256=('1'*64)}
        foreach ($field in @('runId','candidateId','eventId','dispatchCommandSha256','dispatchArgumentsSha256','toolReceiptSha256','runtimeReceiptSha256','arguments','argumentsSha256')) {
            $changed=$expected | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $changed.$field='changed'
            $claim=[pscustomobject]@{nativeProbe=[pscustomobject]@{probeExecuted=$true;binding=$changed;outputSha256=('a'*64)}}
            { Assert-StandardValidationNativeProbeEvidence -Evidence $claim -ProbeContext $expected -HostPlatform linux } | Should Throw 'binding differs'
        }
    }

    # Scenario: A successful compatibility probe is followed by a failing Static process.
    # Purpose: Compatibility cannot mask findings, incomplete coverage, or a normal scan failure.
    It 'UnitT60_keeps_scan_failure_after_a_successful_probe' {
        $result=[pscustomobject]@{status='failed';exitCode=1}
        $envelope=[pscustomobject]@{schemaVersion=1;status='failed';decision='FAIL';candidateIdentity=('a'*64)}
        { Assert-StandardValidationToolEnvelope -Stdout ($envelope | ConvertTo-Json -Compress) -ProcessResult $result -CandidateId ('a'*64) -Context 'probe-success-scan-failure' -ProbeContext ([pscustomobject]@{eventId='fixture'}) } | Should Throw "process status was 'failed'"
    }

    # Scenario: The native compatibility probe is cancelled before it can establish a platform result.
    # Purpose: Propagate cancellation without classifying it as an incompatibility or blocker.
    Context 'Cancelled native probe' {
        It 'UnitT62_propagates_cancellation_without_classifying_the_probe_failure' {
            $context=[pscustomobject]@{commandPath='fixture';arguments=@();outputPath=(Join-Path $TestDrive 'cancelled-probe.json')}
            Mock Assert-StandardValidationNativeProbeContextUnchanged {}
            Mock Invoke-StandardValidationProcess { [pscustomobject]@{status='cancelled';exitCode=1} }
            Mock Write-StandardValidationJsonCreate {}
            Mock Get-StandardValidationFileSha256 { 'a'*64 }
            Mock Register-StandardValidationEvidenceArtifact {}
            Mock Get-StandardValidationNativeProbeFailureKind { throw 'The cancellation must not be classified.' }
            { Invoke-StandardValidationNativeProbe -ProbeContext $context -WorkingDirectory $TestDrive -TimeoutSeconds 10 -CancellationPath (Join-Path $TestDrive 'cancel') -HostPlatform linux -Policy ([pscustomobject]@{}) } | Should Throw 'CANCELLED|'
            Assert-MockCalled Get-StandardValidationNativeProbeFailureKind -Times 0 -Exactly -Scope It
        }
    }

    # Scenario: The native compatibility step returns success and normal Static then fails.
    # Purpose: Exercise dispatch sequencing; a successful probe cannot replace or waive the scan.
    # Pester 4 keeps mocks until Context/Describe exit, not It exit.
    Context 'Compatible probe dispatch' {
        It 'InterT65_dispatches_normal_Static_after_probe_success_and_preserves_its_failure' {
            $root=Join-Path $TestDrive 'probe-then-scan'; [void][IO.Directory]::CreateDirectory($root)
            Initialize-StandardValidationPlatformRuntime
            $root=Resolve-StandardValidationPhysicalCommandPath -Path ((Get-Item -LiteralPath $root).FullName)
            $commandPath=Join-Path $root 'scanner'; [IO.File]::WriteAllText($commandPath,'scanner identity fixture')
            $command=[pscustomobject]@{command=$commandPath;commandSha256=Get-StandardValidationFileSha256 $commandPath fixture;arguments=@('scan');toolReceipt=$null}
            Mock Assert-StandardValidationCandidateAcquisitionArtifactsUnchanged {}
            Mock Assert-StandardValidationSnapshotUnchanged {}
            Mock Assert-StandardValidationEvidenceArtifacts {}
            Mock New-StandardValidationNativeProbeContext { [pscustomobject]@{eventId='fixture'} }
            Mock Invoke-StandardValidationNativeProbe { $null }
            Mock Invoke-StandardValidationProcess { throw 'FAILED|Normal Static failed after compatible probe.' }
            $receipt=[pscustomobject]@{launcher=[pscustomobject]@{kind='skillspector-python'};resolutionRunId=[guid]::NewGuid().ToString('N')}
            { Invoke-StandardValidationCommandAndRecord -CommandSpec $command -RunRoot $root -ChildWorkingRoot $root -StageId skillspector-static -ToolId static-analyzer -CandidateId ('a'*64) -SnapshotRoot $root -ExpectedSnapshotContentSha256 ('b'*64) -SkillsRoot $root -ActiveSkillsText fixture -OriginalCandidateRoot $root -ExpectedCandidateContentSha256 ('b'*64) -AdapterPath $commandPath -ExpectedAdapterSha256 $command.commandSha256 -TimeoutSeconds 10 -NativeProbeReceipt $receipt -NativeProbeReceiptBinding ([pscustomobject]@{}) } | Should Throw 'Normal Static failed after compatible probe'
            Assert-MockCalled Invoke-StandardValidationNativeProbe -Times 1 -Exactly -Scope It
            Assert-MockCalled Invoke-StandardValidationProcess -Times 1 -Exactly -Scope It
        }
    }

    # Scenario: The signed launcher binds a file named Python which is actually a script wrapper.
    # Purpose: A matching hash alone cannot turn wrapper output into a native probe.
    It 'UnitT70_rejects_receipt_tamper_and_script_wrappers' {
        $root=Join-Path $TestDrive 'native-header'; [void][IO.Directory]::CreateDirectory($root)
        $runtime=Join-Path $root 'python'; [IO.File]::WriteAllText($runtime,'#!/bin/sh')
        $receipt=Join-Path $TestDrive 'native-receipt.json'; [IO.File]::WriteAllText($receipt,'{}')
        $context=[pscustomobject]@{commandPath=$runtime;commandSha256=Get-StandardValidationFileSha256 $runtime 'fixture';receiptPath=$receipt;toolReceiptSha256=Get-StandardValidationFileSha256 $receipt 'fixture';installRoot=$root;installedClosureSha256=Get-StandardValidationDirectoryClosureSha256 $root 'fixture'}
        { Assert-StandardValidationNativeProbeContextUnchanged $context } | Should Throw 'wrapper'
        [IO.File]::WriteAllText($receipt,'{"tampered":true}')
        { Assert-StandardValidationNativeProbeContextUnchanged $context } | Should Throw 'receipt or runtime changed'
    }

    # Scenario: Package Validation fails before the Static dispatch in Core source validation.
    # Purpose: The new compatibility route must never bypass the package gate.
    # Pester 4 keeps mocks until Context/Describe exit, not It exit.
    Context 'Failed Package Validation dispatch' {
        It 'InterT80_does_not_probe_or_scan_after_failed_Package_Validation' {
            $runRoot=Join-Path $TestDrive 'package-gate'; [void][IO.Directory]::CreateDirectory($runRoot)
            $path=Join-Path $runRoot 'adapter.json'; [IO.File]::WriteAllText($path,'{}')
            $hash=Get-StandardValidationFileSha256 $path fixture
            $script:ProbePackageCommand=[pscustomobject]@{command=$path;commandSha256=$hash;arguments=@();toolReceipt=$null}
            $spec=[pscustomobject]@{packageAdapter=$script:ProbePackageCommand;skillValidator=$script:ProbePackageCommand;skillTools=$script:ProbePackageCommand;staticAnalyzer=$script:ProbePackageCommand;frozenFiles=@([pscustomobject]@{path=$path;sha256=$hash});toolReceipts=@()}
            Mock Assert-StandardCoreFrozenFiles {}
            Mock Assert-StandardCoreSourceToolReceipts { [pscustomobject]@{receipts=@{};bindings=@{}} }
            Mock Assert-StandardValidationCommandSpec { $script:ProbePackageCommand }
            Mock Invoke-StandardValidationCommandAndRecord { throw 'FAILED|Package Validation fixture failed.' }
            Mock Invoke-StandardValidationNativeProbe { throw 'Probe must not run.' }
            $skills=[pscustomobject]@{root=$runRoot;relative='skills';ids=@('fixture');records=@([pscustomobject]@{id='fixture';inventorySha256=('a'*64)})}
            { Invoke-StandardCoreSourceTools -Spec $spec -SkillSet $skills -RunId ([guid]::NewGuid().ToString('N')) -SourceRevision ('a'*40) -AuthorityRevision ('b'*40) -SnapshotRoot $runRoot -ContentSha256 ('c'*64) -RunRoot $runRoot -AdapterPath $path -AdapterSha256 $hash -ArtifactsRoot $runRoot -TrustedToolRoot $runRoot -TimeoutSeconds 10 -ValidationSecurityPolicy ([pscustomobject]@{}) } | Should Throw 'Package Validation fixture failed'
            Assert-MockCalled Invoke-StandardValidationCommandAndRecord -Times 1 -Exactly -Scope It -ParameterFilter {$StageId -ceq 'package-validation'}
            Assert-MockCalled Invoke-StandardValidationCommandAndRecord -Times 0 -Exactly -Scope It -ParameterFilter {$StageId -ceq 'skillspector-static'}
            Assert-MockCalled Invoke-StandardValidationNativeProbe -Times 0 -Exactly -Scope It
        }
    }

    # Scenario: Synthetic native startup evidence is retained with P2, read back, and then tampered with.
    # Purpose: Exercise the classifier/binding artifact contract only; this is not a SkillSpector host compatibility result.
    It 'InterT90_binds_P2_classifier_fixture_bytes_and_rejects_tampered_capture' {
        $root=Join-Path $TestDrive 'probe-artifact'; [void][IO.Directory]::CreateDirectory($root)
        # Resolve the test directory to its physical spelling on macOS.
        $root=(Get-Item -LiteralPath $root).FullName
        Initialize-StandardValidationPlatformRuntime
        $root=Resolve-StandardValidationPhysicalCommandPath -Path $root
        $install=Join-Path $root 'installed'; [void][IO.Directory]::CreateDirectory($install)
        $runtime=Join-Path $install 'python'; [IO.File]::WriteAllBytes($runtime,[byte[]]@(127,69,76,70))
        $runtimeHash=Get-StandardValidationFileSha256 $runtime fixture
        $runId=[guid]::NewGuid().ToString('N')
        $launcher=[pscustomobject]@{kind='skillspector-python';shimPath=$runtime;shimSha256=$runtimeHash;payloadPath=$runtime;payloadSha256=$runtimeHash;runtimePath=$runtime;runtimeSha256=$runtimeHash}
        $receipt=[pscustomobject]@{toolName='skillspector';source='NVIDIA/SkillSpector';resolutionRunId=$runId;launcher=$launcher;launcherDigestSha256=Get-StandardValidationLauncherDigest $launcher fixture;installRoot=$install;installedClosureSha256=Get-StandardValidationDirectoryClosureSha256 $install fixture}
        $receiptPath=Join-Path $root 'receipt.json'; [IO.File]::WriteAllText($receiptPath,($receipt | ConvertTo-Json -Depth 10))
        $receiptBinding=[pscustomobject]@{path=$receiptPath;sha256=Get-StandardValidationFileSha256 $receiptPath fixture}
        $command=[pscustomobject]@{commandSha256=$runtimeHash;arguments=@('scan','fixture')}
        $eventId=[guid]::NewGuid().ToString()
        $context=New-StandardValidationNativeProbeContext -CommandSpec $command -Receipt $receipt -ReceiptBinding $receiptBinding -RunId $runId -CandidateId ('c'*64) -EventId $eventId -RunRoot $root
        $context.schemaVersion | Should Be 1
        $context.outputPath | Should Be (Join-Path (Join-Path $root 'events') ("probe-$eventId.json"))
        $process=New-ProbeClassifierFixture; $process.status='startup-failed'; $process.exitCode=-1
        $process.startupFailure=[pscustomobject]@{phase='start-owned-process';operation='posix_spawn';nativeErrorCode=8}
        $process.processOwnership | Add-Member -NotePropertyName commandPath -NotePropertyValue $runtime
        $raw=[pscustomobject]@{schemaVersion=1;evidenceType='runner-native-skillspector-probe-v1';probeExecuted=$true;binding=$context;process=$process}
        [void](Write-StandardValidationJsonCreate -Path $context.outputPath -Value $raw -Context 'classifier fixture')
        $rawHash=Get-StandardValidationFileSha256 $context.outputPath fixture
        $evidence=[pscustomobject]@{nativeProbe=[pscustomobject]@{probeExecuted=$true;binding=$context;outputSha256=$rawHash};rawResult=$rawHash;runtimeIdentity=$context.runtimeReceiptSha256;toolIdentity=$context.toolReceiptSha256;attemptedCommand=$runtime;failureKind='executable-format-unsupported'}
        $evidence.nativeProbe.binding.outputPath | Should Be $context.outputPath
        { Assert-StandardValidationNativeProbeEvidence -Evidence $evidence -ProbeContext $context -HostPlatform linux } | Should Not Throw
        { Assert-StandardValidationNativeProbeEvidence -Evidence $evidence -ProbeContext $context -HostPlatform windows } | Should Throw 'no approved native incompatibility'
        [IO.File]::AppendAllText($context.outputPath,' ')
        { Assert-StandardValidationNativeProbeEvidence -Evidence $evidence -ProbeContext $context -HostPlatform linux } | Should Throw 'hash differs'
        # Even a self-consistent new hash cannot authorize uncertain cleanup.
        $raw.process.cleanedUp=$false
        [IO.File]::WriteAllText($context.outputPath,($raw | ConvertTo-Json -Depth 30))
        $evidence.rawResult=Get-StandardValidationFileSha256 $context.outputPath fixture
        $evidence.nativeProbe.outputSha256=$evidence.rawResult
        { Assert-StandardValidationNativeProbeEvidence -Evidence $evidence -ProbeContext $context -HostPlatform linux } | Should Throw 'no approved native incompatibility'
    }
}
