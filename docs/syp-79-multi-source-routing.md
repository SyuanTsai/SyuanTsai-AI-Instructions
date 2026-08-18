# SYP-79 Multi-Source Skills Routing

## Goal

Decouple Agent Skills acquisition from the AI-Instructions repository while keeping the existing instruction mutation semantics intact.

## Runtime flow

1. Load and validate the Skills Catalog.
2. Resolve selected Skill IDs to `sourceId/sourcePath` using Catalog + Lock.
3. Prune sources that are not used by the selected Skill set.
4. Validate every required source archive against its pinned SHA-256.
5. Stage every required source independently.
6. Validate every selected Skill root and `SKILL.md`.
7. Expand the AI-Instructions archive separately.
8. Compose a synthetic bootstrap source:
   - Instructions and Rules come from AI-Instructions.
   - `.agents/skills` from the instruction archive is discarded.
   - Only validated selected Skills are copied back into `.agents/skills/<stable-id>`.
9. Only after all preflight work succeeds, invoke the existing bootstrap mutation engine using the synthetic source archive.

This preserves existing customized/unmanaged-file protection, PersonalAgent stash behavior, manifest handling, and commit behavior without duplicating that mutation logic.

## Fail-closed boundary

No target repository mutation occurs until routing, archive validation, source staging, Skill-path validation, and desired-source composition have all completed successfully.

Failures include:

- unknown or duplicate source IDs;
- unknown selected Skill IDs;
- Catalog/Lock routing mismatch;
- unsafe source paths;
- missing source archive;
- source archive SHA-256 mismatch;
- malformed source archive root;
- missing selected Skill directory or `SKILL.md`;
- duplicate selected Skill IDs during composition.

## Current vertical-slice boundary

The new entry point is `scripts/bootstrap-ai-instructions-multisource.ps1`.

For this slice, callers provide:

- Catalog path;
- Lock path;
- selected Skill IDs;
- local source archive paths keyed by source ID;
- the AI-Instructions source archive.

Remote archive download/resolution, profile selection wiring, installer migration, and replacing the legacy entry point are intentionally deferred to later SYP-79 slices.
