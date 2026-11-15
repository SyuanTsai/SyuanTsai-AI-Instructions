Describe 'Consumer gate workflow templates' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:FormalPath = Join-Path $script:RepositoryRoot 'consumer/workflows/consumer-gate.yml'
        $script:TransitionPath = Join-Path $script:RepositoryRoot 'consumer/workflows/consumer-gate-transition.yml'
        $script:Formal = Get-Content -Raw -Encoding UTF8 $script:FormalPath
        $script:Transition = Get-Content -Raw -Encoding UTF8 $script:TransitionPath
        function ConvertFrom-ConsumerWorkflowYaml([string]$Text) {
            $lines = @($Text -split "`r?`n")
            $document = [ordered]@{ permissions = $null
             jobs = [ordered]@{} }
            $jobsLine = [Array]::IndexOf($lines,'jobs:')
            if($jobsLine-lt0){throw 'Workflow has no jobs mapping.'}
            foreach($line in $lines[0..($jobsLine-1)]){if($line-match'^permissions:\s*(.*)$'){$document.permissions=$Matches[1]}}
            $jobStarts=@()
            for($i=$jobsLine+1;$i-lt$lines.Count;$i++){if($lines[$i]-match'^  ([A-Za-z0-9_-]+):\s*$'){$jobStarts+=@([pscustomobject]@{Name=$Matches[1]
            Index=$i})}}
            for($j=0;$j-lt$jobStarts.Count;$j++){
                $start=$jobStarts[$j].Index
                $end=if($j+1-lt$jobStarts.Count){$jobStarts[$j+1].Index-1}else{$lines.Count-1}
                $job=[ordered]@{properties=[ordered]@{}
                permissions=[ordered]@{}
                outputs=[ordered]@{}
                steps=@()}
                $section=$null
                $step=$null
                for($i=$start+1;$i-le$end;$i++){
                    $line=$lines[$i]
                    if($line-match'^    (permissions|outputs|steps):\s*(.*)$'){
                        $section=$Matches[1]
                        if($section-eq'permissions'-and$Matches[2]-eq'{}'){$job.permissions=[ordered]@{}}
                        continue
                    }
                    if($line-match'^    ([A-Za-z0-9_-]+):\s*(.*)$'){
                        $section=$null
                        $key=$Matches[1]
                        $value=$Matches[2]
                        if($value-match'^\[(.*)\]$'){$value=@($Matches[1]-split','|ForEach-Object{$_.Trim()})}
                        $job.properties[$key]=$value
                        continue
                    }
                    if($section-in@('permissions','outputs')-and$line-match'^      ([A-Za-z0-9_-]+):\s*(.*)$'){$job[$section][$Matches[1]]=$Matches[2]
                    continue}
                    if($section-eq'steps'-and$line-match'^      - name:\s*(.*)$'){
                        $step=[ordered]@{name=$Matches[1]
                        properties=[ordered]@{}
                        env=[ordered]@{}
                        with=[ordered]@{}
                        run=''}
                        $job.steps+=,$step
                        continue
                    }
                    if($null-ne$step-and$line-match'^        (env|with):\s*$'){$stepSection=$Matches[1]
                    continue}
                    if($null-ne$step-and$line-match'^        run:\s*\|\s*$'){
                        $body=[Collections.Generic.List[string]]::new()
                        $i++
                        while($i-le$end-and($lines[$i]-match'^          |^\s*$')){$body.Add(($lines[$i]-replace'^          ',''))
                        $i++}
                        $i--
                        $step.run=$body-join"`n"
                        continue
                    }
                    if($null-ne$step-and$line-match'^        ([A-Za-z0-9_-]+):\s*(.*)$'){$stepSection=$null
                    $step.properties[$Matches[1]]=$Matches[2]
                    continue}
                    if($null-ne$step-and$null-ne$stepSection-and$line-match'^          ([A-Za-z0-9_-]+):\s*(.*)$'){$step[$stepSection][$Matches[1]]=$Matches[2]
                    continue}
                }
                $document.jobs[$jobStarts[$j].Name]=[pscustomobject]$job
            }
            [pscustomobject]$document
        }
        function Get-ConsumerWorkflowStep($Job,[string]$Name){$match=@($Job.steps|Where-Object name -ceq $Name)
        if($match.Count-ne1){throw "Missing unique step: $Name"}
        $match[0]}
        function Assert-FormalWorkflowStructure([string]$Text){
            $workflow=ConvertFrom-ConsumerWorkflowYaml $Text
            if($workflow.permissions-cne'{}'){throw 'Top-level permissions must be empty.'}
            foreach($name in @('gate','aggregate','report')){if($null-eq$workflow.jobs[$name]){throw "Missing job: $name"}}
            if($workflow.jobs.gate.permissions.contents-cne'read'-or$workflow.jobs.aggregate.permissions.contents-cne'read'){throw `
                'Gate and aggregate require contents read.'}
            if ($workflow.jobs.report.permissions.Count -ne 0) { throw 'Report job must use only its scoped App token.' }
            if ($workflow.jobs.aggregate.outputs.authorityCommit -cne '${{ steps.aggregate.outputs.authorityCommit }}') {
                throw 'Aggregate authority output is invalid.'
            }
            if (
                ($workflow.jobs.report.properties.needs -join ',') -cne 'gate,aggregate' -or
                $workflow.jobs.report.properties.if -cne "always() && github.event_name == 'pull_request_target'"
            ) { throw 'Report dependencies are invalid.' }
            $prepare=Get-ConsumerWorkflowStep $workflow.jobs.gate 'Prepare consumer gate'
            $validate=Get-ConsumerWorkflowStep $workflow.jobs.gate 'Validate consumer gate'
            $finalize=Get-ConsumerWorkflowStep $workflow.jobs.gate 'Finalize consumer gate'
            if (
                $prepare.env.STANDARD_VALIDATION_GITHUB_API_TOKEN -cne '${{ github.token }}' -or
                $null -ne $validate.env.STANDARD_VALIDATION_GITHUB_API_TOKEN -or
                $null -ne $finalize.env.STANDARD_VALIDATION_GITHUB_API_TOKEN
            ) { throw 'Resolver token is not prepare-only.' }
            $token=Get-ConsumerWorkflowStep $workflow.jobs.report 'Create App token'
            if (
                $token.with.'permission-checks' -cne 'write' -or
                $token.with.owner -cne '${{ github.repository_owner }}' -or
                $token.with.repositories -cne '${{ github.event.repository.name }}'
            ) { throw 'App token scope is invalid.' }
            $publish=Get-ConsumerWorkflowStep $workflow.jobs.report 'Publish required checks'
            if (
                $publish.env.HEAD_SHA -cne '${{ github.event.pull_request.head.sha }}' -or
                $publish.env.AUTHORITY_COMMIT -cne '${{ needs.aggregate.outputs.authorityCommit }}'
            ) { throw 'Report binding is invalid.' }
            $expectedReportEnvironment = [ordered]@{
                GATE_RESULT='${{ needs.gate.result }}'
                AGGREGATE_RESULT='${{ needs.aggregate.result }}'
                RUN_ID='${{ github.run_id }}'
                BASE_SHA='${{ github.sha }}'
            }
            foreach ($name in $expectedReportEnvironment.Keys) {
                if ($publish.env[$name] -cne $expectedReportEnvironment[$name]) {
                    throw "Report environment binding is invalid: $name"
                }
            }
            $payloadBindings = @(
                'conclusion=failure', 'GATE_RESULT" == success && "$AGGREGATE_RESULT" == success',
                'head_sha="$HEAD_SHA"', 'external_id="$RUN_ID:$BASE_SHA"'
            )
            foreach ($required in $payloadBindings) {
                if (-not $publish.run.Contains($required,[StringComparison]::Ordinal)) {
                    throw "Report payload is invalid: $required"
                }
            }
            $workflow
        }
        $script:FormalYaml=Assert-FormalWorkflowStructure $script:Formal
        $script:TransitionYaml=ConvertFrom-ConsumerWorkflowYaml $script:Transition
    }

    # Scenario: The formal template checks out explicit base and candidate refs for PR and push.
    # Purpose: Revision binding cannot be inferred from an ambient checkout.
    It 'UnitT10_declares_formal_event_refs_and_all_three_revision_inputs' {
        $requiredBindings = @(
            'pull_request_target:', 'push:', 'github.event.before', 'github.sha',
            "format('refs/pull/{0}/merge'", 'GATE_BASE_REVISION', 'GATE_CANDIDATE_REVISION',
            'GATE_HEAD_REVISION', '-BaseRevision', '-CandidateRevision', '-HeadRevision'
        )
        foreach ($required in $requiredBindings) { $script:Formal | Should Match ([regex]::Escape($required)) }
        $script:Formal | Should Match 'fetch-depth: 2'
         $script:Formal | Should Match 'persist-credentials: false'
    }

    # Scenario: The conversion template checks out the legacy base and merge candidate explicitly.
    # Purpose: Its one-time candidate bootstrap remains bound to pull_request merge parents.
    It 'UnitT20_declares_transition_refs_and_candidate_bootstrap' {
        $requiredBindings = @(
            'github.event.pull_request.base.sha', 'github.sha', 'github.event.pull_request.head.sha',
            './candidate/scripts/Invoke-PinnedAuthority.ps1', '-TransitionFromLegacy',
            '-TriggerEvent pull_request', '轉換已完成，請刪除此 workflow'
        )
        foreach ($required in $requiredBindings) { $script:Transition | Should Match ([regex]::Escape($required)) }
    }

    # Scenario: Aggregate jobs repeat the same event-specific base, candidate, and head bindings as their platform legs.
    # Purpose: A clean aggregate runner cannot infer revisions from downloaded receipts or ambient checkout state.
    It 'UnitT25_repeats_explicit_revision_bindings_in_both_aggregate_jobs' {
        $formalAggregate=[regex]::Match($script:Formal,'(?s)\n  aggregate:\n(?<body>.*?)(?=\n  report:)').Groups['body'].Value
        $formalBindings = @(
            'github.event.before', 'github.sha', "format('refs/pull/{0}/merge'", '-BaseRevision $base',
            '-CandidateRevision $candidate', '-HeadRevision $head', '-Phase aggregate', '-Platform aggregate'
        )
        foreach ($required in $formalBindings) { $formalAggregate | Should Match ([regex]::Escape($required)) }
        $transitionAggregate=[regex]::Match($script:Transition,'(?s)\n  aggregate:\n(?<body>.*?)(?=\n  repository-contract:)').Groups['body'].Value
        $transitionBindings = @(
            'github.event.pull_request.base.sha', 'github.sha', 'github.event.pull_request.head.sha',
            '-Phase aggregate', '-Platform aggregate', '-TransitionFromLegacy'
        )
        foreach ($required in $transitionBindings) {
            $transitionAggregate | Should Match ([regex]::Escape($required))
        }
    }

    # Scenario: Token acquisition is limited to prepare in both templates.
    # Purpose: Validate, finalize, aggregate, and candidate subprocesses receive no workflow credential.
    It 'UnitT30_exposes_the_workflow_token_only_to_prepare_steps' {
        $formalPrepare=Get-ConsumerWorkflowStep $script:FormalYaml.jobs.gate 'Prepare consumer gate'
        $formalPrepare.env.STANDARD_VALIDATION_GITHUB_API_TOKEN | Should Be '${{ github.token }}'
        foreach ($step in @($script:FormalYaml.jobs.gate.steps | Where-Object name -ne 'Prepare consumer gate')) {
            $step.env.STANDARD_VALIDATION_GITHUB_API_TOKEN | Should BeNullOrEmpty
        }
        $transitionPrepare=Get-ConsumerWorkflowStep $script:TransitionYaml.jobs.gate 'Prepare transition'
        $transitionPrepare.env.STANDARD_VALIDATION_GITHUB_API_TOKEN | Should Be '${{ github.token }}'
    }

    # Scenario: The first main push after conversion has no base bootstrap.
    # Purpose: Only that exact push is skipped and all other missing-base cases fail.
    It 'UnitT40_contains_the_fixed_transition_push_skip' {
        $requiredBarriers = @(
            'transition push, gate skipped', '-not (Test-Path -LiteralPath $base)',
            'Test-Path -LiteralPath $candidate -PathType Leaf', 'Protected base bootstrap is missing'
        )
        foreach ($required in $requiredBarriers) { $script:Formal | Should Match ([regex]::Escape($required)) }
    }

    # Scenario: Candidate execution and App reporting have separate jobs and secrets.
    # Purpose: Push has no report/environment and report never checks out or downloads candidate artifacts.
    It 'UnitT50_separates_app_reporting_from_candidate_execution' {
        $report=$script:FormalYaml.jobs.report
        $report.properties.environment | Should Be 'consumer-gate'
        @($report.steps|Where-Object{$_.properties.uses-match'actions/checkout|download-artifact'}).Count|Should Be 0
        $publish=Get-ConsumerWorkflowStep $report 'Publish required checks'
        foreach($context in @('repository-contract','skill-validator','skill-tools')){$publish.run|Should Match $context}
        $script:Formal | Should Not Match 'strict_required_status_checks_policy'
    }

    # Scenario: Security-sensitive workflow fields are mutated after parsing.
    # Purpose: Token movement, unconditional success, and wrong head SHA must fail structural validation.
    It 'UnitT55_rejects_security_sensitive_workflow_mutations' {
        $tokenMoved = $script:Formal.Replace(
            'name: Prepare consumer gate',
            'name: Validate consumer gate'
        ).Replace('name: Validate consumer gate','name: Prepare consumer gate')
        {Assert-FormalWorkflowStructure $tokenMoved}|Should Throw
        $alwaysSuccess=$script:Formal.Replace('conclusion=failure','conclusion=success')
        {Assert-FormalWorkflowStructure $alwaysSuccess}|Should Throw
        $wrongHead=$script:Formal.Replace('HEAD_SHA: ${{ github.event.pull_request.head.sha }}','HEAD_SHA: ${{ github.sha }}')
        {Assert-FormalWorkflowStructure $wrongHead}|Should Throw
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
        $environmentNames = @(
            'REPOSITORY_URL', 'BASE_REVISION', 'CANDIDATE_REVISION', 'HEAD_REVISION',
            'GATE_PLATFORM', 'GATE_RUN_ID', 'GATE_RUN_ATTEMPT'
        )
        foreach ($name in $environmentNames) {
            $script:Transition | Should Match "(?m)^\s+${name}:\s+\$\{\{"
        }
        $script:Transition|Should Match '\$env:BASE_REVISION'
        $script:Transition|Should Match '\$env:CANDIDATE_REVISION'
        $script:Transition|Should Match '\$env:HEAD_REVISION'
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
