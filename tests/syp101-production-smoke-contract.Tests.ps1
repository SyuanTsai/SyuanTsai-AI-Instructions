$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:SmokeContractModule = Join-Path $script:RepositoryRoot 'scripts\syp101-production-smoke-contract.psm1'

function Invoke-SmokeContractTestGit {
    param([Parameter(Mandatory = $true)][string] $Repository,[Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return $output
}

function New-SmokeContractTestRepository {
    param([Parameter(Mandatory = $true)][string] $Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-SmokeContractTestGit -Repository $Path -Arguments @('init','--quiet') | Out-Null
    Invoke-SmokeContractTestGit -Repository $Path -Arguments @('config','user.name','Smoke Contract Test') | Out-Null
    Invoke-SmokeContractTestGit -Repository $Path -Arguments @('config','user.email','smoke@example.test') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Path 'README.md'),"# Clean`n",(New-Object System.Text.UTF8Encoding($false)))
    Invoke-SmokeContractTestGit -Repository $Path -Arguments @('add','--','README.md') | Out-Null
    Invoke-SmokeContractTestGit -Repository $Path -Arguments @('commit','--quiet','-m','initial') | Out-Null
}

function Get-SmokeContractTestError {
    param([Parameter(Mandatory = $true)][scriptblock] $Action)
    try { & $Action; return $null }
    catch { return $_.Exception.Message }
}

Describe 'SYP101 production smoke repository contract' {
    BeforeAll { Import-Module $script:SmokeContractModule -Force }

    # Scenario: Existing operators and the task runbook still invoke the pre-SYP-101 smoke command path.
    # Purpose: Keep the documented validation entry point available while routing it to the stricter SYP-101 smoke.
    It 'UnitT05_preserves_the_legacy_production_smoke_entry_point' {
        $legacyEntryPoint = Join-Path $script:RepositoryRoot 'scripts\test-production-cutover.ps1'
        Test-Path -LiteralPath $legacyEntryPoint -PathType Leaf | Should Be $true
        (Get-Content -Raw -Encoding UTF8 -LiteralPath $legacyEntryPoint) | Should Match 'test-syp101-production-smoke\.ps1'
    }

    # Scenario: Production smoke reaches a repository with no staged, modified, or untracked paths.
    # Purpose: Establish the exact clean postcondition required after each bootstrap run.
    It 'UnitT10_accepts_a_clean_repository' {
        $targetRoot = Join-Path $TestDrive 'clean'
        New-SmokeContractTestRepository -Path $targetRoot

        { Assert-Syp101SmokeRepositoryClean -Repository $targetRoot -Phase 'test' } | Should Not Throw
    }

    # Scenario: Both runs could preserve the same pre-existing staged deletion and therefore look stable by comparison alone.
    # Purpose: Reject a stable-but-dirty index instead of treating unchanged status as a successful production smoke.
    It 'UnitT20_rejects_a_stable_but_dirty_index' {
        $targetRoot = Join-Path $TestDrive 'staged'
        New-SmokeContractTestRepository -Path $targetRoot
        Invoke-SmokeContractTestGit -Repository $targetRoot -Arguments @('rm','--quiet','--','README.md') | Out-Null

        (Get-SmokeContractTestError { Assert-Syp101SmokeRepositoryClean -Repository $targetRoot -Phase 'test' }) |
            Should Match 'not clean'
    }
}
