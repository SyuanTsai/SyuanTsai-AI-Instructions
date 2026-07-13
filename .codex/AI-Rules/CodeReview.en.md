# Code Review Rules

- Prioritize bugs, regressions, security issues, data risks, and missing required tests. Do not demand rewrites based only on preference.
- Each finding must identify a specific file and location, explain why the issue is valid, describe its impact, and give actionable remediation.
- Present findings first in severity order. If there are none, say so explicitly and still report residual risks or unverified areas.
- When production code or tests are involved, load `.codex/AI-Rules/Testing.en.md` and check test-first order, framework, and required coverage.
- Verify that all new code includes unit or integration tests at the applicable level. At least 90% of tasks completed by an individual contributor must satisfy this requirement.
- Verify that contributed code maintains at least 60% test coverage, using the project's existing coverage report or tool output as evidence.
- If individual task statistics or coverage data are unavailable in the review scope, mark the threshold as unverified; do not assume compliance.
- When EF, SQL, or queries are involved, load `.codex/AI-Rules/Database.en.md` and check projection and data-access restrictions.
- If a change uses projection to address performance, the finding must explain that projection does not solve the root cause and that unnecessary data loaded by a single query should be identified and avoided. Do not report only a projection-rule violation.
- Unless the user explicitly requests fixes, review and report only; do not modify code.
