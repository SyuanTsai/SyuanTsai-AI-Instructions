function Assert-SemanticEqual {
    param([Parameter(ValueFromPipeline = $true)][AllowNull()] $Actual, [AllowNull()] $Expected)
    process {
        if ($Actual -cne $Expected) { throw "Semantic test expected '$Expected', got '$Actual'." }
    }
}

function Assert-SemanticMatch {
    param([Parameter(ValueFromPipeline = $true)][AllowNull()] $Actual, [string] $Pattern)
    process {
        if ([string]$Actual -notmatch $Pattern) { throw "Semantic test value did not match '$Pattern'." }
    }
}

function Assert-SemanticTrue {
    param([Parameter(ValueFromPipeline = $true)][AllowNull()] $Actual)
    process {
        if ($Actual -isnot [bool] -or -not $Actual) { throw 'Semantic test expected true.' }
    }
}

function Assert-SemanticFalse {
    param([Parameter(ValueFromPipeline = $true)][AllowNull()] $Actual)
    process {
        if ($Actual -isnot [bool] -or $Actual) { throw 'Semantic test expected false.' }
    }
}

function Assert-SemanticThrows {
    param([Parameter(ValueFromPipeline = $true)][scriptblock] $Action, [string] $Pattern = '*')
    process {
        $caught = $false
        try { & $Action | Out-Null }
        catch {
            $caught = $true
            if ([string]$_.Exception.Message -notlike $Pattern) {
                throw "Semantic test expected an error like '$Pattern', got '$($_.Exception.Message)'."
            }
        }
        if (-not $caught) { throw "Semantic test expected an error like '$Pattern'." }
    }
}
