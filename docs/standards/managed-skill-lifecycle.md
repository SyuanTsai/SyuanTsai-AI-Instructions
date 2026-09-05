# Managed Skill Lifecycle Contract v1

Tracking: Jira `SYP-194`.

This document is the normative companion to `docs/standards/skill-repository-standard.md`. The `docs/standards/` directory remains the only authority for the shared lifecycle contract. A repository adapter MAY provide path, host, or command-line adapters, but MUST preserve the classifications, ordering, ownership evidence, fail-closed behavior, transaction semantics, and post-install checks defined here. A repository MUST NOT copy this contract into a second repository-local policy.

## Scope and compatibility

This contract governs a managed consumer projection under `.agents/skills/<skill-id>/` and the user-scoped v1 managed manifest at `.agents/catalog-skills.manifest.json`. The runtime catalog/package manifest v2 contract remains defined by the existing central catalog contract. This SYP-194 slice preserves the existing v1 user manifest and the explicit `-MigrateLegacyCatalogSkills` and `-ForceReinstallManagedSkills` controls; changing Catalog or Lock pinning is outside this lifecycle contract.

The contract applies to replacement, adoption, removal, rename, tombstone, rollback, crash recovery, and post-install verification. It applies equally to local, pre-push, CI, publish, and install paths when those paths mutate a managed consumer projection. The execution environment MAY differ, but pass/block meaning MUST NOT differ.

## Ownership classifications

Every candidate path and every path considered for destructive change MUST have machine-readable ownership evidence. The evidence record shape is defined by `schemas/managed-skill-lifecycle-v1.schema.json`.

### Managed

`managed` means a validated v1 managed-manifest entry identifies the exact target path and the observed target bytes match the manifest SHA-256. The manifest entry is sufficient ownership evidence for replacement or removal of the exact path. A missing managed path MAY be removed from the next manifest, but an existing path that is not byte-identical is `managed-drift`.

### Managed drift

`managed-drift` means a manifest entry exists but the observed target bytes differ from the recorded SHA-256. Drift MUST block replacement or removal by default. `-ForceReinstallManagedSkills` is the explicit operator control for replacing drift; the result MUST retain the observed path, expected hash, actual hash, evidence, and remediation in the transaction/audit result. A force switch MUST NOT turn an unknown path into an owned path.

### Known legacy

`known-legacy` means all of the following are true:

1. The operator explicitly enabled legacy adoption (`-MigrateLegacyCatalogSkills`).
2. The directory name is the current Catalog skill ID or an explicit lifecycle alias declared by the central Catalog.
3. The path is the legacy Skill definition path or a path in the desired managed inventory.
4. No reparse point, special file, or unlisted file is present in the legacy directory.

An active ID, rename, or alias is evidence only when the current Catalog lifecycle data proves the relationship. A removed or retired ID MUST NOT be guessed as a replacement for another Skill. A legacy directory containing any other file is `unmanaged-unknown` and MUST block the complete migration before mutation; the extra file MUST be preserved.

### Unmanaged or unknown

`unmanaged-unknown` means no current managed-manifest entry or explicit known-legacy evidence proves ownership. Unknown personal Skills and directories MUST be preserved. An existing unknown file at a desired target path MUST block if its bytes differ from the candidate. An exact byte match MAY remain in place, but the result MUST NOT claim managed ownership or permit a later destructive action solely because the path matched.

### Controlled candidate

`controlled-candidate` identifies the immutable candidate bytes staged by the resolver. Before any user-environment mutation, every desired file MUST be a regular, non-reparse staged file whose raw bytes hash exactly to the desired inventory SHA-256. Missing staging, invalid hash, changed bytes, or a staging path crossing a reparse point MUST block closed with no target mutation.

## Deterministic replacement and migration order

The canonical lifecycle is:

```text
Resolve desired state
→ Controlled candidate acquisition
→ Verify every staged file path, file type, raw bytes, and SHA-256
→ Validate package, Catalog, Lock, and manifest contracts
→ Inventory target paths and classify ownership
→ Acquire the user-scope lock and revalidate observed target state
→ Create a transaction-owned backup and immutable staged-byte snapshot
→ Revalidate target observations immediately before mutation
→ Delete only paths proven managed or known-legacy
→ Replace/write from the transaction-owned staged snapshot
→ Write the desired managed manifest
→ Verify exact installed bytes, exact manifest inventory, manifest bytes, and lock binding
→ Remove the recovery journal only after all checks pass
```

The transaction-owned staged snapshot MUST be created from the preflight-verified bytes and MUST be the only source used for writes. A later change to the original staging path MUST NOT change the bytes written by the transaction. Candidate staging failure MUST happen before a backup journal or consumer mutation is created.

Replacement MUST be deterministic by stable Skill ID and target path. A rename MUST be represented by an explicit new ID plus a Catalog lifecycle alias/tombstone transition. The old path MUST be removed only when the current manifest or explicit known-legacy evidence proves ownership. An unknown owner, collision, local drift without force, reparse point, special file, or concurrent target change MUST block closed. No destructive action may be justified by directory name alone.

Backup and recovery MUST be transaction-scoped. The recovery journal MUST describe the exact original and intended applied hashes. On mutation failure, the implementation MUST restore the original state or leave a recovery journal that can be validated and resumed. Recovery MUST refuse tampered backups, malformed hashes, unsafe paths, missing files, concurrent edits, and non-regular/reparse entries.

## Failure and evidence contract

Blocked results MUST be machine-readable and MUST retain a human-actionable message plus structured failure details. Each failure detail MUST include:

- a stable `code`;
- Skill ID and repository-relative target `path`;
- `classification` and `owner`;
- the exact ownership/integrity `evidence` used;
- `destructiveChangeAllowed`, which MUST be false for the blocked action;
- `backupCreated`, which MUST be false when the block occurs before transaction backup;
- expected and actual SHA-256 values when applicable; and
- one or more remediation actions.

The reconciler result MAY contain additional operational fields, but it MUST expose `failureDetails` and `ownership` without hiding the evidence in console-only text. Failure codes MUST distinguish at least staged integrity mismatch, unmanaged collision, legacy unmanaged content, and managed local drift. A generic error string without classification, evidence, and remediation is insufficient for a destructive-change decision.

## Adapter and lifecycle boundaries

An adapter MAY translate the central contract to a host-specific install root, lock primitive, archive provider, or reporting format. It MUST preserve the central ownership proof and exact pass/block semantics. It MUST NOT:

- infer ownership from a path, filename, or directory name without manifest/Catalog evidence;
- delete unmanaged/private Skills during cleanup;
- skip candidate integrity verification because the candidate came from a local cache;
- write from a mutable staging path after preflight;
- weaken rollback, recovery, or post-install verification;
- create a repository-local lifecycle/security/release policy; or
- treat a successful package download, manifest write, or process exit as post-install integrity proof.

Changes to this contract are Standard v1 authority changes and MUST update the central authority regression suites and the affected reference/fan-out conformance evidence before release or migration.
