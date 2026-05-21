# Contributing

Thank you for contributing.

## Goals

- Keep `main` branch canonical and tool-neutral.
- Keep tool-specific branches focused on tool output formats.
- Prefer short, clear Markdown instructions.
- Avoid unnecessary duplication across branches.

## Branch model

- Author reusable source content on `main`.
- Adapt output for each tool on `tool/*` branches.
- Keep generated or ready-to-install files in `dist/` on tool branches.

## Content guidelines

- Use English for file names, folder names, headings, and primary docs.
- Traditional Chinese can be added only when useful as examples.
- Use repository placeholders (`{{PROJECT_NAME}}`, etc.) instead of hardcoded project names.

## Validation checklist before commit

- Shell scripts pass `bash -n`.
- PowerShell scripts pass parse check.
- Required files listed in `scripts/validate.*` exist.
- Install workflow still works with `--dry-run`.

## Adding a new tool

1. Add tool doc under `tools/<tool>.md` on `main`.
2. Add mapping entry in `docs/tool-mapping.md`.
3. Create `tool/<tool>` branch.
4. Produce installable output under `dist/` on that branch.
5. Verify `scripts/install-to-project.*` behavior.
