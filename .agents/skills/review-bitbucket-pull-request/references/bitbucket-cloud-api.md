# Bitbucket Cloud PR API reference

## Authentication and scopes

Use `https://api.bitbucket.org/2.0` for Bitbucket Cloud REST API calls. With an Atlassian API token, use HTTP Basic authentication with the Atlassian account email as the username and the API token as the password. Construct the authorization header only in memory.

Read these settings from environment variables or an approved secret store:

| Variable | Purpose | Safe validation |
| --- | --- | --- |
| `BITBUCKET_EMAIL` | Atlassian account email associated with the token | Presence and email shape only |
| `BITBUCKET_API_TOKEN` | Scoped Atlassian API token for Bitbucket | Presence only; never inspect token length or characters |
| `BITBUCKET_API_BASE_URL` | Bitbucket Cloud REST base | Exactly `https://api.bitbucket.org/2.0` |
| `BITBUCKET_WORKSPACE` | Optional default workspace | Confirm against the PR target before use |

Create or rotate tokens through [Atlassian API token settings](https://id.atlassian.com/manage-profile/security/api-tokens) and verify current requirements in [Bitbucket's API-token guide](https://support.atlassian.com/bitbucket-cloud/docs/using-api-tokens/).

Use the minimum current scopes needed:

- Read a PR, diff, comments, tasks, and status: `read:pullrequest:bitbucket`.
- Post feedback, approve, or request changes: provision both `read:pullrequest:bitbucket` and `write:pullrequest:bitbucket`.
- Read source through repository endpoints outside the PR endpoints: add `read:repository:bitbucket`.

Bitbucket scopes do not imply one another. Recheck [Bitbucket API-token permissions](https://support.atlassian.com/bitbucket-cloud/docs/api-token-permissions/) when creating or rotating a token.

## Read endpoints

Use this prefix:

```text
${BITBUCKET_API_BASE_URL}/repositories/{workspace}/{repo_slug}/pullrequests/{pull_request_id}
```

Read only what the review needs:

| Purpose | Method and suffix |
| --- | --- |
| PR metadata | `GET` with no suffix |
| Activity | `GET /activity` |
| Comments | `GET /comments` |
| Tasks | `GET /tasks` |
| Commits | `GET /commits` |
| Diffstat | `GET /diffstat` |
| Unified diff | `GET /diff` |
| Patch | `GET /patch` |
| Build statuses | `GET /statuses` |

Honor pagination and rate-limit responses. Diff, patch, and diffstat endpoints may redirect; follow only trusted Bitbucket destinations and never forward an Authorization header to an untrusted host.

## Feedback endpoints

Use the [official pull-request API reference](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/) to confirm the current payload before a write.

| Action | Method and suffix |
| --- | --- |
| Create a PR comment | `POST /comments` |
| Update a known comment | `PUT /comments/{comment_id}` |
| Resolve a comment | `POST /comments/{comment_id}/resolve` |
| Approve | `POST /approve` |
| Request changes | `POST /request-changes` |

For a global comment, send only the Markdown content required by the API. For an inline comment, also identify the changed file path and a line represented in the current diff. Use destination-side line coordinates for added or context lines and source-side coordinates for removed lines. If the mapping is not certain, use a global comment that names the path and hunk instead of risking a misplaced inline comment.

Before posting, re-read the PR and compare its source commit hash with the reviewed hash. If it changed, stop and refresh the review. After posting, record returned comment identifiers and verify the final participant state. Never retry a timed-out write until a read confirms whether the first request succeeded.
