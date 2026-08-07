#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common\wrapper-arguments.ps1')
$parsedArguments = Split-AiWrapperArguments -Arguments $args

$repositoryRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'ai-resource.ps1') -ResourceName codexSpark -RepositoryRoot $repositoryRoot -NoRepair:$parsedArguments.noRepair -ResourceArguments $parsedArguments.resourceArguments
exit $LASTEXITCODE
