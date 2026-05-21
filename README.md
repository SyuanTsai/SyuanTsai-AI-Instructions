# Portable AI Instructions Repository

A reusable repository for managing AI coding instructions across different developer tools, IDEs, and CLIs.

## Why this repository exists

This repository is designed to be embedded inside software projects (for example as `.ai-instructions/`) and switched to tool-specific branches.

- `main` keeps canonical, tool-neutral instruction sources.
- `tool/*` branches provide tool-ready output in `dist/`.
- install scripts copy `dist/` files into the parent project.

## Repository structure (main branch)

```text
README.md
CONTRIBUTING.md
docs/
  branch-strategy.md
  install-workflow.md
  naming-conventions.md
  prompt-writing-guidelines.md
  tool-mapping.md
instructions/
  common/
    base-instructions.md
    coding-style.md
    code-review-checklist.md
    project-context-template.md
    architecture-template.md
  stacks/
    dotnet.md
    angular.md
    azure.md
    kubernetes.md
  templates/
    new-tool-template.md
    new-project-template.md
tools/
  github-copilot.md
  cursor.md
  claude-code.md
  chatgpt.md
  gemini-cli.md
  codex-cli.md
  vscode.md
  jetbrains.md
scripts/
  install-to-project.sh
  install-to-project.ps1
  validate.sh
  validate.ps1
```

## Branch strategy

- `main`
- `tool/github-copilot`
- `tool/cursor`
- `tool/claude-code`
- `tool/chatgpt`
- `tool/gemini-cli`
- `tool/codex-cli`
- `tool/vscode`
- `tool/jetbrains`

See [`docs/branch-strategy.md`](docs/branch-strategy.md).

## Quick start

### 1) Add as submodule

```bash
git submodule add <REPO_URL> .ai-instructions
```

### 2) Switch to a tool branch

```bash
cd .ai-instructions
git checkout tool/github-copilot
```

### 3) Install tool-ready files into parent project

```bash
./scripts/install-to-project.sh
```

PowerShell:

```powershell
./scripts/install-to-project.ps1
```

### 4) Update instructions

```bash
git pull
```

### 5) Switch tool and reinstall

```bash
git checkout tool/cursor
./scripts/install-to-project.sh
```

## Install script behavior

- Detects parent project directory (`../` from this repository root).
- Copies files from `dist/` to the parent project root.
- Creates missing directories.
- Prompts before overwrite unless `--force` / `-Force`.
- Supports dry-run with `--dry-run` / `-DryRun`.
- Prints summary: copied, skipped, overwritten.

## Example usage inside another project

```text
my-app/
  .ai-instructions/   <-- this repo
  src/
  MyApp.sln
```

After running install on `tool/github-copilot`, the parent project can receive files such as:

- `.github/copilot-instructions.md`
- `.vscode/settings.json`
- other tool-specific outputs from that branch `dist/`

## Placeholders used in templates

- `{{PROJECT_NAME}}`
- `{{TECH_STACK}}`
- `{{ARCHITECTURE}}`
- `{{CODING_STYLE}}`
- `{{DOMAIN_RULES}}`
- `{{CONSTRAINTS}}`

## Validation

Run:

```bash
./scripts/validate.sh
```

or:

```powershell
./scripts/validate.ps1
```
