Set-StrictMode -Version 2.0

function Invoke-Syp101SmokeContractGit {
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [switch] $AllowNonZero
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if (-not $AllowNonZero -and $exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ ExitCode=$exitCode; Output=@($output) }
}

function Assert-Syp101SmokeRepositoryClean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Repository,
        [Parameter(Mandatory = $true)][string] $Phase
    )

    $repositoryPath = [System.IO.Path]::GetFullPath($Repository)
    $statusResult = Invoke-Syp101SmokeContractGit -Repository $repositoryPath -Arguments @('status','--porcelain=v1','--untracked-files=all')
    if (@($statusResult.Output).Count -ne 0) {
        throw "Production smoke repository is not clean after $Phase`: $(@($statusResult.Output) -join ', ')"
    }
    $indexResult = Invoke-Syp101SmokeContractGit -Repository $repositoryPath -Arguments @('diff','--cached','--quiet','--exit-code') -AllowNonZero
    if ($indexResult.ExitCode -eq 1) { throw "Production smoke Git index is not clean after $Phase." }
    if ($indexResult.ExitCode -gt 1) { throw "Production smoke could not inspect the Git index after $Phase." }
}

Export-ModuleMember -Function Assert-Syp101SmokeRepositoryClean
