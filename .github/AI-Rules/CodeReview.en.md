# Code Review Rules

- Prioritize bugs, regressions, security issues, data risks, and missing required tests. Do not demand rewrites based only on preference.
- Each finding must identify a specific file and location, explain why the issue is valid, describe its impact, and give actionable remediation.
- Present findings first in severity order. If there are none, say so explicitly and still report residual risks or unverified areas.
- When production code or tests are involved, load `.github/AI-Rules/Testing.en.md`. Focus the review on the correctness, risks, and necessary coverage of the final code and tests; treat the TDD sequence only as implementation guidance.
- Testing findings should correspond to substantive issues in the final change, such as missing required tests, insufficient assertions, tests that can pass for the wrong reason, or incorrect functional behavior.
- Verify that all new code includes unit or integration tests at the applicable level. At least 90% of tasks completed by an individual contributor must satisfy this requirement.
- Verify that contributed code maintains at least 60% test coverage, using the project's existing coverage report or tool output as evidence.
- If individual task statistics or coverage data are unavailable in the review scope, mark the threshold as unverified; do not assume compliance.
- Check applicable coverage for success, boundaries, failures, ordering, and database side effects.
- For performance tests, verify separation from functional tests and ensure unstable execution time is not a hard CI threshold.
- For EF, SQL, or query changes, load `.github/AI-Rules/Database.en.md` and identify the location and reason for any projection-rule violation.
- If a change uses projection to address performance, the finding must explain that projection does not solve the root cause and that unnecessary data loaded by a single query should be identified and avoided. Do not report only a projection-rule violation.
