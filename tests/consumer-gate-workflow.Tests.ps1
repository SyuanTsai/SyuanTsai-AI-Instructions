Describe 'Consumer gate workflow templates' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:FormalPath = Join-Path $script:RepositoryRoot 'consumer/workflows/consumer-gate.yml'
        $script:TransitionPath = Join-Path $script:RepositoryRoot 'consumer/workflows/consumer-gate-transition.yml'
        $script:Formal = Get-Content -Raw -Encoding UTF8 $script:FormalPath
        $script:Transition = Get-Content -Raw -Encoding UTF8 $script:TransitionPath
    }

    # Scenario: The formal template checks out explicit base and candidate refs for PR and push.
    # Purpose: Revision binding cannot be inferred from an ambient checkout.
    It 'UnitT10_declares_formal_event_refs_and_all_three_revision_inputs' {
        foreach ($required in @('pull_request_target:','push:','github.event.before','github.sha',"format('refs/pull/{0}/merge'",'GATE_BASE_REVISION','GATE_CANDIDATE_REVISION','GATE_HEAD_REVISION','-BaseRevision','-CandidateRevision','-HeadRevision')) { $script:Formal | Should Match ([regex]::Escape($required)) }
        $script:Formal | Should Match 'fetch-depth: 2'; $script:Formal | Should Match 'persist-credentials: false'
    }

    # Scenario: The conversion template checks out the legacy base and merge candidate explicitly.
    # Purpose: Its one-time candidate bootstrap remains bound to pull_request merge parents.
    It 'UnitT20_declares_transition_refs_and_candidate_bootstrap' {
        foreach ($required in @('github.event.pull_request.base.sha','github.sha','github.event.pull_request.head.sha','./candidate/scripts/Invoke-PinnedAuthority.ps1','-TransitionFromLegacy','-TriggerEvent pull_request','轉換已完成，請刪除此 workflow')) { $script:Transition | Should Match ([regex]::Escape($required)) }
    }

    # Scenario: Aggregate jobs repeat the same event-specific base, candidate, and head bindings as their platform legs.
    # Purpose: A clean aggregate runner cannot infer revisions from downloaded receipts or ambient checkout state.
    It 'UnitT25_repeats_explicit_revision_bindings_in_both_aggregate_jobs' {
        $formalAggregate=[regex]::Match($script:Formal,'(?s)\n  aggregate:\n(?<body>.*?)(?=\n  report:)').Groups['body'].Value
        foreach($required in @('github.event.before','github.sha',"format('refs/pull/{0}/merge'",'-BaseRevision $base','-CandidateRevision $candidate','-HeadRevision $head','-Phase aggregate','-Platform aggregate')){$formalAggregate|Should Match ([regex]::Escape($required))}
        $transitionAggregate=[regex]::Match($script:Transition,'(?s)\n  aggregate:\n(?<body>.*?)(?=\n  repository-contract:)').Groups['body'].Value
        foreach($required in @('github.event.pull_request.base.sha','github.sha','github.event.pull_request.head.sha','-Phase aggregate','-Platform aggregate','-TransitionFromLegacy')){$transitionAggregate|Should Match ([regex]::Escape($required))}
    }

    # Scenario: Token acquisition is limited to prepare in both templates.
    # Purpose: Validate, finalize, aggregate, and candidate subprocesses receive no workflow credential.
    It 'UnitT30_exposes_the_workflow_token_only_to_prepare_steps' {
        ([regex]::Matches($script:Formal,'STANDARD_VALIDATION_GITHUB_API_TOKEN:')).Count | Should Be 1
        ([regex]::Matches($script:Transition,'STANDARD_VALIDATION_GITHUB_API_TOKEN:')).Count | Should Be 1
        $script:Formal | Should Match '(?s)name: Prepare consumer gate.*?STANDARD_VALIDATION_GITHUB_API_TOKEN:'
        $script:Transition | Should Match '(?s)name: Prepare transition.*?STANDARD_VALIDATION_GITHUB_API_TOKEN:'
    }

    # Scenario: The first main push after conversion has no base bootstrap.
    # Purpose: Only that exact push is skipped and all other missing-base cases fail.
    It 'UnitT40_contains_the_fixed_transition_push_skip' {
        foreach ($required in @('transition push, gate skipped','-not (Test-Path -LiteralPath $base)','Test-Path -LiteralPath $candidate -PathType Leaf','Protected base bootstrap is missing')) { $script:Formal | Should Match ([regex]::Escape($required)) }
    }

    # Scenario: Candidate execution and App reporting have separate jobs and secrets.
    # Purpose: Push has no report/environment and report never checks out or downloads candidate artifacts.
    It 'UnitT50_separates_app_reporting_from_candidate_execution' {
        $script:Formal | Should Match "if: always\(\) && github\.event_name == 'pull_request_target'"
        $report = [regex]::Match($script:Formal,'(?s)\n  report:\n(.*)$').Groups[1].Value
        $report | Should Match 'environment: consumer-gate'; $report | Should Match 'permissions: \{\}'
        $report | Should Not Match 'actions/checkout|download-artifact'
        foreach ($context in @('repository-contract','skill-validator','skill-tools')) { $report | Should Match $context }
        $script:Formal | Should Not Match 'strict_required_status_checks_policy'
    }

    # Scenario: Transition checks mirror the canonical matrix without App or environment access.
    # Purpose: The one-time workflow exposes exactly the three legacy required job names.
    It 'UnitT60_uses_three_transition_mirror_jobs_without_remote_secrets' {
        foreach ($job in @('repository-contract','skill-validator','skill-tools')) { $script:Transition | Should Match "(?m)^  $([regex]::Escape($job)):\s*$" }
        $script:Transition | Should Not Match 'environment:|create-github-app-token|CONSUMER_GATE_APP_PRIVATE_KEY'
        $script:Transition | Should Match 'needs: \[gate, aggregate\]'
    }

    # Scenario: Expressions are treated as YAML data and never interpolated into shell source.
    # Purpose: Event-controlled values reach scripts only through env variables.
    It 'UnitT70_has_no_github_expression_inside_run_blocks' {
        foreach ($text in @($script:Formal,$script:Transition)) {
            $blocks = [regex]::Matches($text,'(?ms)^[ \t]+run:[ \t]*\|[ \t]*\r?\n(?<body>(?:[ \t]{10,}[^\r\n]*(?:\r?\n|$))*)')
            foreach ($block in $blocks) { $block.Groups['body'].Value | Should Not Match '\$\{\{' }
        }
    }

    # Scenario: Every event-controlled value used by transition shell code is declared in the step environment.
    # Purpose: The YAML expression engine supplies data while PowerShell source reads only environment variables.
    It 'UnitT75_passes_transition_expressions_through_step_environment' {
        foreach($name in @('REPOSITORY_URL','BASE_REVISION','CANDIDATE_REVISION','HEAD_REVISION','GATE_PLATFORM','GATE_RUN_ID','GATE_RUN_ATTEMPT')){$script:Transition|Should Match "(?m)^\s+${name}:\s+\$\{\{"}
        $script:Transition|Should Match '\$env:BASE_REVISION';$script:Transition|Should Match '\$env:CANDIDATE_REVISION';$script:Transition|Should Match '\$env:HEAD_REVISION'
    }

    # Scenario: All external actions are immutable and caches are absent.
    # Purpose: Template supply-chain behavior remains reviewable and non-persistent.
    It 'UnitT80_pins_actions_and_avoids_cache_or_persisted_credentials' {
        foreach ($text in @($script:Formal,$script:Transition)) {
            $text | Should Not Match 'actions/cache|persist-credentials:\s*true'
            foreach ($use in [regex]::Matches($text,'(?m)^\s*uses:\s*([^\s#]+)')) { $use.Groups[1].Value | Should Match '@[0-9a-f]{40}$' }
        }
    }
}
