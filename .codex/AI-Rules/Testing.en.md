# Testing Rules

## Test-First Development

- Use the TDD Red-Green-Refactor cycle by default: first create the smallest test that fails because the target behavior is missing, write the smallest production change that makes it pass, then refactor under test protection.
- During feature analysis or planning, define the expected behavior, suitable test level, and smallest failing test, then plan smoke and regression coverage according to the change's risk.
- Prefer unit tests.
- If unit testing is unsuitable, explain why to the user first, then use the closest applicable approach in the existing test architecture.

The following changes are exempt from test-first development:

- Configuration-only changes such as YAML, pipelines, CI/CD, or appsettings.
- Thin Controller changes limited to routes, attributes, binding, authorization annotations, or calls to an existing service.
- Formatting, comments, log messages, or renaming only.

A Controller containing business logic, conditions, error handling, or data transformation still requires tests first.

## Testing Strategy

1. Prefer unit tests for faster and more stable feedback.
2. Use integration tests when unit tests cannot adequately verify component integration, databases, or external boundaries. Do not add slower integration tests for behavior that unit tests can cover.
3. Use smoke tests to verify that primary features and critical paths have not completely failed.
4. Use regression tests to verify that the change has not broken related existing behavior.

## Framework and Style

- Follow the existing framework: use xUnit in xUnit projects, NUnit in NUnit projects, and prefer NUnit only for a new project with no convention.
- Structure tests using Given-When-Then.
- In NUnit, prefer `Assert.Multiple` when verifying multiple conditions.
- In xUnit, follow the project's existing assertion style and do not use NUnit-only APIs.

## Coverage

Cover as applicable:

- Normal success.
- Boundaries such as no data, no subscription, or `null`.
- Failures such as insufficient permissions, invalid states, or cancellation.
- Ordering and earliest or most recent data.
- Database side effects caused by writes.

## Performance Tests

- Keep performance tests separate from functional tests.
- Performance tests must run multiple measured samples and record the sample count, average execution time, minimum execution time, maximum execution time, and DB query count. Mark DB query count as not applicable when no database is involved.
- Reset the SQL command counter only after seeding so Arrange SQL is excluded.
- N+1 tests should compare at least two result sizes, record the DB query count for each, and confirm that the query count remains fixed or within an explicit upper bound instead of growing linearly with the result count.
- CI must not use execution time in milliseconds as a hard threshold. Verify query count, query shape, and result correctness.
- Mark manual benchmarks `Skip` by default and exclude them from normal test runs.
