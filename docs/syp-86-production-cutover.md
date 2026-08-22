# SYP-86 production cutover and rollback

## Final cutover invariant

The final cutover removes the legacy `.agents/skills/**` copies only when all gates pass on the same commit, and CI keeps the no-built-in-source invariant under regression test:

1. `catalog/skills-catalog-lock.json` is tracked and `scripts/update-skills-catalog-lock.ps1 -Check` succeeds.
2. The production Catalog exposes exactly the intended four sources and ten active stable Skill IDs.
3. Windows PowerShell 5.1 and PowerShell 7 both pass the complete Pester suite.
4. `SYP86 Production Smoke` installs a fresh disposable target through the installed launcher using the real commit-pinned Instructions archive and real external Skill archives, and produces a schema-v2 manifest with per-file provenance.
5. The same production smoke performs a second non-allowlist sync with `core.autocrlf=true`; managed bytes, Git status, HEAD and the retained `PersonalAgent` stash must remain unchanged.
6. Installer safety tests prove that dirty runtime source bytes are rejected before Codex Home mutation, runtime/config bundle identity is checked at launch, and a late installation failure restores the previous launcher, runtime, config and personal files.
7. Allowlist, excluded-repository, customized-file, wrong-hash, ZIP traversal/collision/link, and manifest-v1 migration scenarios all pass.

After these gates pass, retaining legacy copies would create a second source of truth. The final cutover therefore removes them. The composition stage continues to discard any `.agents/skills` content found in an Instructions archive and replaces it only with validated external selections. `Skill-Darktide-Translate` (SYP-88/SYP-92) remains an independent repository and is deliberately absent from this Catalog and Lock.

## Personal installation preflight

The installer now stages and validates the complete runtime bundle before replacing the active installation and rolls back normal installation failures. A manual backup is still useful before a production cutover:

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

Record the backup path. The installer rejects unknown schemas, mutable pins, another bundle repository, and tracked installer/runtime/Catalog/Lock files whose working-tree bytes differ from `HEAD` before changing the active installation. Schema v1/v2 routing arrays are migrated to v3. Existing schema-v3 `profiles`, `includeSkills` and `excludeSkills` are preserved while the bundle repository/ref advances together to the installer checkout.

The active runtime contains `runtime-bundle.json`. The installed launcher compares that repository/commit with `ai-instructions-sync.json` before running the multi-source bootstrap. A process interruption that leaves a mismatched runtime/config pair therefore fails closed until the installer is run again.

## Target migration behavior

- No manifest: normal first install writes manifest v2.
- Manifest v1 with every managed file unchanged and unstaged: one-time migration writes manifest v2.
- Manifest v1 with any customized, staged, deleted, or missing managed file: stop before target mutation. Preserve the file and manifest for manual resolution.
- Manifest v2 whose `catalogId` differs from the selected Catalog, or whose historical `lockSha256` is malformed: stop. A different valid historical lock is expected during an intentional pin update; per-file historical provenance remains the customization baseline.
- Removed stable IDs with `replacementId` and matching aliases are migrated by the selection resolver; removed IDs without a replacement remain fail-closed.

## Roll back the personal installer

For a normal installer exception, the installer restores its backed-up launcher, runtime, configuration, personal `AGENTS.md`, and `hooks.json` before returning the error.

For manual rollback or recovery after process termination, stop active Codex tasks and restore the backed-up hook, runtime, configuration, and personal `AGENTS.md` as one version-consistent set. Do not merge schema-v3 fields into a legacy configuration while rolling back. Restart Codex after restoration.

If no backup exists, clone the last known-good repository commit, ensure the installer/runtime/Catalog/Lock tracked files are clean at that commit, run its installer into a temporary Codex home, inspect the generated `runtime-bundle.json` and config pair, and copy them only after confirming the version pair is internally consistent.

## Roll back a target repository

For an allowlisted target, the bootstrap change is isolated in `chore: add shared AI instructions` or `chore: sync shared AI instructions`. Prefer a normal `git revert <commit>` after reviewing the commit; never reset unrelated work.

For a non-allowlisted target:

1. Record `git status` and `git stash list`.
2. Keep the latest and prior `PersonalAgent` stashes until recovery is verified.
3. Remove or restore only paths listed in the manifest, and only when their current hash still equals the manifest hash. Treat any mismatch as user customization.
4. Restore the backed-up manifest and configuration together.
5. Re-run `git status`, verify unrelated staged/unstaged work is unchanged, then run the known-good bootstrap.

Never drop another user stash. A failed byte verification intentionally leaves both old and new `PersonalAgent` stashes available for recovery.
