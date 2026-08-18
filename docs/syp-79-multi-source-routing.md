# SYP-79 Multi-Source Routing

## Goal

Make Skills source acquisition data-driven from `catalog.sources[]` and Skill `source.sourceId/path`, without hard-coded domain routing.

## First vertical slice

The first slice is intentionally split into two pre-mutation stages:

1. `Resolve-SkillsSourcePlan`
   - accepts Catalog, Lock, and the selected stable Skill IDs;
   - resolves each selected Skill to its declared source ID and repository-relative path;
   - returns only sources required by the selected Skills;
   - verifies Catalog/Lock routing agreement;
   - fails closed for unknown Skills, unknown sources, removed Skills, missing lock entries, and unsafe paths.

2. `Expand-ValidatedSkillsSourceArchives`
   - accepts the routing plan plus local archive fixtures;
   - validates the pinned archive SHA-256 before extraction;
   - stages every selected source independently;
   - verifies each selected Skill directory and `SKILL.md` exist inside its routed source;
   - returns staged source/Skill roots for desired-set composition.

No target repository mutation occurs in either stage.

## Current boundary

This slice establishes generic N-source planning and safe local archive staging. The existing `bootstrap-ai-instructions.ps1` still owns the legacy single instruction archive and target mutation flow. The next integration step is to feed the staged Skill roots into bootstrap desired-set composition while keeping Base Instructions/Rules sourced from `AI-Instructions`.

## Invariants

- Source IDs are data, not domain-specific branches.
- Unused sources are omitted from the acquisition plan.
- Every selected source is independently pinned and validated.
- A required source failure prevents desired-set composition.
- Skill paths remain repository-relative and cannot traverse outside the staged source root.
- Instruction-only synchronization may produce an empty Skills source plan.
