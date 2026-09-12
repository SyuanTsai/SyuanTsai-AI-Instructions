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
            Assert-Equal ([regex]::Matches($workflow, $setupPattern)).Count 1 'Each authority workflow must use the reviewed immutable setup-go v7.0.0 commit exactly once.'
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
            $errorMessage = $null
            try {
                Assert-AuthorityConsumerEntryPointContract `
                    -RepositoryRoot $root `
                    -CanonicalValidatorPath 'scripts/Validate.ps1' `
                    -Policy $policy | Out-Null
            }
            catch { $errorMessage = $_.Exception.Message }
            Assert-Match $errorMessage 'entry-point contract|alternate|canonical' "Consumer entry-point case '$($case.Name)' must fail closed."
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
    needs: canonical-validation
    steps:
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
        Assert-True (Assert-AuthorityConsumerEntryPointContract `
                -RepositoryRoot $disjointCandidateRoot `
                -CanonicalValidatorPath 'scripts/Validate.ps1' `
                -Policy $policy) 'Disjoint branch candidates for the same event may each execute the canonical validator once.'

        $roles = @($policy.entryPointContract.authorityWorkflowRoles)
        Assert-Equal $roles.Count 4 'The authority repository must explicitly classify all four legitimate workflow roles.'
        foreach ($role in $roles) {
            Assert-False ([bool]$role.consumerAlternateGate) "Authority workflow '$($role.path)' must not be classified as a consumer alternate gate."
            Assert-True (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $role.path) -PathType Leaf) "Authority workflow role '$($role.path)' must remain present."
        }
        Assert-Match $authorityGate 'standards-conformance\.yml|pr8-powershell-validation\.yml|syp86-production-lock\.yml|syp101-production-smoke\.yml' 'The authority gate contract must retain the explicit four-workflow role surface.'
    }
}
