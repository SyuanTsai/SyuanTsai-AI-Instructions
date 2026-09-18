Describe 'Agent Skill authority workflow contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidationSecurityGatePath = Join-Path $script:RepositoryRoot 'docs/standards/validation-security-gate.json'
        $script:AuthorityGatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $script:CheckoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $script:SetupGoSha = 'b7ad1dad31e06c5925ef5d2fc7ad053ef454303e'
        $script:AuthorityGoVersionRule = 'latest-stable'
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
            'standard-validation-runner.Tests.ps1'
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

        function Assert-False {
            param([bool] $Condition, [string] $Message)
            if ($Condition) { throw $Message }
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

        function Write-TestUtf8File {
            param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)

            $fullPath = [IO.Path]::GetFullPath($Path)
            $parent = [IO.Path]::GetDirectoryName($fullPath)
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            [IO.File]::WriteAllText($fullPath, $Text, (New-Object Text.UTF8Encoding($false)))
        }

        function New-ConsumerEntryPointFixture {
            param([Parameter(Mandatory = $true)][string] $Root)

            [void](New-Item -ItemType Directory -Path $Root -Force)
            Write-TestUtf8File -Path (Join-Path $Root 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
            Write-TestUtf8File -Path (Join-Path $Root '.github/workflows/validate.yml') -Text @'
name: Canonical validation
on:
  pull_request:
    branches:
      - main
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
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
            $expectedSetupCount = if ($workflow -ceq $standards) { 2 } else { 1 }
            Assert-Equal ([regex]::Matches($workflow, $setupPattern)).Count $expectedSetupCount 'Each authority workflow must use the reviewed immutable setup-go v7.0.0 commit for every native Go lane.'
            Assert-Match $workflow "go-version:\s*'stable'" 'Each authority workflow must provision the latest stable Go runtime.'
            Assert-Match $workflow 'check-latest:\s*true' 'Authority Go setup must check for the latest stable runtime.'
            Assert-NotMatch $workflow "go-version:\s*'[0-9]+\.[0-9]+\.[0-9]+'" 'Authority workflows must not pin a Go patch version.'
            Assert-Match $workflow 'cache:\s*false' 'Authority Go setup must not restore a cross-run module or build cache.'
            Assert-NotMatch $workflow 'actions/setup-go@v[0-9]+' 'Authority workflows must not use a mutable setup-go tag.'
            Assert-Match $workflow 'STANDARD_GO_RUNTIME_VERSION=\$\(\$Matches\.version\)' 'Authority workflows must capture the exact Go runtime resolved by setup-go.'
            Assert-Match $workflow '& ./scripts/Invoke-StandardAuthorityGate\.ps1 -ArtifactsRoot \$env:RUNNER_TEMP -ExpectedGoRuntimeVersion \$env:STANDARD_GO_RUNTIME_VERSION -GoCommandPath \$env:STANDARD_GO_COMMAND_PATH' 'Authority workflows must pass the setup-go resolved runtime into the shared gate.'
            Assert-True ($workflow.IndexOf('actions/setup-go@') -lt $workflow.IndexOf('STANDARD_GO_RUNTIME_VERSION=')) 'The approved Go runtime must be provisioned before its version is captured.'
            Assert-True ($workflow.IndexOf('STANDARD_GO_RUNTIME_VERSION=') -lt $workflow.IndexOf('& ./scripts/Invoke-StandardAuthorityGate.ps1')) 'The resolved Go runtime must be captured before the authority gate starts.'
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
        Assert-Match $gate 'ExpectedGoRuntimeVersion = \$env:STANDARD_GO_RUNTIME_VERSION' 'The shared authority gate must require the setup-go resolved runtime when invoked directly.'
        Assert-Match $gate '-ExpectedGoRuntimeVersion \$expectedGoRuntimeVersion' 'The shared authority gate must pass the resolved runtime into the resolver.'
        Assert-Match $gate '-GoCommandPath \$goCommandPath' 'The shared authority gate must pass the run-resolved Go executable path into the resolver.'
        Assert-Match $gate 'skill-validator receipt Go runtime.*does not match the setup-go run-resolved latest stable runtime' 'The shared authority gate must bind the resolver receipt to setup-go evidence.'
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
        $gatePath = Join-Path $script:RepositoryRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
        $adapterPolicyPath = Join-Path $script:RepositoryRoot 'docs/standards/upstream-adapter.json'
        $adapterSchemaPath = Join-Path $script:RepositoryRoot 'docs/standards/schemas/upstream-adapter-v1.schema.json'
        $adapterValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate-UpstreamAdapter.ps1'

        Assert-True (Test-Path -LiteralPath $upstreamPath -PathType Leaf) 'Upstream interoperability authority document is missing.'
        Assert-True (Test-Path -LiteralPath $adapterPolicyPath -PathType Leaf) 'Upstream adapter policy is missing.'
        Assert-True (Test-Path -LiteralPath $adapterSchemaPath -PathType Leaf) 'Upstream adapter schema is missing.'
        Assert-True (Test-Path -LiteralPath $adapterValidatorPath -PathType Leaf) 'Upstream adapter validator is missing.'
        $upstream = Get-Content -Raw -Encoding UTF8 -LiteralPath $upstreamPath
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath
        $standardTests = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardTestsPath
        $gate = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatePath
        Assert-Match $standards "'docs/standards/\*\*'" 'Dedicated authority workflow must watch the upstream interoperability record.'
        foreach ($workflow in @($standards, $required)) {
            Assert-Match $workflow 'Invoke-StandardAuthorityGate\.ps1' 'Every authority workflow must execute the shared gate for upstream changes.'
            Assert-Match $workflow 'scripts/Validate-UpstreamAdapter\.ps1' 'Every authority workflow must trigger when the upstream adapter validator changes.'
        }
        Assert-Match $standardTests 'UnitT80_binds_upstream_interoperability_to_explicit_central_decisions' 'The workflow gate must execute the upstream interoperability regression.'
        Assert-Match $standardTests 'UnitT81_routes_upstream_negative_cases_through_the_executable_adapter' 'The workflow gate must execute the executable adapter regression.'
        foreach ($caseId in @(
            'package-missing-skill-md',
            'plugin-path-out-of-root',
            'plugin-path-backslash',
            'plugin-path-rooted-windows',
            'plugin-path-dot',
            'plugin-path-colon',
            'plugin-duplicate-field',
            'mcp-unapproved-endpoint',
            'app-unknown-mcp-server',
            'marketplace-mutable-ref',
            'marketplace-duplicate-name',
            'marketplace-duplicate-nested-field',
            'marketplace-unknown-field',
            'marketplace-source-subpath',
            'marketplace-unapproved-repository',
            'marketplace-repository-case-variant',
            'marketplace-unapproved-endpoint',
            'plugin-hook-bypass'
        )) {
            Assert-Match $standardTests ([regex]::Escape($caseId)) "The upstream authority regression must retain negative case '$caseId'."
        }
        Assert-Match $upstream 'SYP-192 Gate 1' 'The upstream decision must bind Plugin conformance to Gate 1.'
        Assert-Match $gate 'Validate-UpstreamAdapter\.ps1' 'The authority gate must execute the upstream adapter validator.'
        Assert-Match $gate 'upstream-adapter\.json' 'The authority gate must load the upstream adapter policy.'
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
        Assert-Match $gate 'semanticPreflight' 'Shared authority gate must enforce the semantic preflight policy.'
        Assert-Match $gate 'llm-input-equals-strict-utf8-decoding-of-verified-source-bytes' 'Shared authority gate must enforce the semantic provider-input binding.'
        Assert-Match $gate 'full-byte-manifest-plus-authenticated-provider-text-subset-with-strict-utf8-v1-digest' 'Shared authority gate must enforce the separate provider-text inventory binding.'
        Assert-Match $gate 'standard-semantic-inventory-probe\.Tests\.ps1' 'Shared authority gate must execute semantic inventory behavior regressions.'
        Assert-Match $gate 'standard-semantic-preflight\.Tests\.ps1' 'Shared authority gate must execute semantic preflight behavior regressions.'
        Assert-Match $gate 'standard-semantic-raw-graph\.Tests\.ps1' 'Shared authority gate must execute raw-graph behavior regressions.'
        Assert-Match $gate 'STANDARD_AUTHORITY_PYTHON' 'Shared authority gate must supply the frozen SkillSpector Python to semantic behavior suites.'
        foreach ($isolatedPythonSuite in @('standard-semantic-inventory-probe.Tests.ps1','standard-semantic-raw-graph.Tests.ps1')) {
            $suiteText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot $isolatedPythonSuite)
            Assert-Match $suiteText '& \$script:Python -I -B' "Semantic suite '$isolatedPythonSuite' must use isolated Python startup."
        }
        Assert-Match $gate 'one-successful-provider-call-per-planned-work-item-with-matching-analyzer-path-and-interval' 'Shared authority gate must enforce per-work provider-call binding.'
        Assert-Match $gate 'reject-decoded-duplicate-properties-with-ordinal-ignore-case-semantics-before-deserialization' 'Shared authority gate must enforce scanner JSON property-collision handling.'
        Assert-Match $standardTests 'UnitT90_binds_canonical_validation_security_order_and_fail_closed_severity' 'The workflow gate must execute SYP-192 validation/security regression.'
    }

    # Scenario: A consumer adds a renamed workflow, hook, release command, or duplicate trigger adapter around a component script.
    # Purpose: Enforce the central entry-point inventory contract while allowing non-authoritative components and status-only compatibility jobs.
    It 'UnitT70_rejects_consumer_alternate_gates_but_preserves_authority_workflow_roles' {
        $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:ValidationSecurityGatePath | ConvertFrom-Json
        $authorityGate = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:AuthorityGatePath
        . $script:AuthorityGatePath -DefineFunctionsOnly

        Assert-True ($null -ne $policy.entryPointContract) 'Canonical validation/security policy must declare the entry-point contract.'
        Assert-Match $authorityGate 'Assert-AuthorityConsumerEntryPointContract' 'The shared authority gate must expose the consumer entry-point contract checker.'

        $canonicalFixture = Join-Path $TestDrive 'entry-point-valid'
        New-ConsumerEntryPointFixture -Root $canonicalFixture
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $canonicalFixture `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A single canonical workflow must satisfy the entry-point contract.'

        Write-TestUtf8File -Path (Join-Path $canonicalFixture 'scripts/check-domain.ps1') -Text "Invoke-Pester -Path tests/domain`n"
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $canonicalFixture `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A component script must not become an alternate gate merely because it exists.'

        $negativeCases = @(
            @{
                Name = 'arbitrary-workflow-name'
                RelativePath = '.github/workflows/domain-check.yaml'
                Text = "name: Domain check`non:`n  pull_request:`njobs:`n  domain:`n    steps:`n      - run: ./scripts/run-domain-tests.ps1`n"
            },
            @{
                Name = 'pre-push-hook-bypass'
                RelativePath = '.githooks/pre-push'
                Text = "#!/bin/sh`nInvoke-Pester -Path tests/domain`n"
            },
            @{
                Name = 'pre-commit-hook-bypass'
                RelativePath = '.githooks/pre-commit'
                Text = "#!/bin/sh`nInvoke-Pester -Path tests/domain`n"
            },
            @{
                Name = 'authority-role-name-bypass'
                RelativePath = '.github/workflows/standards-conformance.yml'
                Text = "name: Fake authority role`non:`n  pull_request:`njobs:`n  domain:`n    steps:`n      - run: ./scripts/run-domain-tests.ps1`n"
            },
            @{
                Name = 'public-release-command'
                RelativePath = 'README.md'
                Text = "Run ./scripts/run-domain-tests.ps1 as the release gate.`n"
            },
            @{
                Name = 'release-workflow-without-canonical'
                RelativePath = '.github/workflows/release.yml'
                Text = @'
name: Release
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-action-without-canonical'
                RelativePath = '.github/workflows/release-action.yml'
                Text = @'
name: Release action
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - uses: softprops/action-gh-release@v2
'@
            },
            @{
                Name = 'release-workflow-step-name-only-canonical'
                RelativePath = '.github/workflows/release-step-name.yml'
                Text = @'
name: Release step metadata
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - name: ./scripts/Validate.ps1
        run: gh release create v1.0.0
'@
            },
            @{
                Name = 'release-workflow-comment-only-canonical'
                RelativePath = '.github/workflows/release-comment.yml'
                Text = @'
name: Release comment metadata
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - run: |
          # ./scripts/Validate.ps1
          gh release create v1.0.0
'@
            },
            @{
                Name = 'release-workflow-suppresses-canonical-failure'
                RelativePath = '.github/workflows/release-suppressed.yml'
                Text = @'
name: Release with suppressed validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: ./scripts/Validate.ps1 || true
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-disables-canonical-step'
                RelativePath = '.github/workflows/release-disabled-canonical.yml'
                Text = @'
name: Release with disabled canonical validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - if: ${{ false }}
        run: ./scripts/Validate.ps1
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-conditional-release'
                RelativePath = '.github/workflows/release-conditional.yml'
                Text = @'
name: Conditional release without canonical validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - if: startsWith(github.ref, 'refs/tags/')
        run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-references-canonical-only'
                RelativePath = '.github/workflows/release-canonical-reference.yml'
                Text = @'
name: Release with canonical path reference only
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - run: Get-Item ./scripts/Validate.ps1
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-same-step-without-success-gate'
                RelativePath = '.github/workflows/release-same-step.yml'
                Text = @'
name: Release with ungated same-step validation
on:
  push:
    tags:
      - v*
jobs:
  release:
    steps:
      - shell: bash
        run: |
          ./scripts/Validate.ps1
          gh release create $GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-with-unbound-validation'
                RelativePath = '.github/workflows/release-unbound.yml'
                Text = @'
name: Release with unbound validation
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    steps:
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-unrelated-list-item'
                RelativePath = '.github/workflows/release-unrelated-list.yml'
                Text = @'
name: Release with unrelated list item
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    steps:
      - canonical-validation
      - run: gh release create $env:GITHUB_REF_NAME
'@
            },
            @{
                Name = 'release-workflow-opaque-local-helper'
                RelativePath = '.github/workflows/release-opaque-helper.yml'
                Text = @'
name: Release with opaque local helper
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    needs: canonical-validation
    steps:
      - run: ./ship
'@
                Files = @(
                    @{
                        RelativePath = 'ship'
                        Text = "gh release create `$env:GITHUB_REF_NAME`n"
                    }
                )
            },
            @{
                Name = 'release-workflow-opaque-action-delegate'
                RelativePath = '.github/workflows/release-opaque-action.yml'
                Text = @'
name: Release with opaque action delegate
on:
  workflow_dispatch:
jobs:
  release:
    steps:
      - uses: acme/ship@0123456789012345678901234567890123456789
'@
            },
            @{
                Name = 'compatibility-independent-validation'
                RelativePath = '.github/workflows/compatibility-independent.yml'
                Text = @'
name: Compatibility status
on:
  workflow_dispatch:
jobs:
  compatibility-status:
    needs: canonical-validation
    steps:
      - run: Invoke-Pester -Path tests/domain
'@
            }
        )
        foreach ($case in $negativeCases) {
            $root = Join-Path $TestDrive ("entry-point-negative-{0}" -f $case.Name)
            New-ConsumerEntryPointFixture -Root $root
            Write-TestUtf8File -Path (Join-Path $root $case.RelativePath) -Text $case.Text
            if ($case.ContainsKey('Files')) {
                foreach ($file in @($case.Files)) {
                    Write-TestUtf8File -Path (Join-Path $root $file.RelativePath) -Text $file.Text
                }
            }
            $errorMessage = $null
            try {
                Assert-AuthorityConsumerEntryPointContract `
                    -RepositoryRoot $root `
                    -CanonicalValidatorPath 'scripts/Validate.ps1' `
                    -Policy $policy | Out-Null
            }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'entry-point contract|alternate|canonical|opaque|release' "Consumer entry-point case '$($case.Name)' must fail closed."
        }

        $compatibilityRoot = Join-Path $TestDrive 'entry-point-compatibility-status'
        New-ConsumerEntryPointFixture -Root $compatibilityRoot
        Write-TestUtf8File -Path (Join-Path $compatibilityRoot '.github/workflows/compatibility-status.yml') -Text @'
name: Compatibility status
on:
  pull_request:
jobs:
  compatibility-status:
    needs: canonical-validation
    steps:
      - run: echo canonical-validation.result
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $compatibilityRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A compatibility status job may depend on and mirror the canonical result.'

        $releaseBoundRoot = Join-Path $TestDrive 'entry-point-release-bound'
        [void](New-Item -ItemType Directory -Path $releaseBoundRoot -Force)
        Write-TestUtf8File -Path (Join-Path $releaseBoundRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $releaseBoundRoot '.github/workflows/release-bound.yml') -Text @'
name: Release with bound validation
on:
  push:
    tags:
      - v*
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
  release:
    needs:
      - canonical-validation
    steps:
      - canonical-validation
      - run: gh release create $env:GITHUB_REF_NAME
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $releaseBoundRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'A release job must be allowed when it depends on the canonical validation job.'

        $duplicateRoot = Join-Path $TestDrive 'entry-point-duplicate-event'
        New-ConsumerEntryPointFixture -Root $duplicateRoot
        Write-TestUtf8File -Path (Join-Path $duplicateRoot '.github/workflows/duplicate-pr.yaml') -Text @'
name: Duplicate PR adapter
on:
  pull_request:
    branches:
      - main
jobs:
  duplicate:
    steps:
      - run: ./scripts/Validate.ps1
'@
        $duplicateError = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $duplicateRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $duplicateError = $_.Exception.Message }
        Assert-Match $duplicateError 'duplicate|event|candidate' 'Two canonical executions for the same event/candidate must fail closed.'

        $splitRoot = Join-Path $TestDrive 'entry-point-split-triggers'
        [void](New-Item -ItemType Directory -Path $splitRoot -Force)
        Write-TestUtf8File -Path (Join-Path $splitRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $splitRoot '.github/workflows/protected-pr.yml') -Text @'
name: Protected PR adapter
on:
  pull_request:
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Write-TestUtf8File -Path (Join-Path $splitRoot '.github/workflows/trusted-push.yml') -Text @'
name: Trusted push adapter
on:
  push:
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $splitRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'Protected PR and trusted push adapters may be separate when their events do not duplicate execution.'

        $disjointCandidateRoot = Join-Path $TestDrive 'entry-point-disjoint-candidates'
        [void](New-Item -ItemType Directory -Path (Join-Path $disjointCandidateRoot '.github/workflows') -Force)
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot 'scripts/Validate.ps1') -Text "Write-Output 'canonical validation'`n"
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot '.github/workflows/main-pr.yml') -Text @'
name: Main pull request adapter
on:
  pull_request:
    branches:
      - main
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        Write-TestUtf8File -Path (Join-Path $disjointCandidateRoot '.github/workflows/release-pr.yml') -Text @'
name: Release pull request adapter
on:
  pull_request:
    branches:
      - release
jobs:
  canonical-validation:
    steps:
      - run: ./scripts/Validate.ps1
'@
        $filterOverlapError = $null
        try {
            Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $disjointCandidateRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy | Out-Null
        }
        catch { $filterOverlapError = $_.Exception.Message }
        Assert-Match $filterOverlapError 'duplicate|event/candidate|overlap' 'Different path or branch filters must not be treated as proof of disjoint canonical execution.'

        $roles = @($policy.entryPointContract.authorityWorkflowRoles)
        Assert-Equal $roles.Count 4 'The authority repository must explicitly classify all four legitimate workflow roles.'
        foreach ($role in $roles) {
            Assert-False ([bool]$role.consumerAlternateGate) "Authority workflow '$($role.path)' must not be classified as a consumer alternate gate."
            Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $role.path) -PathType Leaf) "Authority workflow role '$($role.path)' must remain present."
        }
        Assert-Match $authorityGate 'standards-conformance\.yml|pr8-powershell-validation\.yml|syp86-production-lock\.yml|syp101-production-smoke\.yml' 'The authority gate contract must retain the explicit four-workflow role surface.'
    }

    # Scenario: SYP-154 needs native Linux evidence for the immutable PR33 tree before any trusted-base promotion.
    # Purpose: Keep the evidence-only job pinned, non-publishing, and separate from formal adoption authority.
    It 'UnitT80_binds_the_PR33_adoption_evidence_job_to_exact_independent_inputs' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath

        Assert-Match $workflow 'pr33-adoption-evidence-development-only:' 'The temporary PR33 adoption evidence job must remain explicit.'
        Assert-Match $workflow "if: github\.event_name == 'workflow_dispatch'" 'The evidence job must run only from an explicit workflow dispatch.'
        Assert-Match $workflow '(?s)pr33-adoption-evidence-development-only:.*?needs:\s*- latest-stable-authority-regression' 'The evidence job must wait for the exact central authority regression.'
        Assert-Match $workflow 'runs-on: ubuntu-24\.04' 'The evidence job must bind the native Ubuntu 24.04 family.'
        Assert-Match $workflow 'timeout-minutes: 45' 'The evidence job must retain one bounded outer deadline.'
        Assert-Match $workflow 'https://github\.com/SyuanTsai/Skill-Darktide-Translate\.git' 'The evidence job must acquire the exact Darktide repository.'
        foreach ($identity in @(
            '7519745266e0cd67b057e88c0ee63e702ccd1e10',
            '654934a3f1f412bc5ccda89bda0f9158cb4d328a',
            'efff60f7667d3e1fef159dfeec3565ad3087100e',
            '0d89a00cb7786fba932332cd287aa7db88fc22af',
            'c3bb5e49ee34e37418703ca2bf9a89c8bc5abfe8',
            '4332d9a1a366d6ff238cde3fe33912cca7dd2050'
        )) {
            Assert-Match $workflow ([regex]::Escape($identity)) "The evidence job must pin immutable identity '$identity'."
        }
        Assert-Match $workflow 'codex/SYP-158-trusted-file-contract' 'The evidence job must fetch the reviewed PR36 launcher branch before proving its pinned head.'
        Assert-Match $workflow '522852401e85ed82bbeef69128f6825381f0cc99' 'The evidence job must pin the reviewed PR36 validator blob.'
        foreach ($pinnedCommitVariable in @('SYP154_CANDIDATE_COMMIT', 'SYP154_LAUNCHER_COMMIT', 'SYP154_ORACLE_COMMIT')) {
            Assert-Match $workflow ('cat-file -e "\$' + $pinnedCommitVariable + '\^\{commit\}"') "The evidence job must prove that $pinnedCommitVariable exists as an exact commit object."
        }
        Assert-NotMatch $workflow 'rev-parse refs/remotes/evidence/(?:candidate|launcher|oracle).*?== "\$SYP154_' 'Moving branch heads must not be required to remain equal to immutable evidence pins.'
        Assert-Match $workflow 'git .*merge-base --is-ancestor.*SYP154_ORACLE_COMMIT.*SYP154_CANDIDATE_COMMIT' 'The evidence job must prove the oracle/base is an ancestor of the candidate.'
        Assert-Match $workflow 'GITHUB_SHA.*SYP154_ORACLE_COMMIT' 'The protected validator must receive the independent oracle commit as its event authority.'
        Assert-Match $workflow 'TRUSTED_SUPERVISOR_COMMIT.*SYP154_ORACLE_COMMIT' 'The validator must bind its declared test authority to the independent oracle commit.'
        Assert-Match $workflow 'scripts/Validate\.ps1' 'The evidence job must invoke the exact launcher validator.'
        Assert-Match $workflow 'releaseEligible.*false' 'The evidence manifest must remain non-release-eligible.'
        Assert-Match $workflow 'formalAdoption.*not-authorized' 'The evidence manifest must not claim formal adoption.'
        Assert-Match $workflow 'unshare --user --map-root-user --pid --fork --kill-child=SIGKILL' 'The native job must prove the required Linux namespace capability.'
        Assert-Match $workflow 'sysctl -n kernel\.apparmor_restrict_unprivileged_userns' 'The namespace probe must query the exact AppArmor key without a pipefail-sensitive producer pipeline.'
        Assert-NotMatch $workflow 'sysctl -a[^\r\n]*\|[^\r\n]*grep -q' 'The namespace probe must not combine sysctl -a with grep -q under pipefail.'
        Assert-Match $workflow 'cgroup\.subtree_control' 'The native job must establish the bounded cgroup v2 process boundary.'
        Assert-Match $workflow 'https://github\.com/actions/upload-artifact\.git' 'Evidence upload must acquire the official uploader without credentials.'
        foreach ($uploaderIdentity in @(
            '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
            '7cb4d1e81db55320b41217e1a78a1a46e3d2baef',
            'a36d775b02159bad1b24bf1ac3a314bc456a6fb5'
        )) {
            Assert-Match $workflow ([regex]::Escape($uploaderIdentity)) "Evidence upload must bind immutable uploader identity '$uploaderIdentity'."
        }
        Assert-NotMatch $workflow '(?s)pr33-adoption-evidence-development-only:.*?uses:\s*actions/upload-artifact@' 'The uploader must not start through a runner-inherited action environment.'
        Assert-NotMatch $workflow '(?s)pr33-adoption-evidence-development-only:.*?checks:\s*write' 'The evidence-only job must not publish required checks.'
        Assert-NotMatch $workflow '(?s)pr33-adoption-evidence-development-only:.*?pull-requests:\s*write' 'The evidence-only job must not mutate pull requests.'
    }

    # Scenario: Candidate code runs under the runner identity and must not be able to forge the uploaded identity metadata.
    # Purpose: Build every trusted metadata payload only after candidate descendants stop, replacing any candidate-created export path first.
    It 'UnitT85_finalizes_trusted_evidence_metadata_after_candidate_execution' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $acquisition = [regex]::Match(
            $workflow,
            '(?s)- name: Acquire and bind immutable launcher oracle and PR33 candidate.*?(?=\r?\n\s+- name: Delegate Linux cgroup v2 subtree)'
        ).Value
        $finalizer = [regex]::Match(
            $workflow,
            '(?s)- name: Finalize bounded evidence export.*?(?=\r?\n\s+- name: Upload bounded PR33 adoption evidence)'
        ).Value
        $validation = [regex]::Match(
            $workflow,
            '(?s)- name: Validate immutable PR33 candidate with independent oracle.*?(?=\r?\n\s+- name: Remove delegated Linux cgroup subtree)'
        ).Value
        Assert-True (-not [string]::IsNullOrEmpty($acquisition)) 'The acquisition section must be present.'
        Assert-True (-not [string]::IsNullOrEmpty($validation)) 'The validation section must be present.'
        Assert-True (-not [string]::IsNullOrEmpty($finalizer)) 'The finalizer section must be present.'
        Assert-NotMatch $acquisition 'candidate-diff\.txt|launcher-inventory\.tsv|oracle-inventory\.tsv|identity-manifest\.json' 'Trusted export metadata must not exist while candidate code can run.'
        Assert-Match $finalizer "runner_temp='\$\{\{ runner\.temp \}\}'" 'The finalizer must receive the runner temp path from a supervisor-owned workflow expression.'
        Assert-Match $finalizer 'export_root="\$runner_temp/syp154-pr33-evidence-export"' 'The finalizer must bind the exact run-owned export path.'
        Assert-Match $finalizer 'rm -rf -- "\$export_root"' 'The finalizer must replace any candidate-created export path after candidate shutdown.'
        Assert-Match $acquisition 'acquisitionComplete=1' 'The acquisition step must publish an explicit completion witness.'
        Assert-Match $finalizer 'acquisition_complete.*==\s*''1''' 'The finalizer must fail closed over completed acquisition inputs.'
        foreach ($trustedPayload in @(
            'candidate-diff\.txt',
            'launcher-inventory\.tsv',
            'oracle-inventory\.tsv',
            'identity-manifest\.json'
        )) {
            Assert-Match $finalizer $trustedPayload "The finalizer must recreate $trustedPayload from immutable inputs."
        }
        Assert-Match $finalizer 'export-sha256\.tsv' 'The finalizer must hash every exported payload after rebuilding trusted metadata.'
        $reportDigestIndex = $validation.IndexOf('$evidenceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath).Hash.ToLowerInvariant()')
        $validationRethrowIndex = $validation.IndexOf('if ($null -ne $validationError) { throw $validationError }')
        Assert-True ($reportDigestIndex -ge 0 -and $validationRethrowIndex -ge 0 -and $reportDigestIndex -lt $validationRethrowIndex) 'Any produced conformance report digest must be protected before a validation error is rethrown.'
        $portableSummaryChecksum = 'printf ''%s  %s\n'' "$expected_summary_sha256" ''security-preflight-summary.json'' > "$export_root/security-preflight-summary.sha256"'
        $absoluteSummaryChecksum = '/usr/bin/sha256sum "$export_root/security-preflight-summary.json" > "$export_root/security-preflight-summary.sha256"'
        Assert-Match $finalizer ([regex]::Escape($portableSummaryChecksum)) 'The exported security-summary checksum must name only its adjacent artifact basename.'
        Assert-NotMatch $finalizer ([regex]::Escape($absoluteSummaryChecksum)) 'The exported security-summary checksum must not capture an ephemeral runner-absolute path.'
        Assert-Match $finalizer "mapfile -d '' -t summaries" 'The finalizer must parse candidate-controlled security-summary paths with a NUL delimiter.'
        Assert-Match $finalizer '-name security-preflight-summary\.json -print0' 'The finalizer must serialize candidate-controlled security-summary paths with NUL delimiters.'
        Assert-NotMatch $finalizer '-name security-preflight-summary\.json -print(?:\s|\))' 'The finalizer must not split candidate-controlled security-summary paths on newlines.'
    }

    # Scenario: Candidate code can append startup variables and paths to the runner file-command files before later steps start.
    # Purpose: Start cleanup and finalization through sudo secure-exec with an empty environment, and keep their authority outside runner-owned paths.
    It 'UnitT90_isolates_cleanup_and_finalization_from_candidate_poisoned_step_state' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $acquisition = [regex]::Match(
            $workflow,
            '(?s)- name: Acquire and bind immutable launcher oracle and PR33 candidate.*?(?=\r?\n\s+- name: Delegate Linux cgroup v2 subtree)'
        ).Value
        $cleanup = [regex]::Match(
            $workflow,
            '(?s)- name: Remove delegated Linux cgroup subtree.*?(?=\r?\n\s+- name: Finalize bounded evidence export)'
        ).Value
        $finalizer = [regex]::Match(
            $workflow,
            '(?s)- name: Finalize bounded evidence export.*?(?=\r?\n\s+- name: Upload bounded PR33 adoption evidence)'
        ).Value
        $upload = [regex]::Match(
            $workflow,
            '(?s)- name: Upload bounded PR33 adoption evidence.*?(?=\r?\n\s{2}\S|\z)'
        ).Value

        foreach ($section in @($acquisition, $cleanup, $finalizer, $upload)) {
            Assert-True (-not [string]::IsNullOrEmpty($section)) 'Every post-candidate isolation section must be present.'
        }
        Assert-Match $acquisition '/var/lib/syp154-evidence-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}' 'The immutable witness and Git authority must live below a root-owned parent.'
        Assert-Match $acquisition 'sudo -n install -d -m 0755 -o root -g root' 'Acquisition must create the supervisor authority as root.'
        Assert-Match $acquisition 'candidate\.git' 'Acquisition must preserve trusted Git metadata outside the candidate-writable checkout.'
        Assert-Match $acquisition 'sudo -n /usr/bin/tee -- "\$cleanup_helper"' 'Acquisition must materialize cleanup before candidate execution.'
        Assert-Match $acquisition "stat -c '%u:%g:%a'.*?cleanup_helper.*?0:0:555" 'The cleanup helper must be root-owned and immutable before candidate execution.'
        Assert-Match $cleanup 'shell:.*?/usr/local/sbin/syp154-cleanup-cgroup \{0\}' 'Cleanup must execute only the fixed root-owned pre-candidate helper.'
        Assert-NotMatch $cleanup 'shell:[^\r\n]*\$\{\{' 'The custom shell must not use unsupported workflow expressions.'
        Assert-NotMatch $cleanup '/bin/bash[^\r\n]*\{0\}' 'Cleanup must not pass the runner-writable step script to root Bash.'
        Assert-Match $finalizer 'shell:\s*/usr/bin/sudo -n /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/bash --noprofile --norc -e -o pipefail \{0\}' 'Post-cleanup finalization must use sudo secure-exec and an empty environment.'
        Assert-Match $finalizer '--git-dir="\$supervisor_root/candidate\.git" --work-tree="\$candidate_root"' 'Finalization must use supervisor-owned Git metadata.'
        Assert-NotMatch $finalizer '\$\{SYP154_[A-Z_]+' 'Finalization must not inherit candidate-poisonable SYP154 environment state.'
        Assert-Match $upload 'shell:\s*/usr/bin/sudo -n /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/bash --noprofile --norc -e -o pipefail \{0\}' 'Uploader shell startup must use sudo secure-exec and an empty environment.'
        Assert-Match $upload '/usr/bin/env -i' 'The Node uploader must receive an explicit environment allowlist.'
        Assert-Match $upload '"\$node_runtime" "\$upload_entry"' 'The strict uploader must execute the root-owned Node runtime and pinned entrypoint.'
        Assert-NotMatch $upload '(?m)^\s+uses:' 'The strict uploader must not be dispatched by the runner with inherited job environment.'
    }

    # Scenario: Candidate code has the runner account's host filesystem permissions before the artifact action starts.
    # Purpose: Restore the pinned uploader from a root-owned pre-candidate snapshot and skip upload if trusted finalization fails.
    It 'UnitT95_restores_the_pinned_uploader_from_supervisor_owned_bytes' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $acquisition = [regex]::Match(
            $workflow,
            '(?s)- name: Acquire and bind immutable launcher oracle and PR33 candidate.*?(?=\r?\n\s+- name: Delegate Linux cgroup v2 subtree)'
        ).Value
        $finalizer = [regex]::Match(
            $workflow,
            '(?s)- name: Finalize bounded evidence export.*?(?=\r?\n\s+- name: Upload bounded PR33 adoption evidence)'
        ).Value
        $upload = [regex]::Match(
            $workflow,
            '(?s)- name: Upload bounded PR33 adoption evidence.*?(?=\r?\n\s{2}\S|\z)'
        ).Value

        Assert-Match $acquisition 'https://github\.com/actions/upload-artifact\.git' 'Acquisition must fetch the uploader from the official repository.'
        Assert-Match $acquisition 'fetch --no-tags --depth=1 origin "\$uploader_commit"' 'Acquisition must fetch only the exact uploader commit without a token.'
        Assert-Match $acquisition 'rev-parse "\$uploader_commit:action\.yml"' 'Acquisition must verify the pinned action definition blob.'
        Assert-Match $acquisition 'rev-parse "\$uploader_commit:dist/upload/index\.js"' 'Acquisition must verify the pinned upload entrypoint blob.'
        Assert-Match $acquisition 'git -C "\$uploader_source" archive "\$uploader_commit"' 'Acquisition must materialize only the verified uploader tree.'
        Assert-Match $acquisition '"\$supervisor_root/upload-artifact"' 'Acquisition must store the uploader below the root-owned supervisor authority.'
        Assert-NotMatch $finalizer 'upload_action_root' 'Finalization must not restore an uploader into the runner-managed action tree.'
        Assert-Match $upload "if:\s*\$\{\{ always\(\) && steps\.finalize_evidence\.outcome == 'success' \}\}" 'Upload must not execute if trusted restoration or finalization fails.'
        Assert-Match $upload "stat -c '%u:%g:%a'.*?upload_entry.*?0:0:444" 'The root uploader must validate immutable mode bits directly.'
        Assert-NotMatch $upload '\[\[\s*!\s+-w\s+"\$upload_entry"\s*\]\]' 'Root must not use access(2)-style writability as a mode-bit check.'
    }

    # Scenario: Candidate code can inject arbitrary Node/debug/output variables beyond any finite transport denylist.
    # Purpose: Start the pinned uploader with an explicit allowlist instead of inheriting the job or runner command-file environment.
    It 'UnitT100_runs_the_uploader_with_a_strict_environment_allowlist' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $finalizer = [regex]::Match(
            $workflow,
            '(?s)- name: Finalize bounded evidence export.*?(?=\r?\n\s+- name: Upload bounded PR33 adoption evidence)'
        ).Value
        $upload = [regex]::Match(
            $workflow,
            '(?s)- name: Upload bounded PR33 adoption evidence.*?(?=\r?\n\s{2}\S|\z)'
        ).Value

        Assert-True (-not [string]::IsNullOrEmpty($finalizer)) 'The finalizer section must be present.'
        Assert-True (-not [string]::IsNullOrEmpty($upload)) 'The upload section must be present.'
        Assert-NotMatch $finalizer 'github\.env|environment_file|>>\s*"\$environment_file"' 'Finalization must not append to any runner environment command file.'
        Assert-Match $upload '/usr/bin/env -i' 'Uploader process creation must begin from an empty environment.'
        foreach ($name in @('ACTIONS_RESULTS_URL', 'ACTIONS_RUNTIME_URL', 'ACTIONS_RUNTIME_TOKEN', 'INPUT_NAME', 'INPUT_PATH', 'RUNNER_TEMP', 'GITHUB_RUN_ID')) {
            Assert-Match $upload ([regex]::Escape($name) + '=') "The strict uploader allowlist must supply $name explicitly."
        }
        Assert-Match $upload 'RUNNER_TEMP="\$upload_tmp"' 'The strict uploader must bind temporary files to its root-owned private directory.'
        foreach ($name in @('NODE_DEBUG', 'NODE_REDIRECT_WARNINGS', 'NODE_OPTIONS', 'LD_PRELOAD', 'LD_AUDIT', 'LD_LIBRARY_PATH', 'BASH_ENV')) {
            Assert-NotMatch $upload ([regex]::Escape($name) + '=') "The strict uploader environment must not carry $name."
        }
    }

    # Scenario: Candidate code shares the runner identity and can otherwise migrate through a runner-writable parent cgroup.
    # Purpose: Keep every candidate descendant below a root-owned aggregate boundary, kill the whole subtree, and gate finalization on verified cleanup.
    It 'UnitT105_contains_candidate_processes_below_a_root_owned_cgroup_boundary' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $acquisition = [regex]::Match(
            $workflow,
            '(?s)- name: Acquire and bind immutable launcher oracle and PR33 candidate.*?(?=\r?\n\s+- name: Delegate Linux cgroup v2 subtree)'
        ).Value
        $delegation = [regex]::Match(
            $workflow,
            '(?s)- name: Delegate Linux cgroup v2 subtree.*?(?=\r?\n\s+- name: Prove unprivileged Linux namespace capability)'
        ).Value
        $cleanup = [regex]::Match(
            $workflow,
            '(?s)- name: Remove delegated Linux cgroup subtree.*?(?=\r?\n\s+- name: Finalize bounded evidence export)'
        ).Value
        $finalizer = [regex]::Match(
            $workflow,
            '(?s)- name: Finalize bounded evidence export.*?(?=\r?\n\s+- name: Upload bounded PR33 adoption evidence)'
        ).Value

        foreach ($section in @($acquisition, $delegation, $cleanup, $finalizer)) {
            Assert-True (-not [string]::IsNullOrEmpty($section)) 'Every cgroup containment section must be present.'
        }
        Assert-Match $delegation 'cgroup_delegated="\$cgroup_parent/delegated"' 'Only a nested cgroup subtree may be delegated to the runner identity.'
        Assert-Match $delegation 'cgroup_supervisor="\$cgroup_delegated/trusted-validator"' 'The trusted validator must remain inside the delegated subtree.'
        Assert-Match $delegation '(?s)printf ''%s\\n'' ''2147483648''.*?"\$cgroup_parent/memory\.max"' 'The root-owned outer boundary must enforce the aggregate 2 GiB memory ceiling.'
        Assert-Match $delegation '(?s)printf ''%s\\n'' ''256''.*?"\$cgroup_parent/pids\.max"' 'The root-owned outer boundary must enforce the aggregate PID ceiling when available.'
        Assert-NotMatch $delegation 'chown[^\r\n]*"\$cgroup_parent(?:/cgroup\.(?:procs|threads))?"' 'The outer boundary and its migration controls must remain root-owned.'
        Assert-Match $delegation 'CODEX_PESTER_CGROUP_ROOT=%s.*?\$cgroup_delegated' 'Protected tests must receive only the nested delegated root.'
        Assert-Match $cleanup '(?m)^\s+id:\s*cleanup_cgroup\s*$' 'Cleanup must expose an outcome that can gate trusted finalization.'
        Assert-Match $cleanup '/usr/local/sbin/syp154-cleanup-cgroup \{0\}' 'Cleanup must dispatch the fixed root-owned helper while treating the generated step script as an ignored argument.'
        Assert-NotMatch $cleanup 'shell:[^\r\n]*\$\{\{' 'Cleanup shell selection must remain parseable without workflow expressions.'
        Assert-NotMatch $cleanup 'cgroup\.kill|cgroup\.events|/usr/bin/find' 'The runner-writable cleanup step script must not contain privileged cleanup logic.'
        Assert-Match $acquisition 'cgroup\.kill' 'The root-owned cleanup helper must terminate the complete outer cgroup subtree.'
        Assert-Match $acquisition 'cgroup\.events' 'The root-owned cleanup helper must verify that the complete outer cgroup subtree is unpopulated.'
        Assert-Match $acquisition '/usr/bin/find "\$cgroup_parent" -mindepth 1 -depth -type d' 'The root-owned cleanup helper must remove every descendant cgroup from deepest to shallowest.'
        Assert-Match $acquisition "mapfile -d '' -t descendant_cgroups" 'The root-owned cleanup helper must parse descendant cgroup paths with a NUL delimiter.'
        Assert-Match $acquisition '-print0' 'The root-owned cleanup helper must serialize descendant cgroup paths with NUL delimiters.'
        Assert-NotMatch $acquisition '-type d -print(?:\s|\))' 'The root-owned cleanup helper must not serialize hostile descendant cgroup paths with newline delimiters.'
        Assert-Match $finalizer "if:\s*\$\{\{ always\(\) && steps\.cleanup_cgroup\.outcome == 'success' \}\}" 'Trusted finalization must not start unless candidate subtree cleanup succeeds.'
    }

    # Scenario: Candidate code can append artifact-service endpoints and tokens to the runner environment command file.
    # Purpose: Snapshot the runner-provided service authority before candidate execution and restore it only after verified cleanup.
    It 'UnitT110_restores_trusted_artifact_service_authority_before_upload' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $snapshotStep = [regex]::Match(
            $workflow,
            '(?s)- name: Snapshot trusted artifact-service authority.*?(?=\r?\n\s+- name: Delegate Linux cgroup v2 subtree)'
        ).Value
        $finalizer = [regex]::Match(
            $workflow,
            '(?s)- name: Finalize bounded evidence export.*?(?=\r?\n\s+- name: Upload bounded PR33 adoption evidence)'
        ).Value
        $upload = [regex]::Match(
            $workflow,
            '(?s)- name: Upload bounded PR33 adoption evidence.*?(?=\r?\n\s{2}\S|\z)'
        ).Value
        $actionDefinition = Get-Content -Raw -Encoding UTF8 -LiteralPath (
            Join-Path $script:RepositoryRoot '.github\actions\capture-artifact-service\action.yml'
        )
        $actionScript = Get-Content -Raw -Encoding UTF8 -LiteralPath (
            Join-Path $script:RepositoryRoot '.github\actions\capture-artifact-service\index.js'
        )

        Assert-True (-not [string]::IsNullOrEmpty($snapshotStep)) 'The artifact-service snapshot step must be present.'
        Assert-True (-not [string]::IsNullOrEmpty($finalizer)) 'The finalizer section must be present.'
        Assert-True (-not [string]::IsNullOrEmpty($upload)) 'The upload section must be present.'
        Assert-Match $snapshotStep 'uses:\s*\./\.github/actions/capture-artifact-service' 'The workflow must capture runner-injected service values through a Node action before candidate execution.'
        Assert-Match $actionDefinition 'using:\s*node24' 'The capture step must use the same reviewed Node generation as the pinned uploader.'
        Assert-Match $actionScript 'artifact-service\.env' 'The capture action must snapshot artifact-service authority outside runner-owned paths.'
        Assert-Match $actionScript 'process\.execPath' 'The capture action must identify the exact trusted Node runtime before candidate execution.'
        Assert-Match $actionScript 'node24' 'The capture action must copy the trusted Node runtime below the supervisor root.'
        Assert-Match $actionScript "'/usr/bin/install', '-m', '0555'" 'The captured Node runtime must be root-owned and immutable.'
        Assert-Match $actionScript "'/usr/bin/chmod', '0400'" 'The artifact-service snapshot must be readable only by root.'
        Assert-Match $actionScript "'/usr/bin/tee'" 'The capture action must write through root authority without logging the token.'
        Assert-Match $upload 'artifact-service\.env' 'The strict upload step must read the root-owned artifact-service authority snapshot.'
        Assert-Match $upload "stat -c '%u:%g:%a'.*?0:0:400" 'The strict upload step must verify root-only snapshot ownership and mode.'
        foreach ($name in @('ACTIONS_RESULTS_URL', 'ACTIONS_RUNTIME_URL', 'ACTIONS_RUNTIME_TOKEN')) {
            Assert-Match $actionScript ([regex]::Escape($name)) "The Node capture action must snapshot $name before candidate execution."
            Assert-Match $upload ([regex]::Escape($name)) "The strict upload step must restore $name from root-owned authority."
        }
        Assert-NotMatch $finalizer 'environment_file|>> "\$environment_file"' 'Trusted service values must not be appended to candidate-influenced command-file bytes.'
        Assert-Match $upload 'mapfile -t artifact_service_lines < "\$artifact_service_file"' 'The strict upload step must read the root-owned authority snapshot directly.'
    }

    # Scenario: The evidence job invokes a repository-local security action whose files can change independently.
    # Purpose: Materialize the exact PR head without registering a candidate-writable post action, and watch every action change.
    It 'UnitT115_materializes_and_watches_the_local_artifact_authority_action_without_a_post_hook' {
        $workflowPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $workflowPath
        $evidenceJob = [regex]::Match(
            $workflow,
            '(?s)pr33-adoption-evidence-development-only:.*\z'
        ).Value

        Assert-True (-not [string]::IsNullOrEmpty($evidenceJob)) 'The PR33 evidence job must be present.'
        Assert-NotMatch $evidenceJob 'actions/checkout@' 'The evidence job must not register a checkout post action that candidate code can replace.'
        Assert-Match $evidenceJob 'git -C "\$workspace" fetch --no-tags --depth=1 origin "\$GITHUB_SHA"' 'The evidence job must fetch only the exact 40-hex workflow commit.'
        Assert-Match $evidenceJob 'rev-parse FETCH_HEAD.*?== "\$GITHUB_SHA"' 'The evidence job must verify the fetched commit before materializing the local action.'
        Assert-Match $evidenceJob 'git -C "\$workspace" checkout --detach FETCH_HEAD' 'The evidence job must materialize the verified commit without an action post hook.'
        Assert-True ($evidenceJob.IndexOf('git -C "$workspace" checkout --detach FETCH_HEAD') -lt $evidenceJob.IndexOf('uses: ./.github/actions/capture-artifact-service')) 'Exact Git materialization must precede local action resolution.'
        Assert-Equal ([regex]::Matches($workflow, "'\.github/actions/capture-artifact-service/\*\*'").Count) 2 'Push and pull-request filters must both watch the security-critical local action.'
    }
}
