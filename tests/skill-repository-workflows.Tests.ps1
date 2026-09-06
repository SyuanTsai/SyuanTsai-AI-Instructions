Describe 'Agent Skill authority workflow contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:CheckoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $script:SetupGoSha = 'b7ad1dad31e06c5925ef5d2fc7ad053ef454303e'
        $script:AuthorityGoVersion = '1.26.8'
        $script:WorkflowExpectations = [ordered]@{
            '.github/workflows/pr8-powershell-validation.yml' = 3
            '.github/workflows/standards-conformance.yml' = 1
            '.github/workflows/syp101-production-smoke.yml' = 2
            '.github/workflows/syp86-production-lock.yml' = 2
        }
        $script:AuthorityTests = @(
            'skill-repository-standard.Tests.ps1'
            'skill-repository-workflows.Tests.ps1'
            'standard-validation-resolver-hardening.Tests.ps1'
        )
        $script:AuthorityWorkflowDependencies = @(
            'pr8-powershell-validation.yml'
            'syp101-production-smoke.yml'
            'syp86-production-lock.yml'
        )

        function Assert-True {
            param([bool] $Condition, [string] $Message)
            if (-not $Condition) { throw $Message }
        }

        function Assert-Equal {
            param($Actual, $Expected, [string] $Message)
            if ($Actual -ne $Expected) { throw "$Message Expected='$Expected' Actual='$Actual'." }
        }

        function Assert-Match {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -notmatch $Pattern) { throw "$Message Pattern='$Pattern'." }
        }

        function Assert-NotMatch {
            param([string] $Actual, [string] $Pattern, [string] $Message)
            if ($Actual -match $Pattern) { throw "$Message Pattern='$Pattern'." }
        }
    }

    # Scenario: A workflow checkout is changed back to a mutable tag or leaves its token in Git config.
    # Purpose: Bind every production and authority checkout to the reviewed action commit without ambient credentials.
    It 'UnitT10_pins_every_checkout_and_disables_persisted_credentials' {
        foreach ($entry in $script:WorkflowExpectations.GetEnumerator()) {
            $path = Join-Path $script:RepositoryRoot ([string]$entry.Key)
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing workflow '$($entry.Key)'."
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            $checkoutPattern = "actions/checkout@$($script:CheckoutSha)\s+# v7"
            Assert-Equal ([regex]::Matches($workflow, $checkoutPattern)).Count ([int]$entry.Value) "Every checkout in '$($entry.Key)' must use the reviewed immutable v7 commit."
            Assert-Equal ([regex]::Matches($workflow, 'persist-credentials:\s*false')).Count ([int]$entry.Value) "Every checkout in '$($entry.Key)' must disable persisted credentials."
            Assert-NotMatch $workflow 'actions/checkout@v[0-9]+' "Workflow '$($entry.Key)' must not use a mutable checkout tag."
        }
    }

    # Scenario: An authority suite or the Ruleset-required bridge changes without running the complete shared gate.
    # Purpose: Keep both workflow evidence surfaces bound to one gate and all authority regressions.
    It 'UnitT20_runs_dedicated_authority_CI_for_every_authority_file_and_bridge_change' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts\Invoke-StandardAuthorityGate.ps1'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath

        foreach ($workflow in @($standards, $required)) {
            $setupPattern = "actions/setup-go@$($script:SetupGoSha)\s+# v7\.0\.0"
            Assert-Equal ([regex]::Matches($workflow, $setupPattern)).Count 1 'Each authority workflow must use the reviewed immutable setup-go v7.0.0 commit exactly once.'
            Assert-Match $workflow ("go-version:\s*'{0}'" -f [regex]::Escape($script:AuthorityGoVersion)) 'Each authority workflow must provision the exact approved Go runtime.'
            Assert-Match $workflow 'check-latest:\s*false' 'Authority Go setup must not drift to another patch release.'
            Assert-Match $workflow 'cache:\s*false' 'Authority Go setup must not restore a cross-run module or build cache.'
            Assert-NotMatch $workflow 'actions/setup-go@v[0-9]+' 'Authority workflows must not use a mutable setup-go tag.'
            Assert-True ($workflow.IndexOf('actions/setup-go@') -lt $workflow.IndexOf('& ./scripts/Invoke-StandardAuthorityGate.ps1')) 'The approved Go runtime must be provisioned before the authority gate starts.'
        }

        foreach ($workflowName in $script:AuthorityWorkflowDependencies) {
            $pattern = "'\.github/workflows/{0}'" -f [regex]::Escape($workflowName)
            Assert-Equal ([regex]::Matches($standards, $pattern)).Count 2 "Push and pull-request path filters must both include authority workflow '$workflowName'."
        }
        Assert-Equal ([regex]::Matches($standards, 'Invoke-StandardAuthorityGate\.ps1')).Count 3 'Dedicated CI must watch and invoke the shared authority gate.'
        Assert-Equal ([regex]::Matches($required, 'Invoke-StandardAuthorityGate\.ps1')).Count 1 'Required Composition CI must invoke the shared authority gate.'
        foreach ($testName in $script:AuthorityTests) {
            Assert-Equal ([regex]::Matches($standards, [regex]::Escape($testName))).Count 2 "Dedicated authority workflow must watch '$testName' for push and pull request events."
            Assert-Equal ([regex]::Matches($gate, [regex]::Escape($testName))).Count 1 "Shared authority gate must execute '$testName'."
        }
    }

    # Scenario: A main push or pull request is checked against a fixed branch range that can be empty or incomplete.
    # Purpose: Make whitespace validation cover the actual event range, including a repository's root commit.
    It 'UnitT30_checks_the_actual_event_commit_range_instead_of_an_empty_main_range' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        foreach ($path in @($standardsPath, $requiredPath)) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            Assert-Match $workflow 'PULL_REQUEST_BASE_SHA' "Workflow '$path' must bind the pull-request base SHA."
            Assert-Match $workflow 'PUSH_BEFORE_SHA' "Workflow '$path' must bind the pre-push SHA."
            Assert-Match $workflow 'GITHUB_EVENT_NAME' "Workflow '$path' must select the commit range by event type."
            Assert-Match $workflow 'git diff --check "\$PULL_REQUEST_BASE_SHA\.\.\.HEAD"' "Workflow '$path' must check the pull-request merge-base range."
            Assert-Match $workflow 'git diff --check "\$PUSH_BEFORE_SHA\.\.HEAD"' "Workflow '$path' must check the exact push range."
            Assert-Match $workflow 'git diff-tree --check --root -r HEAD' "Workflow '$path' must support a root-commit fallback."
            Assert-NotMatch $workflow 'git diff --check origin/main\.\.\.HEAD' "Workflow '$path' must not use a range that becomes empty on a main-branch push."
        }
    }

    # Scenario: The managed lifecycle contract changes without reaching the required authority workflow or its regression gate.
    # Purpose: Keep SYP-194 lifecycle semantics on the same central Standard CI path as every other authority change.
    It 'UnitT40_routes_managed_lifecycle_changes_through_the_central_authority_gate' {
        $standardsPath = Join-Path $script:RepositoryRoot 'docs/standards/managed-skill-lifecycle.md'
        $schemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json'
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'

        Assert-True (Test-Path -LiteralPath $standardsPath -PathType Leaf) 'Managed lifecycle authority document is missing.'
        Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Managed lifecycle evidence schema is missing.'
        $standardWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $requiredWorkflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath

        Assert-Match $standardWorkflow "'docs/standards/\*\*'" 'Dedicated authority workflow must watch the complete central standards directory.'
        foreach ($workflow in @($standardWorkflow, $requiredWorkflow)) {
            Assert-Match $workflow 'Invoke-StandardAuthorityGate\.ps1' 'Every authority workflow must execute the shared authority gate.'
        }
        Assert-Match $standardTests 'UnitT70_binds_managed_lifecycle_to_the_central_standard_authority' 'The workflow gate must execute lifecycle-specific authority regression.'
    }

    # Scenario: An upstream interoperability decision changes without reaching the required authority workflow or regression gate.
    # Purpose: Keep SYP-193 Plugin/Agent Skills boundary changes under the same central Standard CI semantics.
    It 'UnitT50_routes_upstream_interoperability_changes_through_the_central_authority_gate' {
        $upstreamPath = Join-Path $script:RepositoryRoot 'docs/standards/upstream-interoperability.md'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'

        Assert-True (Test-Path -LiteralPath $upstreamPath -PathType Leaf) 'Upstream interoperability authority document is missing.'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath
        Assert-Match $standards "'docs/standards/\*\*'" 'Dedicated authority workflow must watch the upstream interoperability record.'
        foreach ($workflow in @($standards, $required)) {
            Assert-Match $workflow 'Invoke-StandardAuthorityGate\.ps1' 'Every authority workflow must execute the shared gate for upstream changes.'
        }
        Assert-Match $standardTests 'UnitT80_binds_upstream_interoperability_to_explicit_central_decisions' 'The workflow gate must execute the upstream interoperability regression.'
    }

    # Scenario: The canonical validation/security policy changes without reaching both authority workflows and its executable gate.
    # Purpose: Keep SYP-192 stage order and fail-closed semantics under the same merge-blocking authority path.
    It 'UnitT60_routes_validation_security_gate_changes_through_the_central_authority_gate' {
        $policyPath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $schemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/validation-security-gate-v1.schema.json'
        $standardsPath = Join-Path $script:RepositoryRoot '.github/workflows/standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github/workflows/pr8-powershell-validation.yml'
        $gatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $standardTestsPath = Join-Path $script:RepositoryRoot 'tests/skill-repository-standard.Tests.ps1'

        Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) 'Canonical validation/security policy is missing.'
        Assert-True (Test-Path -LiteralPath $schemaPath -PathType Leaf) 'Canonical validation/security policy schema is missing.'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath

        Assert-Match $standards 'docs/standards/\*\*' 'Dedicated authority workflow must watch the central validation/security policy.'
        foreach ($workflow in @($standards, $required)) {
            Assert-Match $workflow 'Invoke-StandardAuthorityGate\.ps1' 'Authority workflows must execute the shared gate for validation/security changes.'
        }
        Assert-Match $gate 'validation-security-gate\.json' 'Shared authority gate must load the canonical validation/security policy.'
        Assert-Match $gate 'Assert-AuthorityValidationSecurityGate' 'Shared authority gate must enforce the canonical validation/security policy.'
        Assert-Match $standardTests 'UnitT90_binds_canonical_validation_security_order_and_fail_closed_severity' 'The workflow gate must execute SYP-192 validation/security regression.'
    }
}
