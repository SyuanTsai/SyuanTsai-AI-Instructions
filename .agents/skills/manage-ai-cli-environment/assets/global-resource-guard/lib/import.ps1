Set-StrictMode -Version Latest

$globalLibraryRoot = $PSScriptRoot
foreach ($file in @(
    'paths.ps1',
    'config.ps1',
    'state.ps1',
    'guard.ps1',
    'provider-runtime.ps1',
    'execution.ps1',
    'collector.ps1'
)) {
    . (Join-Path $globalLibraryRoot $file)
}
