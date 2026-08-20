# SYP-79 — New Skill Repository Readiness

## Status

This is the historical SYP-79 readiness contract. The four external Skill repositories are now provisioned and SYP-86 uses their immutable production pins. Current cutover and rollback gates are in `docs/syp-86-production-cutover.md`.

## Initial source inventory

The runtime does not hard-code these IDs. They are the production Catalog sources:

| Source ID | Domain |
| --- | --- |
| `general` | General reusable Agent Skills |
| `code-collaboration` | Code collaboration / PR / implementation workflows |
| `knowledge-content` | Knowledge and content capture workflows |
| `atlassian-ecosystem` | Jira / Confluence / Atlassian ecosystem workflows |

Adding a fifth source must require only Catalog + Lock changes, not bootstrap code changes.

## Required repository layout

Each new Skill repository uses the same flat stable-ID layout:

```text
<repository-root>/
└─ .agents/
   └─ skills/
      ├─ <skill-id>/
      │  ├─ SKILL.md
      │  ├─ scripts/
      │  ├─ references/
      │  └─ assets/
      └─ ...
```

Rules:

- Every physical Skill directory is `.agents/skills/<stable-skill-id>`.
- `SKILL.md` is mandatory.
- Skill stable IDs do not change when moving repositories.
- Repository/domain names are metadata and never become routing conditions.
- A source repository must not contain AI-Instructions base/rule files as part of Skill delivery.

## Catalog entry required for a new repository

```json
{
  "id": "<source-id>",
  "repository": "https://github.com/<owner>/<repository>.git"
}
```

Each migrated Skill changes only its source metadata:

```json
{
  "source": {
    "sourceId": "<source-id>",
    "path": ".agents/skills/<skill-id>"
  }
}
```

No bootstrap code change is allowed for this migration.

## Lock entry required before runtime use

Every real source must have a lock entry containing:

- `requestedRef`
- `requestedRefType`
- full 40-character `resolvedCommit`
- `resolvedVersion`
- downloaded archive `archiveSha256`

Every active Skill must also have `contentSha256` calculated from the deterministic inventory contract:

```text
<repository-relative-path>\t<raw-file-sha256>\n
```

Inventory paths are forward-slash repository-relative paths sorted with ordinal ordering. The concatenated UTF-8/no-BOM inventory is SHA-256 hashed.

Every regular file under the Skill root participates in that inventory, including hidden and dot-prefixed resources. Path identity is ordinal and case-sensitive so repositories that support case-distinct names produce deterministic hashes without collisions.

## Runtime guarantees already implemented

Before target mutation starts, the multi-source path now performs:

1. schema v3 profile / include / exclude selection;
2. Skill → `sourceId/path` routing from Catalog + Lock;
3. pruning of unused sources;
4. commit-pinned GitHub archive retrieval (or explicit local fixture override);
5. archive SHA-256 validation;
6. independent source staging;
7. safe Skill path and `SKILL.md` validation;
8. deterministic Skill `contentSha256` validation;
9. composition of AI-Instructions Instructions/Rules with only the selected external Skills;
10. handoff to the mutation engine with immutable per-file provenance only after all preflight work succeeds.

The mutation engine protects customized/unmanaged files, writes manifest v2 when invoked by the production wrapper, and preserves raw Skill bytes through non-allowlist PersonalAgent stash refreshes.

## Repository provisioning sequence

For each source repository:

1. Create the repository without moving Skills yet.
2. Add `.agents/skills/` structure.
3. Move the assigned Skills without changing stable IDs.
4. Commit the source repository.
5. Resolve the immutable commit SHA.
6. Download the exact commit archive and calculate `archiveSha256`.
7. Calculate deterministic `contentSha256` for every migrated Skill.
8. Add/update Catalog `sources[]` and Skill `sourceId/path`.
9. Update Catalog Lock.
10. Run the multi-source bootstrap against fixtures / a disposable target repository.
11. Only after verification, remove the migrated Skill copy from AI-Instructions.

## Historical stop condition for SYP-79 pre-repository work

The pre-repository phase is complete when the next required operation is **creating the first external Skill repository**. Repository creation and physical Skill migration must occur as a separate, explicit step so source URLs and immutable pins are known before Catalog/Lock are finalized.
