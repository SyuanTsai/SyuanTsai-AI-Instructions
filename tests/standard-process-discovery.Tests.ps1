Describe 'Windows owned descendant discovery' {
    BeforeAll {
        $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-StandardValidation.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -ne 0) { throw 'The process runner must parse before discovery tests.' }
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-StandardValidationDescendantProcessIds'
        }, $true)
        if ($null -eq $definition) { throw 'The descendant discovery function is required.' }
        Invoke-Expression $definition.Extent.Text
    }

    # Scenario: An owned short-lived Windows root has completed and its PID is absent.
    # Purpose: Avoid full process-table scans that cannot produce a birth-verified descendant edge.
    It 'InterT10_skips_snapshot_for_a_completed_root' {
        $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($arg in @('-NoProfile', '-NonInteractive', '-Command', 'exit 0')) { [void]$info.ArgumentList.Add($arg) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        try {
            if (-not $process.Start()) { throw 'The owned fixture did not start.' }
            $ownedPid = $process.Id
            if (-not $process.WaitForExit(5000)) { throw 'The owned fixture did not exit within its bound.' }
            Mock Get-CimInstance { throw 'A completed root must not enumerate the process table.' }
            @(Get-StandardValidationDescendantProcessIds -RootProcessId $ownedPid).Count | Should -Be 0
            Assert-MockCalled Get-CimInstance -Times 0 -Exactly -Scope It
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
    }

    # Scenario: A live root snapshot includes descendants, unrelated processes and missing birth data.
    # Purpose: Retain transitive discovery and fail closed on incomplete or older-child edges.
    It 'UnitT20_retains_live_root_birth_verified_graph' {
        $script:DiscoveryRoot = $PID
        $script:DiscoveryBirth = [DateTime]::UtcNow
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ ProcessId=$script:DiscoveryRoot; ParentProcessId=0; CreationDate=$script:DiscoveryBirth }
                [pscustomobject]@{ ProcessId=101; ParentProcessId=$script:DiscoveryRoot; CreationDate=$script:DiscoveryBirth.AddSeconds(1) }
                [pscustomobject]@{ ProcessId=102; ParentProcessId=101; CreationDate=$script:DiscoveryBirth.AddSeconds(2) }
                [pscustomobject]@{ ProcessId=103; ParentProcessId=$script:DiscoveryRoot; CreationDate=$script:DiscoveryBirth.AddSeconds(-1) }
                [pscustomobject]@{ ProcessId=104; ParentProcessId=$script:DiscoveryRoot; CreationDate=$null }
                [pscustomobject]@{ ProcessId=105; ParentProcessId=999; CreationDate=$script:DiscoveryBirth.AddSeconds(1) }
            )
        }
        $descendants = @(Get-StandardValidationDescendantProcessIds -RootProcessId $PID)
        ($descendants -join ',') | Should -Be '101,102'
        Assert-MockCalled Get-CimInstance -Times 1 -Exactly -Scope It
    }

    # Scenario: A live PID has been reused after an older process's children were born.
    # Purpose: Never attach old numeric parent references to the new root's ownership tree.
    It 'UnitT30_rejects_children_older_than_reused_parent_pid' {
        $script:DiscoveryRoot = $PID
        $script:DiscoveryBirth = [DateTime]::UtcNow
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ ProcessId=$script:DiscoveryRoot; ParentProcessId=0; CreationDate=$script:DiscoveryBirth }
                [pscustomobject]@{ ProcessId=201; ParentProcessId=$script:DiscoveryRoot; CreationDate=$script:DiscoveryBirth.AddSeconds(-10) }
                [pscustomobject]@{ ProcessId=202; ParentProcessId=201; CreationDate=$script:DiscoveryBirth.AddSeconds(-5) }
            )
        }
        @(Get-StandardValidationDescendantProcessIds -RootProcessId $PID).Count | Should -Be 0
        Assert-MockCalled Get-CimInstance -Times 1 -Exactly -Scope It
    }
}
