$script:SkillRoot = Join-Path $PSScriptRoot '..\.agents\skills\search-with-felo'
$script:ModulePath = Join-Path $script:SkillRoot 'scripts\SearchWithFelo.psm1'

function Get-TestPowerShellHost {
    $command = Get-Command pwsh, powershell.exe, powershell -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw 'No PowerShell executable is available for child-process tests.'
    }
    return $command.Source
}

Import-Module $script:ModulePath -Force

Describe 'search-with-felo compact wrapper' {
    # Scenario: A verified FELO 0.2.54 response contains extra identifiers, analysis, snippets, duplicate URLs, and more than five unique sources.
    # Purpose: Protect the compact allowlist contract and prevent raw FELO fields from entering the agent context.
    It 'T010_projects_a_success_response_to_the_compact_allowlist' {
        # Given
        $rawResponse = @'
Searching...
{
  "status": 200,
  "code": 0,
  "request_id": "request-private",
  "data": {
    "id": "answer-private",
    "message_id": "message-private",
    "answer": "A compact public answer.",
    "query_analysis": { "queries": ["expanded query"] },
    "resources": [
      { "title": "One", "link": "https://example.com/one", "snippet": "private snippet one" },
      { "title": "One duplicate", "link": "https://EXAMPLE.com/one#section", "snippet": "private duplicate" },
      { "title": "Two", "link": "https://example.com/two", "snippet": "private snippet two" },
      { "title": "Three", "link": "https://example.com/three", "snippet": "private snippet three" },
      { "title": "Four", "link": "https://example.com/four", "snippet": "private snippet four" },
      { "title": "Five", "link": "https://example.com/five", "snippet": "private snippet five" },
      { "title": "Six", "link": "https://example.com/six", "snippet": "private snippet six" }
    ]
  }
}
'@
        $asOf = [DateTimeOffset]::Parse('2026-08-10T12:00:00+08:00')

        # When
        $result = ConvertTo-FeloCompactResult -RawOutput $rawResponse -AsOf $asOf
        $json = $result | ConvertTo-Json -Depth 5 -Compress

        # Then
        ($result.PSObject.Properties.Name -join ',') | Should Be 'status,asOf,summary,sources,truncated'
        $result.status | Should Be 'ok'
        $result.asOf | Should Be '2026-08-10T12:00:00.0000000+08:00'
        $result.summary | Should Be 'A compact public answer.'
        @($result.sources).Count | Should Be 5
        $result.sources[0].title | Should Be 'One'
        $result.sources[0].url | Should Be 'https://example.com/one'
        $result.truncated | Should Be $true
        $json | Should Not Match 'request-private|answer-private|message-private|query_analysis|snippet|expanded query'
    }

    # Scenario: FELO returns a summary longer than the configured limit and the boundary contains a multi-code-point emoji.
    # Purpose: Preserve one user-visible ZWJ emoji at the boundary consistently across Windows PowerShell 5.1 and PowerShell 7.
    It 'T020_truncates_summary_by_Unicode_text_elements' {
        # Given
        $emoji = [char]::ConvertFromUtf32(0x1F469) + [char]0x200D + [char]::ConvertFromUtf32(0x1F4BB)
        $answer = ('a' * 799) + $emoji + 'tail'
        $expectedSummary = ('a' * 799) + $emoji
        $rawResponse = [ordered]@{
            status = 200
            data = [ordered]@{
                answer = $answer
                resources = @([ordered]@{ title = 'Source'; link = 'https://example.com/source' })
            }
        } | ConvertTo-Json -Depth 5

        # When
        $result = ConvertTo-FeloCompactResult -RawOutput $rawResponse -AsOf ([DateTimeOffset]::UtcNow)

        # Then
        $result.summary | Should Be $expectedSummary
        $result.summary.EndsWith($emoji) | Should Be $true
        $result.summary | Should Not Match 'tail'
        $result.truncated | Should Be $true
    }

    # Scenario: The CLI output does not contain a valid FELO JSON response.
    # Purpose: Return a safe classification without echoing raw output or diagnostics.
    It 'T030_returns_a_safe_error_for_invalid_output' {
        # Given
        $rawResponse = 'Searching failed with private diagnostic details.'

        # When
        $result = ConvertTo-FeloCompactResult -RawOutput $rawResponse -AsOf ([DateTimeOffset]::Parse('2026-08-10T12:00:00Z'))
        $json = $result | ConvertTo-Json -Compress

        # Then
        ($result.PSObject.Properties.Name -join ',') | Should Be 'status,asOf,error'
        $result.status | Should Be 'error'
        $result.error | Should Be 'invalid-response'
        $json | Should Not Match 'private diagnostic'
    }

    # Scenario: The CLI returns valid JSON but the FELO response schema no longer contains the expected status and data fields.
    # Purpose: Treat provider schema drift as a safe parse failure instead of throwing or exposing the changed response.
    It 'T035_returns_a_safe_error_when_the_response_schema_changes' {
        # Given
        $rawResponse = '{"unexpected":"private-schema-value"}'

        # When
        $result = ConvertTo-FeloCompactResult -RawOutput $rawResponse -AsOf ([DateTimeOffset]::Parse('2026-08-10T12:00:00Z'))
        $json = $result | ConvertTo-Json -Compress

        # Then
        $result.status | Should Be 'error'
        $result.error | Should Be 'invalid-response'
        $json | Should Not Match 'private-schema-value'
    }

    # Scenario: FELO returns an answer but no usable HTTP or HTTPS sources.
    # Purpose: Prevent an uncited FELO answer from being treated as a successful research result.
    It 'T040_returns_a_safe_error_when_no_sources_are_usable' {
        # Given
        $rawResponse = [ordered]@{
            status = 200
            data = [ordered]@{
                answer = 'Uncited answer'
                resources = @(
                    [ordered]@{ title = 'Missing URL'; link = '' },
                    [ordered]@{ title = 'Local file'; link = 'file:///private/report.txt' }
                )
            }
        } | ConvertTo-Json -Depth 5

        # When
        $result = ConvertTo-FeloCompactResult -RawOutput $rawResponse -AsOf ([DateTimeOffset]::UtcNow)

        # Then
        $result.status | Should Be 'error'
        $result.error | Should Be 'no-sources'
    }

    # Scenario: A child process writes normal data to stdout and diagnostics to stderr.
    # Purpose: Ensure raw CLI streams are captured separately and never pass through to the caller during execution.
    It 'T050_captures_child_process_stdout_and_stderr_separately' {
        # Given
        $fakeScript = Join-Path $TestDrive 'fake-felo.ps1'
        Set-Content -LiteralPath $fakeScript -Encoding UTF8 -Value @'
[Console]::Out.WriteLine('{"status":200}')
[Console]::Error.WriteLine('private stderr diagnostic')
exit 0
'@

        # When
        $result = Invoke-FeloChildProcess `
            -FilePath (Get-TestPowerShellHost) `
            -ArgumentList @('-NoProfile', '-File', $fakeScript) `
            -TimeoutSeconds 5

        # Then
        $result.ExitCode | Should Be 0
        $result.TimedOut | Should Be $false
        $result.StandardOutput.Trim() | Should Be '{"status":200}'
        $result.StandardError.Trim() | Should Be 'private stderr diagnostic'
    }

    # Scenario: A FELO-compatible child process writes UTF-8 text while the parent console uses a legacy Windows code page.
    # Purpose: Preserve multilingual stdout and stderr instead of decoding UTF-8 bytes with the parent console encoding.
    It 'UnitT55_decodes_child_process_stdout_and_stderr_as_UTF8' {
        # Given
        $fakeScript = Join-Path $TestDrive 'fake-felo-utf8.ps1'
        $expectedStdout = -join ([char[]]@(0x7E41, 0x9AD4, 0x4E2D, 0x6587, 0x6458, 0x8981))
        $expectedStderr = -join ([char[]]@(0x8A3A, 0x65B7, 0x8A0A, 0x606F))
        Set-Content -LiteralPath $fakeScript -Encoding UTF8 -Value @'
$stdoutText = -join ([char[]]@(0x7E41, 0x9AD4, 0x4E2D, 0x6587, 0x6458, 0x8981))
$stderrText = -join ([char[]]@(0x8A3A, 0x65B7, 0x8A0A, 0x606F))
$stdoutBytes = [System.Text.Encoding]::UTF8.GetBytes($stdoutText)
$stderrBytes = [System.Text.Encoding]::UTF8.GetBytes($stderrText)
[Console]::OpenStandardOutput().Write($stdoutBytes, 0, $stdoutBytes.Length)
[Console]::OpenStandardError().Write($stderrBytes, 0, $stderrBytes.Length)
'@
        $originalOutputEncoding = [Console]::OutputEncoding

        # When
        try {
            [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(950)
            $result = Invoke-FeloChildProcess `
                -FilePath (Get-TestPowerShellHost) `
                -ArgumentList @('-NoProfile', '-File', $fakeScript) `
                -TimeoutSeconds 5
        }
        finally {
            [Console]::OutputEncoding = $originalOutputEncoding
        }

        # Then
        $result.StandardOutput | Should Be $expectedStdout
        $result.StandardError | Should Be $expectedStderr
    }

    # Scenario: A public user query is prepared for the FELO CLI.
    # Purpose: Apply the agreed same-language and 800-character soft limit before the hard local projection.
    It 'T060_adds_the_compact_answer_instruction_to_the_query' {
        # Given
        $query = 'Compare current public transport options.'

        # When
        $result = New-FeloSearchQuery -Query $query -SummaryCharacterLimit 800

        # Then
        $result | Should Match ([regex]::Escape($query))
        $result | Should Match 'same language'
        $result | Should Match '800'
    }

    # Scenario: FELO succeeds on the first child-process invocation.
    # Purpose: Keep the normal path to one provider request while exposing compact retry metadata.
    It 'UnitT65_returns_retried_false_when_the_first_request_succeeds' {
        InModuleScope SearchWithFelo {
            # Given
            Mock Resolve-FeloCliInvocation {
                [pscustomobject]@{ FilePath = 'node'; PrefixArguments = @('felo.js') }
            }
            Mock Invoke-FeloChildProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    TimedOut = $false
                    StandardOutput = '{"status":200,"data":{"answer":"Answer","resources":[{"title":"Source","link":"https://example.com/source"}]}}'
                    StandardError = ''
                }
            }
            Mock Start-Sleep {}

            # When
            $result = Invoke-FeloSearch -Query 'Public query'

            # Then
            Assert-MockCalled Invoke-FeloChildProcess -Times 1 -Exactly -Scope It
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
            ($result.PSObject.Properties.Name -join ',') | Should Be 'status,asOf,summary,sources,truncated,retried'
            $result.status | Should Be 'ok'
            $result.retried | Should Be $false
        }
    }

    # Scenario: The first FELO child process returns an unclassified request failure and the second succeeds.
    # Purpose: Recover transient provider failures inside the wrapper without adding another Agent tool round trip.
    It 'UnitT70_retries_request_failed_once_and_returns_the_success' {
        InModuleScope SearchWithFelo {
            # Given
            $script:invocationCount = 0
            Mock Resolve-FeloCliInvocation {
                [pscustomobject]@{ FilePath = 'node'; PrefixArguments = @('felo.js') }
            }
            Mock Invoke-FeloChildProcess {
                $script:invocationCount++
                if ($script:invocationCount -eq 1) {
                    return [pscustomobject]@{
                        ExitCode = 1
                        TimedOut = $false
                        StandardOutput = ''
                        StandardError = 'Temporary provider failure.'
                    }
                }

                return [pscustomobject]@{
                    ExitCode = 0
                    TimedOut = $false
                    StandardOutput = '{"status":200,"data":{"answer":"Recovered","resources":[{"title":"Source","link":"https://example.com/source"}]}}'
                    StandardError = ''
                }
            }
            Mock Start-Sleep {}

            # When
            $result = Invoke-FeloSearch -Query 'Public query'

            # Then
            Assert-MockCalled Invoke-FeloChildProcess -Times 2 -Exactly -Scope It
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter {
                $Milliseconds -ge 1000 -and $Milliseconds -le 2000
            }
            $result.status | Should Be 'ok'
            $result.summary | Should Be 'Recovered'
            $result.retried | Should Be $true
        }
    }

    # Scenario: Both FELO child-process invocations return unclassified request failures.
    # Purpose: Bound provider usage to one retry and return one compact final failure to the Agent.
    It 'UnitT80_stops_after_one_request_failed_retry' {
        InModuleScope SearchWithFelo {
            # Given
            Mock Resolve-FeloCliInvocation {
                [pscustomobject]@{ FilePath = 'node'; PrefixArguments = @('felo.js') }
            }
            Mock Invoke-FeloChildProcess {
                [pscustomobject]@{
                    ExitCode = 1
                    TimedOut = $false
                    StandardOutput = ''
                    StandardError = 'Temporary provider failure.'
                }
            }
            Mock Start-Sleep {}

            # When
            $result = Invoke-FeloSearch -Query 'Public query'

            # Then
            Assert-MockCalled Invoke-FeloChildProcess -Times 2 -Exactly -Scope It
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
            ($result.PSObject.Properties.Name -join ',') | Should Be 'status,asOf,error,retried'
            $result.status | Should Be 'error'
            $result.error | Should Be 'request-failed'
            $result.retried | Should Be $true
        }
    }

    # Scenario: FELO rejects the request because authentication is invalid.
    # Purpose: Avoid spending another request and delay on a non-transient classified failure.
    It 'UnitT90_does_not_retry_a_classified_failure' {
        InModuleScope SearchWithFelo {
            # Given
            Mock Resolve-FeloCliInvocation {
                [pscustomobject]@{ FilePath = 'node'; PrefixArguments = @('felo.js') }
            }
            Mock Invoke-FeloChildProcess {
                [pscustomobject]@{
                    ExitCode = 1
                    TimedOut = $false
                    StandardOutput = ''
                    StandardError = 'Unauthorized (401).'
                }
            }
            Mock Start-Sleep {}

            # When
            $result = Invoke-FeloSearch -Query 'Public query'

            # Then
            Assert-MockCalled Invoke-FeloChildProcess -Times 1 -Exactly -Scope It
            Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
            $result.status | Should Be 'error'
            $result.error | Should Be 'authentication'
            $result.retried | Should Be $false
        }
    }
}
