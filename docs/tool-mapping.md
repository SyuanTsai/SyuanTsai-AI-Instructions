# Tool Mapping

This document maps canonical source content (`instructions/`) to target outputs in each `tool/*` branch.

| Tool Branch | Typical dist output | Notes |
|---|---|---|
| `tool/github-copilot` | `dist/.github/copilot-instructions.md` | GitHub Copilot repo instructions |
| `tool/cursor` | `dist/.cursor/rules.md` | Cursor rules/instructions |
| `tool/claude-code` | `dist/.claude/CLAUDE.md` | Claude Code working instructions |
| `tool/chatgpt` | `dist/chatgpt/custom-instructions.md` | Copy/paste custom instructions |
| `tool/gemini-cli` | `dist/gemini-cli/instructions.md` | CLI-oriented instruction profile |
| `tool/codex-cli` | `dist/codex-cli/instructions.md` | Codex CLI prompt profile |
| `tool/vscode` | `dist/.vscode/ai-instructions.md` | VS Code workspace docs/settings support |
| `tool/jetbrains` | `dist/.idea/ai-instructions.md` | JetBrains project docs/settings support |

## Canonical sources used

- `instructions/common/*`
- `instructions/stacks/*`
- `instructions/templates/*`
- `tools/<tool>.md`

## Tool-specific examples

Example files are provided under `docs/tool-examples/` to demonstrate branch outputs.
