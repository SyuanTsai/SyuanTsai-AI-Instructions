# SYP-86 production cutover and rollback

## Release gates

Do not remove the legacy `.agents/skills/**` copies until all gates pass on the same commit:

1. `catalog/skills-catalog-lock.json` is tracked and `scripts/update-skills-catalog-lock.ps1 -Check` succeeds.
2. The production Catalog exposes exactly the intended four sources and ten active stable Skill IDs.
3. Windows PowerShell 5.1 and PowerShell 7 both pass the complete Pester suite.
4. A fresh disposable target installs all selected production Skills from the real commit-pinned archives and produces a schema-v2 manifest with per-file provenance.
5. A second non-allowlist sync with `core.autocrlf=true` is a byte-for-byte no-op and preserves the existing `PersonalAgent` stash.
6. Allowlist, excluded-repository, customized-file, wrong-hash, ZIP traversal/collision/link, and manifest-v1 migration scenarios all pass.

Keeping the legacy copies after a successful cutover is safe: the composition stage removes Instructions-repository Skills and replaces them only with validated external selections. Deletion is a separate cleanup change, not part of the runtime switch.

## Personal installation preflight

Before running the installer:

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$backupRoot = Join-Path $codexHome ('backup-ai-instructions-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupRoot | Out-Null
foreach ($name in @('AGENTS.md', 'ai-instructions-sync.json', 'hooks.json')) {
    $path = Join-Path $codexHome $name
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination $backupRoot
    }
}
foreach ($name in @('bootstrap-ai-instructions.ps1', 'ai-instructions-runtime')) {
    $path = Join-Path (Join-Path $codexHome 'hooks') $name
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination $backupRoot -Recurse
    }
}
```

Record the backup path. The installer rejects unknown configuration schemas before replacing the hook or runtime. Schema v1/v2 routing arrays are migrated to v3; existing schema-v3 catalog selections are preserved.

## Target migration behavior

- No manifest: normal first install writes manifest v2.
- Manifest v1 with every managed file unchanged and unstaged: one-time migration writes manifest v2.
- Manifest v1 with any customized, staged, deleted, or missing managed file: stop before target mutation. Preserve the file and manifest for manual resolution.
- Manifest v2 whose `catalogId` differs from the selected Catalog, or whose historical `lockSha256` is malformed: stop. A different valid historical lock is expected during an intentional pin update; per-file historical provenance remains the customization baseline.

## Roll back the personal installer

Stop active Codex tasks, then restore the backed-up hook, runtime, configuration, and personal `AGENTS.md`. Do not merge schema-v3 fields into a legacy configuration while rolling back; restore the complete backed-up files as one consistent set. Restart Codex after restoration.

If no backup exists, clone the last known-good repository commit, run its installer into a temporary Codex home, inspect the generated files, and copy them only after confirming the version pair is internally consistent.

## Roll back a target repository

For an allowlisted target, the bootstrap change is isolated in `chore: add shared AI instructions` or `chore: sync shared AI instructions`. Prefer a normal `git revert <commit>` after reviewing the commit; never reset unrelated work.

For a non-allowlisted target:

1. Record `git status` and `git stash list`.
2. Keep the latest and prior `PersonalAgent` stashes until recovery is verified.
3. Remove or restore only paths listed in the manifest, and only when their current hash still equals the manifest hash. Treat any mismatch as user customization.
4. Restore the backed-up manifest and configuration together.
5. Re-run `git status`, verify unrelated staged/unstaged work is unchanged, then run the known-good bootstrap.

Never drop another user stash. A failed byte verification intentionally leaves both old and new `PersonalAgent` stashes available for recovery.
