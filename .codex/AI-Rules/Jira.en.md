# JIRA

## Access and API Endpoint

- Jira Cloud uses scoped API tokens. Read `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_CLOUD_ID`, and `JIRA_API_BASE_URL` from environment variables.
- Base every `/rest/api/3/...` and `/rest/agile/1.0/...` request on `JIRA_API_BASE_URL`; never call the REST API directly through `JIRA_BASE_URL`.
- If `JIRA_CLOUD_ID` or `JIRA_API_BASE_URL` is missing, a read-only request to `${JIRA_BASE_URL}/_edge/tenant_info` may obtain the Cloud ID, then construct the API base as `https://api.atlassian.com/ex/jira/{cloudId}`. If the required values cannot be obtained safely, stop and report what is missing instead of guessing an endpoint.
- Prefer an approved local JIRA REST helper that follows the endpoint and credential rules above. If no helper exists, call the JIRA REST API through the shell only when `JIRA_EMAIL`, `JIRA_API_TOKEN`, and a usable `JIRA_API_BASE_URL` are all available.
- Read credentials only from environment variables or an approved secret store. Never print, log, place, or persist their values in prompts, instructions, repositories, command arguments, or responses, and do not reveal them with diagnostic commands.
- Do not use Atlassian MCP or Rovo unless the current organization explicitly permits it and the environment is configured. The presence of `ATLASSIAN_ROVO_MCP_TOKEN` does not constitute authorization to use MCP.

## Operations

- When an issue key, JQL query, project, user, transition, or other identifier is missing or could resolve to different targets, obtain the required information instead of guessing.
- Read and search only the fields needed for the task. Avoid exposing unrelated personal data, internal links, or sensitive content in responses.
- Perform external writes such as creating issues, commenting, assigning, changing fields, or transitioning status only when the user explicitly requests them. Verify the target issue and intended change before submission; obtain confirmation before bulk, destructive, or difficult-to-reverse operations.
- On API failure, report the HTTP status, operation type, and a safely redacted error summary. Never return an Authorization header, token, or complete sensitive response body.
