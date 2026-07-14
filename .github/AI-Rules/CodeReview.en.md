# Code Review Rules

- Prioritize bugs, regressions, security issues, data risks, and missing required tests. Do not demand rewrites based only on preference.
- Each finding must identify a specific file and location, explain why the issue is valid, describe its impact, and give actionable remediation.
- Present findings first in severity order. If there are none, say so explicitly and still report residual risks or unverified areas.
- When production code or tests are involved, load `.github/AI-Rules/Testing.en.md`. Focus the review on the correctness, risks, and necessary coverage of the final code and tests; treat the TDD sequence only as implementation guidance.
- Testing findings should correspond to substantive issues in the final change, such as missing required tests, insufficient assertions, tests that can pass for the wrong reason, or incorrect functional behavior.
- Use the Testing rules to determine whether the current change requires tests. New code that requires testing should have unit or integration tests at the appropriate level.
- When individual task statistics are in scope, verify that at least 90% of tasks satisfy the testing requirement. When a coverage report is in scope, verify at least 60% test coverage on contributed code.
- When EF, SQL, or queries are involved, load `.github/AI-Rules/Database.en.md` and check projection and data-access restrictions.
- If a change uses projection to address performance, focus the finding on the unresolved data-loading cause and its actual impact, identifying unnecessary entities, relationships, rows, or round trips that should be investigated.
- Unless the user explicitly requests fixes, review and report only; do not modify code.
