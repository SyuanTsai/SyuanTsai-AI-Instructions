# Install Workflow

## 1. Embed repository in project

```bash
git submodule add <REPO_URL> .ai-instructions
```

## 2. Choose target tool branch

```bash
cd .ai-instructions
git checkout tool/github-copilot
```

## 3. Install files to parent project

```bash
./scripts/install-to-project.sh
```

PowerShell:

```powershell
./scripts/install-to-project.ps1
```

## 4. Update repository

```bash
git pull
```

## 5. Switch tool

```bash
git checkout tool/cursor
./scripts/install-to-project.sh
```

## Script options

- `--dry-run` / `-DryRun`: preview without writing files.
- `--force` / `-Force`: overwrite existing files without prompt.
