# Branch Strategy

## Purpose

This repository separates **canonical instruction sources** from **tool-specific output branches**.

## Branches

- `main`: canonical, reusable, tool-neutral instruction source.
- `tool/github-copilot`: output layout and files for GitHub Copilot.
- `tool/cursor`: output layout and files for Cursor.
- `tool/claude-code`: output layout and files for Claude Code.
- `tool/chatgpt`: output for ChatGPT custom instructions.
- `tool/gemini-cli`: output for Gemini CLI usage.
- `tool/codex-cli`: output for Codex CLI usage.
- `tool/vscode`: output for VS Code instruction-related setup.
- `tool/jetbrains`: output for JetBrains instruction-related setup.

## Rules

1. Keep reusable source in `main`.
2. Tool branches adapt source to target file format and location.
3. Tool branches expose installable files in `dist/`.
4. Avoid direct edits in tool branches that should belong to canonical source.
5. Use placeholders to stay project-agnostic.

## Typical flow

```bash
cd .ai-instructions
git checkout tool/github-copilot
./scripts/install-to-project.sh
```

Switch tool:

```bash
git checkout tool/cursor
./scripts/install-to-project.sh
```
