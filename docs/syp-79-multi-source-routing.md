# SYP-79 Multi-Source Routing

## Goal

Make Skills source acquisition data-driven from `catalog.sources[]` and Skill `source.sourceId/path`, without hard-coded domain routing.

## Implemented pre-repository path

The executable multi-source path is split into fail-closed stages:

1. **Selection** — schema v3 `profiles`, `includeSkills`, and `excludeSkills` resolve to stable Skill IDs. Empty profile selection falls back to Catalog default profiles; explicit personal exclude wins last.
2. **Routing** — selected Skill IDs resolve through Catalog + Lock to generic `sourceId/path` entries and only required sources are retained.
3. **Retrieval** — required GitHub sources are downloaded by immutable `resolvedCommit`; local archive overrides exist only for fixture/testing scenarios.
4. **Archive validation and staging** — each required archive must match its locked `archiveSha256` before extraction.
5. **Skill validation** — each selected Skill must remain inside its source root, contain `SKILL.md`, and match locked deterministic `contentSha256`.
6. **Composition** — AI-Instructions provides Instructions/Rules; any `.agents/skills` present in that instruction archive is removed and replaced only with validated selected external Skills.
7. **Mutation handoff** — only after all previous stages succeed is the existing bootstrap mutation engine invoked.

## Fail-closed boundary

A routing, pin, archive, path, Skill definition, content hash, or composition failure occurs before target mutation begins. No source is allowed to contribute a partial desired set.

Unused Catalog sources are not retrieved or validated during a sync when no selected Skill references them.

## Compatibility boundary

The multi-source wrapper consumes schema v3 selection, then derives a temporary schema v2 view containing only allowlist/exclusion settings for the legacy mutation engine. This preserves current customized/unmanaged protection, PersonalAgent stash behavior, and commit behavior while avoiding a high-risk rewrite of the existing mutation engine during SYP-79.

The legacy single-source entry point remains unchanged for regression compatibility during migration.

The composed handoff archive is created with the .NET ZIP API so `.codex`, `.github`, `.agents`, and other hidden or dot-prefixed managed content remain present on Windows, Linux, and macOS. Skill inventory hashing likewise includes hidden resources and uses ordinal case-sensitive path keys before the platform-specific mutation handoff.

## Domain independence

No runtime branch checks `general`, `code-collaboration`, `knowledge-content`, `atlassian-work-management`, or any future source ID. Source IDs are stable data keys only.

## Repository-ready state

The pre-repository work is now sufficient to provision the first real external Skill repository. The exact source layout, Catalog/Lock requirements, pin/hash steps, and migration order are documented in `docs/syp-79-new-skill-repository-readiness.md`.

The next explicit operation should be repository provisioning and physical Skill migration, not another bootstrap domain-specific change.

## Remaining later integration work

These are intentionally not blockers for creating the first Skill repository:

- installer-driven schema v2 → v3 personal config migration;
- making the multi-source wrapper the final installed entry point;
- managed manifest v2 provenance migration;
- capability/dependency resolution owned by its separate scope;
- final removal of migrated Skill copies from AI-Instructions after external-source verification.
