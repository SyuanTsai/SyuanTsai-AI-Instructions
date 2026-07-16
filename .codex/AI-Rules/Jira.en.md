# JIRA

## Access

- Prefer an approved local JIRA REST helper available in the current environment. If no helper exists, call the JIRA REST API through the shell only when `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN` are all available to the execution environment.
- Read credentials only from environment variables or an approved secret store. Never print, log, place, or persist their values in prompts, instructions, repositories, command arguments, or responses, and do not reveal them with diagnostic commands.
- Do not use Atlassian MCP or Rovo unless the current organization explicitly permits it and the environment is configured. The presence of `ATLASSIAN_ROVO_MCP_TOKEN` does not constitute authorization to use MCP.

## Operations

- When an issue key, JQL query, project, user, transition, or other identifier is missing or could resolve to different targets, obtain the required information instead of guessing.
- Read and search only the fields needed for the task. Avoid exposing unrelated personal data, internal links, or sensitive content in responses.
- Perform external writes such as creating issues, commenting, assigning, changing fields, or transitioning status only when the user explicitly requests them. Verify the target issue and intended change before submission; obtain confirmation before bulk, destructive, or difficult-to-reverse operations.
- On API failure, report the HTTP status, operation type, and a safely redacted error summary. Never return an Authorization header, token, or complete sensitive response body.
