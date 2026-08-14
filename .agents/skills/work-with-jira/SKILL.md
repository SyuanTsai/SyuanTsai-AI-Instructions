---
name: work-with-jira
description: Safely read, search, create, comment on, assign, edit, or transition Jira Cloud issues using approved access paths and scoped API credentials. Use for Jira issue keys, JQL searches, work-context lookup, or requested Jira changes.
---

# Work With Jira Cloud

## Access

If Jira API access is missing, invalid, or not yet verified, use `configure-jira-api-access` to guide setup and read-only validation before continuing.

1. Read `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`, `JIRA_CLOUD_ID`, and `JIRA_API_BASE_URL` only from environment variables or an approved secret store.
2. Base every `/rest/api/3/...` and `/rest/agile/1.0/...` request on `JIRA_API_BASE_URL`; never call those REST endpoints through `JIRA_BASE_URL`.
3. If `JIRA_CLOUD_ID` or `JIRA_API_BASE_URL` is missing, use a read-only request to `${JIRA_BASE_URL}/_edge/tenant_info` to obtain the Cloud ID, then construct `https://api.atlassian.com/ex/jira/{cloudId}`. Stop and report missing inputs if this cannot be done safely; do not guess.
4. Prefer an approved connector or local Jira REST helper that follows these endpoint and credential rules. Use Atlassian MCP or Rovo only when the organization explicitly permits it and the environment is configured; a token's presence alone is not authorization.
5. Never print, log, persist, or place credential values in prompts, repositories, command arguments, or responses. Do not reveal them through diagnostic commands.

## Operations

1. Default to read-only queries. Perform external writes only when the user explicitly requests them.
2. Resolve ambiguous issue keys, JQL, projects, users, transitions, or other identifiers before acting; never guess a target.
3. Request only the fields needed for the task and avoid exposing unrelated personal data, internal links, or sensitive content.
4. Before a write, verify the target issue and intended change. Obtain confirmation before bulk, destructive, or difficult-to-reverse operations.
5. On failure, report the HTTP status, operation type, and a safely redacted error summary. Never return an Authorization header, token, or complete sensitive response body.
6. Report in the user's language what was read or changed, the target issue keys, and any unresolved permission or configuration problem without exposing secrets.
