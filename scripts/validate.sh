#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

required_files=(
  "$REPO_DIR/README.md"
  "$REPO_DIR/CONTRIBUTING.md"
  "$REPO_DIR/docs/branch-strategy.md"
  "$REPO_DIR/docs/install-workflow.md"
  "$REPO_DIR/docs/naming-conventions.md"
  "$REPO_DIR/docs/prompt-writing-guidelines.md"
  "$REPO_DIR/docs/tool-mapping.md"
  "$REPO_DIR/instructions/common/base-instructions.md"
  "$REPO_DIR/instructions/common/coding-style.md"
  "$REPO_DIR/instructions/common/code-review-checklist.md"
  "$REPO_DIR/instructions/common/project-context-template.md"
  "$REPO_DIR/instructions/common/architecture-template.md"
  "$REPO_DIR/instructions/stacks/dotnet.md"
  "$REPO_DIR/instructions/stacks/angular.md"
  "$REPO_DIR/instructions/stacks/azure.md"
  "$REPO_DIR/instructions/stacks/kubernetes.md"
  "$REPO_DIR/instructions/templates/new-tool-template.md"
  "$REPO_DIR/instructions/templates/new-project-template.md"
  "$REPO_DIR/tools/github-copilot.md"
  "$REPO_DIR/tools/cursor.md"
  "$REPO_DIR/tools/claude-code.md"
  "$REPO_DIR/tools/chatgpt.md"
  "$REPO_DIR/tools/gemini-cli.md"
  "$REPO_DIR/tools/codex-cli.md"
  "$REPO_DIR/tools/vscode.md"
  "$REPO_DIR/tools/jetbrains.md"
  "$REPO_DIR/scripts/install-to-project.sh"
  "$REPO_DIR/scripts/install-to-project.ps1"
  "$REPO_DIR/scripts/validate.sh"
  "$REPO_DIR/scripts/validate.ps1"
)

for file in "${required_files[@]}"; do
  [[ -f "$file" ]] || { echo "Missing required file: $file" >&2; exit 1; }
done

bash -n "$REPO_DIR/scripts/install-to-project.sh"
bash -n "$REPO_DIR/scripts/validate.sh"

echo "Validation passed."
