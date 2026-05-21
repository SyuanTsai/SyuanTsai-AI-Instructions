[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Resolve-Path (Join-Path $scriptDir '..')

$requiredFiles = @(
    'README.md',
    'CONTRIBUTING.md',
    'docs/branch-strategy.md',
    'docs/install-workflow.md',
    'docs/naming-conventions.md',
    'docs/prompt-writing-guidelines.md',
    'docs/tool-mapping.md',
    'instructions/common/base-instructions.md',
    'instructions/common/coding-style.md',
    'instructions/common/code-review-checklist.md',
    'instructions/common/project-context-template.md',
    'instructions/common/architecture-template.md',
    'instructions/stacks/dotnet.md',
    'instructions/stacks/angular.md',
    'instructions/stacks/azure.md',
    'instructions/stacks/kubernetes.md',
    'instructions/templates/new-tool-template.md',
    'instructions/templates/new-project-template.md',
    'tools/github-copilot.md',
    'tools/cursor.md',
    'tools/claude-code.md',
    'tools/chatgpt.md',
    'tools/gemini-cli.md',
    'tools/codex-cli.md',
    'tools/vscode.md',
    'tools/jetbrains.md',
    'scripts/install-to-project.sh',
    'scripts/install-to-project.ps1',
    'scripts/validate.sh',
    'scripts/validate.ps1'
)

foreach ($relPath in $requiredFiles) {
    $path = Join-Path $repoDir $relPath
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Missing required file: $path"
    }
}

$null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoDir 'scripts/install-to-project.ps1'), [ref]$null, [ref]$null)
$null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoDir 'scripts/validate.ps1'), [ref]$null, [ref]$null)

Write-Host 'Validation passed.'
