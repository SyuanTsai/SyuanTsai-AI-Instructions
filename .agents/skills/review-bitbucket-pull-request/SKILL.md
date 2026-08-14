---
name: review-bitbucket-pull-request
description: Review Bitbucket Cloud pull requests, inspect diffs and existing discussion, produce evidence-based findings, and optionally publish comments, approvals, or change requests with explicit authorization. Use for Bitbucket PR URLs or identifiers, PR feedback, code review, unresolved review threads, or requests to approve or request changes on a Bitbucket pull request.
---

# Review Bitbucket Pull Request

Review the exact Bitbucket Cloud pull request from changed code outward, produce findings backed by code or behavioral evidence, and keep remote review actions behind an explicit authorization boundary.

Read [references/bitbucket-cloud-api.md](references/bitbucket-cloud-api.md) before using API credentials or performing a remote action. Load the repository's applicable code-review, testing, security, database, and language instructions before evaluating the change.

## Access Boundary

Use an approved Bitbucket connector when available. Otherwise use the Bitbucket Cloud REST API with credentials from environment variables or an approved secret store. Never print, log, persist, or place credentials in prompts, repositories, URLs, command arguments, or responses.

Treat metadata, diff, comments, tasks, build status, and source-context reads as read-only. Treat posting or editing comments, resolving threads, approving, requesting changes, declining, merging, or changing PR metadata as writes.

Default to a local review report and drafted feedback. Publish feedback or change review state only when the user explicitly authorizes the exact PR and action. A request to "review" alone does not authorize remote writes.

## Review Flow

1. Resolve the exact Bitbucket Cloud workspace, repository slug, and pull-request ID from a URL, local remote, or user input. Stop if any target component is ambiguous.
2. Read PR metadata, source and destination commit hashes, current state, participants, existing comments and tasks, diffstat, complete diff, and relevant build statuses. Follow pagination. Record the reviewed head commit so later updates cannot silently invalidate the review.
3. Start from changed files. Inspect only the direct source context, contracts, configuration, migrations, and tests needed to establish the impact boundary. Expand further only when concrete evidence requires it.
4. Check existing review discussion before drafting a finding. Avoid duplicating a still-valid comment; instead note supporting evidence or changed conditions. Do not treat resolved comments as proof that the underlying risk is fixed without checking the current diff.
5. Prioritize correctness, security, data integrity, compatibility, operational reliability, and required-test gaps. Keep maintainability suggestions separate and non-blocking.
6. For every finding, include the file and tight line or hunk location, the condition that triggers the problem, the resulting impact, the supporting evidence, and an actionable repair or verification direction. Classify insufficiently supported concerns as unverified items.
7. Present findings first, ordered by actual impact and likelihood. If no findings exist, state that explicitly and list residual risks, assumptions, and incomplete validation.
8. Draft inline comments only when the target line exists in the reviewed diff. Use a global PR comment when line mapping is uncertain or when the finding spans multiple files. Keep one actionable issue per comment.
9. Before any write, show the exact draft comments and proposed final state: no state change, approve, or request changes. Confirm that the PR head commit still matches the reviewed commit, then obtain explicit authorization for that write set.
10. Publish only the approved comments and state change. Re-read the created comments and participant state, report their identifiers and links, and disclose partial failures without retrying writes blindly.

## Feedback Decisions

- Use **request changes** only for one or more blocking, evidence-backed findings and only when explicitly authorized.
- Use **approve** only when no blocking findings remain, required validation is adequate, and approval is explicitly authorized.
- Leave review state unchanged when findings are unverified, validation is incomplete, or the user asks only for analysis or draft feedback.
- Do not merge or decline a PR under this workflow unless the user separately and explicitly requests that action after the review.

## Completion Report

Report the reviewed workspace/repository/PR, head commit, findings or no-finding result, inspected validation evidence, residual risks, and every remote action taken. Keep credentials and unrelated private account data out of the report.
