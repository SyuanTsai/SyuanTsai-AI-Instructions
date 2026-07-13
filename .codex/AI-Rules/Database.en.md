# Database Rules

- Projection does not truly solve data-access performance problems; address the root cause of loading unnecessary data in a single query. For EF or SQL, do not use projections to carry core logic or returned data.
- Projections are allowed only to retrieve a key or ID, a count, a boolean flag, or no more than three scalar fields.
- Do not add a model, DTO, or class to carry returned data unless the user explicitly approves it.
- Before changing data access, inspect only the relevant existing queries, entity relationships, indexes, and conventions.
- For query performance or N+1 work, also load `.codex/AI-Rules/Testing.en.md` and validate using its performance-test rules.
