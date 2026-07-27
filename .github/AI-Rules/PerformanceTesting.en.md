# Performance Testing Rules

- Apply these rules only when the user explicitly requests performance validation or the task itself involves performance improvement, benchmarking, or N+1 behavior. Do not add performance tests by default to general feature changes under the current policy.
- When adding or modifying performance tests, also load `.github/AI-Rules/Testing.en.md` and follow the existing test framework and style.
- Keep performance tests separate from functional tests.
- Performance tests must run multiple measured samples and record the sample count, average execution time, minimum execution time, maximum execution time, and DB query count. Mark DB query count as not applicable when no database is involved.
- Reset the SQL command counter only after seeding so Arrange SQL is excluded.
- N+1 tests should compare at least two result sizes, record the DB query count for each, and confirm that the query count remains fixed or within an explicit upper bound instead of growing linearly with the result count.
- CI must not use execution time in milliseconds as a hard threshold. Verify query count, query shape, and result correctness.
- Mark manual benchmarks `Skip` by default and exclude them from normal test runs.
