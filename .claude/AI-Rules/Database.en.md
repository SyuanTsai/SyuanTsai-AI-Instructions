# Database Rules

- Improve data-access performance by first identifying unnecessary entities, relationships, or rows loaded by one query, along with excess round trips, N+1 behavior, and other root causes, then adjust the query scope and loading strategy. <!-- ai-invariant:database.root-cause-evidence -->
- Projection is an available way to reduce the data scope. Retrieve only the fields required for the target behavior and validate the result with evidence such as the query plan, row and column volume, tracking, and round trips; never substitute an arbitrary field-count limit for that analysis. <!-- ai-invariant:database.projection-evidence -->
- Prefer an existing business response, DTO, or read model. When a new internal projection type is needed, use the smallest shape consistent with the existing architecture. Ask the user only when adding or changing a public contract, crossing layer responsibilities, or expanding beyond the approved change scope. <!-- ai-invariant:database.contract-boundary -->
- Use projection only for data shaping; keep business rules and core logic within the existing application or domain boundary. <!-- ai-invariant:database.logic-boundary -->
- Before changing data access, inspect only the relevant existing queries, entity relationships, indexes, and conventions.
- For query performance or N+1 work, also use `.agents/skills/verify-data-access-performance/SKILL.md` for diagnosis and validation. <!-- ai-invariant:database.performance-validation -->
