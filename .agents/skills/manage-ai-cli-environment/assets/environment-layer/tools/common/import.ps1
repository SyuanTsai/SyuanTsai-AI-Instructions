Set-StrictMode -Version Latest

$commonRoot = $PSScriptRoot
foreach ($file in @(
    'process.ps1',
    'resource-policy.ps1',
    'usage.ps1',
    'adapters.ps1',
    'bootstrap.ps1',
    'auth.ps1',
    'probe.ps1',
    'logging.ps1',
    'worker.ps1'
)) {
    . (Join-Path $commonRoot $file)
}

$toolsRoot = Split-Path -Parent $commonRoot
. (Join-Path $toolsRoot 'codex\usage.ps1')
