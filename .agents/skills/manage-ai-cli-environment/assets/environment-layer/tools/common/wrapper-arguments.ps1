Set-StrictMode -Version Latest

function Split-AiWrapperArguments {
    [CmdletBinding()]
    param(
        [object[]] $Arguments = @()
    )

    $noRepair = $false
    $resourceArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $Arguments) {
        if ([string] $argument -ieq '-NoRepair') {
            $noRepair = $true
            continue
        }

        $resourceArguments.Add([string] $argument)
    }

    return [pscustomobject]@{
        noRepair = $noRepair
        resourceArguments = [string[]] $resourceArguments
    }
}
