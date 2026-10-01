Describe 'Standard entry point binding and result contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ModulePath = Join-Path $script:RepositoryRoot 'scripts/StandardEntryPointContract.psm1'
        $script:CliPath = Join-Path $script:RepositoryRoot 'scripts/Test-StandardEntryPointResult.ps1'
        $script:GitSafeRoot = $script:RepositoryRoot.Replace('\', '/')
        $script:SourceHead = (& git -c "safe.directory=$script:GitSafeRoot" -C $script:RepositoryRoot rev-parse HEAD).Trim()
        $script:SourceParent = (& git -c "safe.directory=$script:GitSafeRoot" -C $script:RepositoryRoot log -n 1 --format=%P HEAD).Trim().Split(' ')[0]

        function Import-StandardEntryContractForTest {
            if (-not (Test-Path -LiteralPath $script:ModulePath -PathType Leaf)) {
                throw 'MISSING_BEHAVIOR|The standard entry binding/result API is not implemented.'
            }
            Import-Module -Name $script:ModulePath -Force -Global -ErrorAction Stop
        }

        function Invoke-EntryTestGit {
            param([string] $Root, [string[]] $Arguments)
            $safeRoot = $Root.Replace('\', '/')
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                # Windows PowerShell 5.1 surfaces Git's normal stderr as a terminating error under Stop.
                $ErrorActionPreference = 'Continue'
                $output = & git -c "safe.directory=$safeRoot" -C $Root @Arguments 2>&1
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previousErrorActionPreference }
            if ($exitCode -ne 0) {
                throw "FIXTURE_GIT_FAILED|git $($Arguments -join ' ') : $($output -join [Environment]::NewLine)"
            }
            return @($output)
        }

        function New-EntrySnapshotRoot {
            param([string] $Name, [string] $Revision)
            $root = Join-Path $TestDrive ('entry-' + $Name + '-' + [Guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $root -Force)
            $source = $script:RepositoryRoot
            $sourceSafe = $source.Replace('\', '/')
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $cloneOutput = & git -c "safe.directory=$sourceSafe" clone --local --no-hardlinks --no-checkout $source $root 2>&1
                $cloneExit = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previousErrorActionPreference }
            if ($cloneExit -ne 0) { throw "FIXTURE_CLONE_FAILED|$Name : $($cloneOutput -join [Environment]::NewLine)" }
            [void](Invoke-EntryTestGit -Root $root -Arguments @('checkout', '--detach', $Revision))
            return $root
        }

        function New-EntrySnapshotPair {
            param(
                [string] $Name,
                [string] $CandidateRevision = $script:SourceHead,
                [string] $AuthorityRevision = $script:SourceParent
            )
            $candidate = New-EntrySnapshotRoot -Name ($Name + '-candidate') -Revision $CandidateRevision
            $authority = New-EntrySnapshotRoot -Name ($Name + '-authority') -Revision $AuthorityRevision
            [pscustomobject]@{
                root = Split-Path -Parent $candidate
                candidate = $candidate
                authority = $authority
                candidateRevision = $CandidateRevision
                authorityRevision = $AuthorityRevision
                currentRevision = $CandidateRevision
            }
        }

        function New-EntryTestBinding {
            param($Snapshots, [string] $CandidateRevision, [string] $AuthorityRevision, [switch] $AllowDevelopmentContent)
            Import-StandardEntryContractForTest
            $arguments = @{
                CandidateRoot = $Snapshots.candidate
                AuthorityRoot = $Snapshots.authority
                CandidateRevision = $CandidateRevision
                AuthorityRevision = $AuthorityRevision
                EntryId = 'standard-v1-authority'
                EventName = 'local-contract'
                RequiredChecks = @('Standard v1 authority gate')
                ResultArtifact = 'authority-entry-result.json'
            }
            if ($AllowDevelopmentContent) { $arguments.AllowDevelopmentContent = $true }
            New-StandardEntryPointBinding @arguments
        }

        function New-EntryTestResult {
            param($Binding)
            [pscustomobject][ordered]@{
                schemaVersion = 1
                binding = $Binding
                status = 'passed'
                executed = $true
                releaseEligible = $false
                checks = @(
                    [pscustomobject][ordered]@{
                        name = 'Standard v1 authority gate'
                        status = 'passed'
                        executed = $true
                        exitCode = 0
                    }
                )
            }
        }

        function Copy-EntryTestObject {
            param($Value)
            return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 16 -Compress) -ErrorAction Stop)
        }

        function Get-EntryCallFailure {
            param([scriptblock] $Action)
            try {
                & $Action | Out-Null
                return $null
            }
            catch { return $_.Exception.Message }
        }

        function Get-EntryTestRuntimeExecutable {
            $entryTestOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
            if ($entryTestOnWindows) {
                if ($PSVersionTable.PSEdition -eq 'Desktop') { $executableName = 'powershell.exe' }
                else { $executableName = 'pwsh.exe' }
            }
            else {
                if ($PSVersionTable.PSEdition -ne 'Core') { throw 'RUNTIME_EXECUTABLE_UNSUPPORTED|Non-Windows test runtime must use PowerShell Core.' }
                $executableName = 'pwsh'
            }

            $executable = Join-Path $PSHOME $executableName
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
                throw "RUNTIME_EXECUTABLE_MISSING|The current runtime executable was not found at '$executable'."
            }
            return [IO.Path]::GetFullPath($executable)
        }

        function Get-EntryTestFileSha256 {
            param([string] $Path)

            $algorithm = [Security.Cryptography.SHA256]::Create()
            $stream = $null
            try {
                $stream = [IO.File]::OpenRead($Path)
                $hashBytes = $algorithm.ComputeHash($stream)
                return ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
                $algorithm.Dispose()
            }
        }

        function Invoke-EntryTestRuntimeProcess {
            param([string] $Executable, [string[]] $Arguments)

            $maximumOutputCharacters = 32768
            $output = New-Object System.Text.StringBuilder
            $truncated = $false
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                & $Executable @Arguments 2>&1 | ForEach-Object {
                $line = [string]$_
                if ($output.Length -lt $maximumOutputCharacters) {
                    $remaining = $maximumOutputCharacters - $output.Length
                    if ($line.Length -gt $remaining) {
                        [void]$output.Append($line.Substring(0, $remaining))
                        $truncated = $true
                    }
                    else { [void]$output.AppendLine($line) }
                }
                else { $truncated = $true }
                }
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previousErrorActionPreference }

            [pscustomobject]@{
                output = $output.ToString()
                exitCode = $exitCode
                truncated = $truncated
            }
        }
    }

    # Scenario: Candidate and authority are checked out from two real local Git snapshots with distinct full revisions.
    # Purpose: Prove a valid binding records both independently verified snapshot identities and their input inventories.
    It 'UnitT10_creates_binding_for_two_real_snapshots' {
        $snapshots = New-EntrySnapshotPair -Name 'two-real-snapshots'
        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision

        $binding.schemaVersion | Should Be 1
        $binding.candidateRevision | Should Be $snapshots.candidateRevision
        $binding.authorityRevision | Should Be $snapshots.authorityRevision
        $binding.candidateRevision | Should Not Be $binding.authorityRevision
        @($binding.inputFileManifest | Where-Object role -eq 'candidate').Count | Should BeGreaterThan 0
        @($binding.inputFileManifest | Where-Object role -eq 'authority').Count | Should BeGreaterThan 0
    }

    # Scenario: A caller supplies a candidate revision that differs from the candidate checkout's actual HEAD.
    # Purpose: Reject revision substitution independently of ambient workflow environment variables.
    It 'UnitT20_rejects_candidate_revision_mismatch' {
        $snapshots = New-EntrySnapshotPair -Name 'revision-mismatch'
        $wrongRevision = $snapshots.authorityRevision
        $failureMessage = $null
        try {
            New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $wrongRevision -AuthorityRevision $snapshots.authorityRevision | Out-Null
        }
        catch { $failureMessage = $_.Exception.Message }
        $failureMessage | Should Match 'candidateRevision|candidate revision'
    }

    # Scenario: The runtime environment contains a workflow SHA that differs from both explicit checkout identities.
    # Purpose: Keep binding tied to the two supplied Git roots instead of ambient GITHUB_SHA.
    It 'UnitT25_uses_explicit_revisions_instead_of_GITHUB_SHA' {
        $snapshots = New-EntrySnapshotPair -Name 'github-sha'
        $previousGithubSha = $env:GITHUB_SHA
        try {
            $env:GITHUB_SHA = 'ffffffffffffffffffffffffffffffffffffffff'
            $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
            $binding.candidateRevision | Should Be $snapshots.candidateRevision
            $binding.authorityRevision | Should Be $snapshots.authorityRevision
        }
        finally {
            if ($null -eq $previousGithubSha) { Remove-Item Env:\GITHUB_SHA -ErrorAction SilentlyContinue }
            else { $env:GITHUB_SHA = $previousGithubSha }
        }
    }

    # Scenario: Same-revision candidate and authority snapshots differ only by a controlled tracked standard-file edit.
    # Purpose: Hash the candidate's actual development bytes and require explicit opt-in for immutable-mode rejection.
    It 'UnitT30_hashes_current_development_bytes_and_rejects_implicit_dirty_content' {
        $snapshots = New-EntrySnapshotPair -Name 'current-dev-bytes' -CandidateRevision $script:SourceHead -AuthorityRevision $script:SourceHead
        $candidateRevision = (Invoke-EntryTestGit -Root $snapshots.candidate -Arguments @('rev-parse', '--verify', 'HEAD^{commit}') | Select-Object -Last 1).Trim()
        $authorityRevision = (Invoke-EntryTestGit -Root $snapshots.authority -Arguments @('rev-parse', '--verify', 'HEAD^{commit}') | Select-Object -Last 1).Trim()
        $candidateRevision | Should Be $script:SourceHead
        $authorityRevision | Should Be $script:SourceHead

        $candidateStandardPath = Join-Path $snapshots.candidate 'docs/standards/skill-repository-standard.md'
        $authorityStandardPath = Join-Path $snapshots.authority 'docs/standards/skill-repository-standard.md'
        [IO.File]::AppendAllText($candidateStandardPath, [Environment]::NewLine + '# SYP-226 UnitT30 development-candidate fixture' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $candidateStatus = Invoke-EntryTestGit -Root $snapshots.candidate -Arguments @('status', '--porcelain=v1')
        $candidateStatus | Should Match '^ M docs/standards/skill-repository-standard\.md$'
        $authorityStatus = @(Invoke-EntryTestGit -Root $snapshots.authority -Arguments @('status', '--porcelain=v1') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $authorityStatus.Count | Should Be 0

        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $script:SourceHead -AuthorityRevision $script:SourceHead -AllowDevelopmentContent
        $binding.contentMode | Should Be 'development'

        $developmentTestHash = Get-EntryTestFileSha256 -Path (Join-Path $snapshots.candidate 'tests/standard-entry-point-binding.Tests.ps1')
        $developmentTestEntry = @($binding.inputFileManifest | Where-Object { $_.role -ceq 'candidate' -and $_.path -ceq 'tests/standard-entry-point-binding.Tests.ps1' })
        $developmentTestEntry.Count | Should Be 1
        $developmentTestEntry[0].sha256 | Should Be $developmentTestHash

        $developmentStandardHash = Get-EntryTestFileSha256 -Path $candidateStandardPath
        $authorityStandardHash = Get-EntryTestFileSha256 -Path $authorityStandardPath
        $candidateStandard = @($binding.inputFileManifest | Where-Object { $_.role -ceq 'candidate' -and $_.path -ceq 'docs/standards/skill-repository-standard.md' })[0]
        $authorityStandard = @($binding.inputFileManifest | Where-Object { $_.role -ceq 'authority' -and $_.path -ceq 'docs/standards/skill-repository-standard.md' })[0]
        $candidateStandard.sha256 | Should Be $developmentStandardHash
        $authorityStandard.sha256 | Should Be $authorityStandardHash
        $candidateStandard.sha256 | Should Not Be $authorityStandard.sha256

        $immutableArguments = @{
            CandidateRoot = $snapshots.candidate
            AuthorityRoot = $snapshots.authority
            CandidateRevision = $script:SourceHead
            AuthorityRevision = $script:SourceHead
            EntryId = 'standard-v1-authority'
            EventName = 'local-contract'
            RequiredChecks = @('Standard v1 authority gate')
            ResultArtifact = 'authority-entry-result.json'
        }
        $failureMessage = $null
        try { New-StandardEntryPointBinding @immutableArguments | Out-Null }
        catch { $failureMessage = $_.Exception.Message }
        $failureMessage | Should Match 'development|dirty|untracked|modified'
    }

    # Scenario: A development candidate explicitly stages a regular tracked test file rename while keeping HEAD unchanged.
    # Purpose: Bind the actual staged path and bytes without weakening immutable mode or accepting an unstaged missing file.
    It 'UnitT35_binds_a_staged_rename_only_in_development_mode' {
        $snapshots = New-EntrySnapshotPair -Name 'staged-rename'
        $oldPath = 'tests/license-delivery.Tests.ps1'
        $newPath = 'tests/license-delivery.Advanced.ps1'
        [void](Invoke-EntryTestGit -Root $snapshots.candidate -Arguments @('mv', '--', $oldPath, $newPath))

        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision -AllowDevelopmentContent
        $candidatePaths = @($binding.inputFileManifest | Where-Object role -eq 'candidate' | ForEach-Object path)
        ($candidatePaths -ccontains $newPath) | Should Be $true
        ($candidatePaths -ccontains $oldPath) | Should Be $false
        $binding.contentMode | Should Be 'development'

        $immutableFailure = Get-EntryCallFailure {
            New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
        }
        $immutableFailure | Should Match 'immutable content mode rejects modified or untracked input files'
    }
    # Scenario: A snapshot loses a tracked contract input, contains a reparse path, or presents malformed typed manifest data.
    # Purpose: Stop binding creation and typed assertions when the declared inventory cannot describe regular, safe snapshot bytes.
    It 'UnitT40_rejects_missing_unsafe_duplicate_and_wrongly_typed_inputs' {
        $missing = New-EntrySnapshotPair -Name 'missing-tracked-input'
        Remove-Item -LiteralPath (Join-Path $missing.candidate 'scripts/Invoke-StandardAuthorityGate.ps1') -Force
        $missingFailure = Get-EntryCallFailure {
            New-EntryTestBinding -Snapshots $missing -CandidateRevision $missing.candidateRevision -AuthorityRevision $missing.authorityRevision -AllowDevelopmentContent
        }
        $missingFailure | Should Match 'missing|tracked|inventory'

        $reparse = New-EntrySnapshotPair -Name 'reparse-input'
        $junctionPath = Join-Path $reparse.candidate 'tests/linked-standards'
        $junctionTarget = Join-Path $reparse.candidate 'docs/standards'
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop)
        }
        else {
            [void](New-Item -ItemType SymbolicLink -Path $junctionPath -Target $junctionTarget -ErrorAction Stop)
        }
        $reparseFailure = Get-EntryCallFailure {
            New-EntryTestBinding -Snapshots $reparse -CandidateRevision $reparse.candidateRevision -AuthorityRevision $reparse.authorityRevision -AllowDevelopmentContent
        }
        $reparseFailure | Should Match 'reparse|symbolic|unsafe|regular'

        $valid = New-EntrySnapshotPair -Name 'typed-binding'
        $binding = New-EntryTestBinding -Snapshots $valid -CandidateRevision $valid.candidateRevision -AuthorityRevision $valid.authorityRevision
        Import-StandardEntryContractForTest
        $mutations = @(
            @{ name = 'duplicate manifest path'; apply = { param($value) $value.inputFileManifest = @($value.inputFileManifest) + @($value.inputFileManifest[0]) } },
            @{ name = 'unsafe manifest path'; apply = { param($value) $value.inputFileManifest[0].path = '../outside.json' } },
            @{ name = 'wrong runtime type'; apply = { param($value) $value.runtime.psVersion = 7 } },
            @{ name = 'unknown binding field'; apply = { param($value) Add-Member -InputObject $value -NotePropertyName unknown -NotePropertyValue $true } }
        )
        foreach ($mutation in $mutations) {
            $changed = Copy-EntryTestObject -Value $binding
            & $mutation.apply $changed
            $failure = Get-EntryCallFailure { Assert-StandardEntryPointBinding -Binding $changed }
            if ([string]::IsNullOrWhiteSpace($failure)) { throw "BINDING_ACCEPTED_INVALID|$($mutation.name)" }
        }
    }

    # Scenario: A binding JSON file repeats a decoded property name literally or through a JSON escape.
    # Purpose: Reject duplicate-key ambiguity before PowerShell's JSON decoder can silently keep one value.
    It 'UnitT45_rejects_duplicate_decoded_json_properties' {
        $snapshots = New-EntrySnapshotPair -Name 'duplicate-json'
        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
        Import-StandardEntryContractForTest
        $json = ConvertTo-Json -InputObject $binding -Depth 16 -Compress
        foreach ($duplicate in @(
            $json.Replace('{"schemaVersion":1,', '{"schemaVersion":1,"schemaVersion":1,'),
            $json.Replace('{"schemaVersion":1,', '{"schemaVersion":1,"\u0073chemaVersion":1,')
        )) {
            $path = Join-Path $snapshots.root ([Guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($path, $duplicate, (New-Object Text.UTF8Encoding($false)))
            $failure = Get-EntryCallFailure { Assert-StandardEntryPointBinding -BindingPath $path }
            $failure | Should Match 'duplicate|unambiguous|ambiguous'
        }
    }

    # Scenario: A typed binding and a UTF-8 JSON binding each contain the complete valid shape from real snapshots.
    # Purpose: Keep object and path parameter sets aligned with schema version 1 without normalizing missing or extra data.
    It 'UnitT50_accepts_complete_typed_and_json_bindings' {
        $snapshots = New-EntrySnapshotPair -Name 'binding-positive'
        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
        $bindingPath = Join-Path $snapshots.root 'binding.json'
        [IO.File]::WriteAllText($bindingPath, (ConvertTo-Json -InputObject $binding -Depth 16), (New-Object Text.UTF8Encoding($false)))

        Import-StandardEntryContractForTest
        (Assert-StandardEntryPointBinding -Binding $binding) | Should Be $true
        (Assert-StandardEntryPointBinding -BindingPath $bindingPath) | Should Be $true

        $testJson = Get-Command -Name Test-Json -ErrorAction SilentlyContinue
        if ($null -ne $testJson) {
            (Get-Content -Raw -LiteralPath $bindingPath | Test-Json -SchemaFile (Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-entry-binding-v1.schema.json')) | Should Be $true
        }
        else {
            Write-Output 'SCHEMA_ENGINE_UNAVAILABLE|Test-Json is unavailable; typed and JSON-path binding assertions still ran.'
        }
    }

    # Scenario: A passed result carries a binding that differs from the expected binding identity.
    # Purpose: Prevent a result for another candidate or authority snapshot from satisfying the expected entry.
    It 'UnitT60_rejects_result_binding_mismatch' {
        $snapshots = New-EntrySnapshotPair -Name 'result-mismatch'
        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
        $result = Copy-EntryTestObject -Value (New-EntryTestResult -Binding $binding)
        $result.binding.candidateRevision = $result.binding.authorityRevision

        Import-StandardEntryContractForTest
        $failureMessage = $null
        try { Assert-StandardEntryPointResult -ExpectedBinding $binding -Result $result | Out-Null }
        catch { $failureMessage = $_.Exception.Message }
        $failureMessage | Should Match 'mismatch|does not match|differs'
    }

    # Scenario: A passed result differs from the expected identity in one binding field or one check claim.
    # Purpose: Compare every binding input and require an exact, executed, successful check set with no release claim.
    It 'UnitT65_rejects_each_binding_identity_and_invalid_result_claim' {
        $snapshots = New-EntrySnapshotPair -Name 'result-claims'
        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
        $validResult = New-EntryTestResult -Binding $binding
        $bindingPath = Join-Path $snapshots.root 'expected-binding.json'
        $validResultPath = Join-Path $snapshots.root 'valid-result.json'
        [IO.File]::WriteAllText($bindingPath, (ConvertTo-Json -InputObject $binding -Depth 16), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($validResultPath, (ConvertTo-Json -InputObject $validResult -Depth 16), (New-Object Text.UTF8Encoding($false)))
        Import-StandardEntryContractForTest

        (Assert-StandardEntryPointResult -ExpectedBinding $binding -Result $validResult) | Should Be $true
        (Assert-StandardEntryPointResult -ExpectedBinding $binding -ResultPath $validResultPath) | Should Be $true
        (Assert-StandardEntryPointResult -ExpectedBindingPath $bindingPath -ResultPath $validResultPath) | Should Be $true

        $bindingMutations = @(
            @{ name = 'entry id'; apply = { param($value) $value.entryId = 'other-entry' } },
            @{ name = 'event name'; apply = { param($value) $value.eventName = 'push' } },
            @{ name = 'candidate revision'; apply = { param($value) $value.candidateRevision = 'f' * 40 } },
            @{ name = 'authority revision'; apply = { param($value) $value.authorityRevision = 'e' * 40 } },
            @{ name = 'runtime'; apply = { param($value) $value.runtime.psVersion = '0.0.0' } },
            @{ name = 'config hash'; apply = { param($value) $value.configSha256 = 'a' * 64 } },
            @{ name = 'required checks'; apply = { param($value) $value.requiredChecks = @('different check') } },
            @{ name = 'result artifact'; apply = { param($value) $value.resultArtifact = 'other-result.json' } },
            @{ name = 'content mode'; apply = { param($value) $value.contentMode = 'development' } },
            @{ name = 'input manifest'; apply = { param($value) $value.inputFileManifest[0].sha256 = 'b' * 64 } }
        )
        foreach ($mutation in $bindingMutations) {
            $result = Copy-EntryTestObject -Value $validResult
            & $mutation.apply $result.binding
            $failure = Get-EntryCallFailure { Assert-StandardEntryPointResult -ExpectedBinding $binding -Result $result }
            if ([string]::IsNullOrWhiteSpace($failure)) { throw "RESULT_ACCEPTED_BINDING_MISMATCH|$($mutation.name)" }
        }

        $resultMutations = @(
            @{ name = 'failed status'; apply = { param($value) $value.status = 'failed' } },
            @{ name = 'not executed'; apply = { param($value) $value.executed = $false } },
            @{ name = 'release eligible'; apply = { param($value) $value.releaseEligible = $true } },
            @{ name = 'missing executed'; apply = { param($value) $value.PSObject.Properties.Remove('executed') } },
            @{ name = 'missing check'; apply = { param($value) $value.checks = @() } },
            @{ name = 'extra check'; apply = { param($value) $value.checks = @($value.checks) + @([pscustomobject]@{ name = 'extra'; status = 'passed'; executed = $true; exitCode = 0 }) } },
            @{ name = 'duplicate check'; apply = { param($value) $value.checks = @($value.checks) + @($value.checks[0]) } },
            @{ name = 'wrong check status'; apply = { param($value) $value.checks[0].status = 'failed' } },
            @{ name = 'check not executed'; apply = { param($value) $value.checks[0].executed = $false } },
            @{ name = 'nonzero check exit'; apply = { param($value) $value.checks[0].exitCode = 1 } }
        )
        foreach ($mutation in $resultMutations) {
            $result = Copy-EntryTestObject -Value $validResult
            & $mutation.apply $result
            $failure = Get-EntryCallFailure { Assert-StandardEntryPointResult -ExpectedBinding $binding -Result $result }
            if ([string]::IsNullOrWhiteSpace($failure)) { throw "RESULT_ACCEPTED_INVALID_CLAIM|$($mutation.name)" }
        }

        $validJson = ConvertTo-Json -InputObject $validResult -Depth 16
        $resultSchema = Join-Path $script:RepositoryRoot 'docs/standards/schemas/standard-entry-result-v1.schema.json'
        $releaseResult = Copy-EntryTestObject -Value $validResult
        $releaseResult.releaseEligible = $true
        $releaseResultPath = Join-Path $snapshots.root 'release-result.json'
        [IO.File]::WriteAllText($releaseResultPath, (ConvertTo-Json -InputObject $releaseResult -Depth 16), (New-Object Text.UTF8Encoding($false)))
        $objectPathReleaseFailure = Get-EntryCallFailure {
            Assert-StandardEntryPointResult -ExpectedBinding $binding -ResultPath $releaseResultPath
        }
        $objectPathReleaseFailure | Should Match 'release|eligible|must not|cannot'
        $pathFailure = Get-EntryCallFailure {
            Assert-StandardEntryPointResult -ExpectedBindingPath $bindingPath -ResultPath $releaseResultPath
        }
        $pathFailure | Should Match 'release|eligible|must not|cannot'

        $wrongBindingResult = Copy-EntryTestObject -Value $validResult
        $wrongBindingResult.binding.entryId = 'other-entry'
        $wrongBindingResultPath = Join-Path $snapshots.root 'wrong-binding-result.json'
        [IO.File]::WriteAllText($wrongBindingResultPath, (ConvertTo-Json -InputObject $wrongBindingResult -Depth 16), (New-Object Text.UTF8Encoding($false)))
        $objectPathBindingFailure = Get-EntryCallFailure {
            Assert-StandardEntryPointResult -ExpectedBinding $binding -ResultPath $wrongBindingResultPath
        }
        $objectPathBindingFailure | Should Match 'mismatch|does not match|differs'

        $testJson = Get-Command -Name Test-Json -ErrorAction SilentlyContinue
        if ($null -ne $testJson) {
            ($validJson | Test-Json -SchemaFile $resultSchema) | Should Be $true
            $releaseSchemaResult = ConvertTo-Json -InputObject $releaseResult -Depth 16 | Test-Json -SchemaFile $resultSchema -ErrorAction SilentlyContinue
            $releaseSchemaResult | Should Be $false
        }
        else {
            Write-Output 'SCHEMA_ENGINE_UNAVAILABLE|Test-Json is unavailable; typed and JSON-path result assertions still ran.'
        }
    }

    # Scenario: A CLI caller points to a required result artifact that is missing.
    # Purpose: Ensure absent or unreadable result evidence cannot produce a successful exit code.
    It 'UnitT70_blocks_missing_result_artifact' {
        $snapshots = New-EntrySnapshotPair -Name 'missing-result'
        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
        $bindingPath = Join-Path $snapshots.root 'expected-binding.json'
        $resultPath = Join-Path $snapshots.root 'missing-result.json'
        [IO.File]::WriteAllText($bindingPath, (ConvertTo-Json -InputObject $binding -Depth 12), (New-Object Text.UTF8Encoding($false)))

        Import-StandardEntryContractForTest
        $failureMessage = $null
        try { Assert-StandardEntryPointResult -ExpectedBindingPath $bindingPath -ResultPath $resultPath | Out-Null }
        catch { $failureMessage = $_.Exception.Message }
        $failureMessage | Should Match 'missing|not found|artifact'
    }

    # Scenario: The CLI receives real binding/result JSON files for a complete snapshot pair, then a result with a mismatched candidate.
    # Purpose: Verify the shipped command returns zero only for the exact passed result and nonzero for a binding mismatch.
    It 'UnitT75_cli_verifies_success_and_fails_mismatch' {
        $snapshots = New-EntrySnapshotPair -Name 'cli-result'
        $binding = New-EntryTestBinding -Snapshots $snapshots -CandidateRevision $snapshots.candidateRevision -AuthorityRevision $snapshots.authorityRevision
        $bindingPath = Join-Path $snapshots.root 'cli-binding.json'
        $resultPath = Join-Path $snapshots.root 'cli-result.json'
        $result = New-EntryTestResult -Binding $binding
        [IO.File]::WriteAllText($bindingPath, (ConvertTo-Json -InputObject $binding -Depth 16), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($resultPath, (ConvertTo-Json -InputObject $result -Depth 16), (New-Object Text.UTF8Encoding($false)))

        $runtimeExecutable = Get-EntryTestRuntimeExecutable
        $runtimeArguments = @('-NoLogo', '-NoProfile')
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $runtimeArguments += @('-ExecutionPolicy', 'Bypass')
        }
        $runtimeArguments += @('-File', $script:CliPath, '-BindingPath', $bindingPath, '-ResultPath', $resultPath)
        $success = Invoke-EntryTestRuntimeProcess -Executable $runtimeExecutable -Arguments $runtimeArguments
        $success.exitCode | Should Be 0
        $success.truncated | Should Be $false
        $success.output | Should Match 'Verified entry=standard-v1-authority'
        $expectedRuntime = 'runtime={0}/{1}/{2}' -f $binding.runtime.os, $binding.runtime.psEdition, $binding.runtime.psVersion
        $success.output | Should Match ([Regex]::Escape($expectedRuntime))

        $result.binding.candidateRevision = 'f' * 40
        [IO.File]::WriteAllText($resultPath, (ConvertTo-Json -InputObject $result -Depth 16), (New-Object Text.UTF8Encoding($false)))
        $failure = Invoke-EntryTestRuntimeProcess -Executable $runtimeExecutable -Arguments $runtimeArguments
        $failure.exitCode | Should Not Be 0
        $failure.output | Should Match 'mismatch|does not match|differs'
    }
}
