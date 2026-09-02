Describe 'Agent Skill authority workflow contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:CheckoutSha = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $script:WorkflowExpectations = [ordered]@{
            '.github\workflows\pr8-powershell-validation.yml' = 3
            '.github\workflows\standards-conformance.yml' = 1
            '.github\workflows\syp101-production-smoke.yml' = 2
            '.github\workflows\syp86-production-lock.yml' = 2
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

    It 'UnitT20_runs_dedicated_authority_CI_for_every_authority_file_and_bridge_change' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'
        $standards = Get-Content -Raw -Encoding UTF8 -LiteralPath $standardsPath
        $required = Get-Content -Raw -Encoding UTF8 -LiteralPath $requiredPath

        foreach ($workflowName in $script:AuthorityWorkflowDependencies) {
            $pattern = "'\.github/workflows/{0}'" -f [regex]::Escape($workflowName)
            Assert-Equal ([regex]::Matches($standards, $pattern)).Count 2 "Push and pull-request path filters must both include authority workflow '$workflowName'."
        }
        foreach ($testName in $script:AuthorityTests) {
            Assert-Equal ([regex]::Matches($standards, [regex]::Escape($testName))).Count 3 "Dedicated authority workflow must watch and execute '$testName'."
            Assert-Equal ([regex]::Matches($required, [regex]::Escape($testName))).Count 1 "Required Composition gate must execute '$testName'."
        }
    }

    It 'UnitT30_checks_the_actual_event_commit_range_instead_of_an_empty_main_range' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'
        foreach ($path in @($standardsPath, $requiredPath)) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            Assert-Match $workflow 'PULL_REQUEST_BASE_SHA' "Workflow '$path' must bind the pull-request base SHA."
            Assert-Match $workflow 'PUSH_BEFORE_SHA' "Workflow '$path' must bind the pre-push SHA."
            Assert-Match $workflow 'GITHUB_EVENT_NAME' "Workflow '$path' must select the commit range by event type."
            Assert-Match $workflow 'git diff --check' "Workflow '$path' must run a whitespace check."
            Assert-NotMatch $workflow 'git diff --check origin/main\.\.\.HEAD' "Workflow '$path' must not use a range that becomes empty on a main-branch push."
        }
    }

    It 'UnitT40_enforces_verification_only_install_and_static_metadata_receipts' {
        $standardsPath = Join-Path $script:RepositoryRoot '.github\workflows\standards-conformance.yml'
        $requiredPath = Join-Path $script:RepositoryRoot '.github\workflows\pr8-powershell-validation.yml'
        foreach ($path in @($standardsPath, $requiredPath)) {
            $workflow = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
            Assert-Match $workflow 'installDisposition.*ephemeral-verification' "Workflow '$path' must enforce verification-only resolver installation."
            Assert-Match $workflow 'credentialIsolation.*github-token-cleared-before-python' "Workflow '$path' must enforce GitHub credential isolation before Python."
            Assert-Match $workflow 'installedMetadataVerification.*static-dist-info-metadata' "Workflow '$path' must enforce static installed metadata verification."
        }
    }
}
