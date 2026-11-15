# Consumer gate

This directory publishes the authority-owned bootstrap, workflow templates, schemas, interface contract, and legacy conversion inventory used by conformant Skill source repositories. A consumer copies the bootstrap and workflow templates byte for byte; routine authority upgrades then change only `config/authority-pin.json`.

The pin is valid only when `repository` is the fixed official authority URL, `commit` is an immutable commit on the official `main` ancestry, and the acquired checkout matches that commit tree file by file. `config/consumer-gate.json` declares only consumer identity, active Skills, and repository-specific checks. It must include every `requiredRepositoryChecks` entry assigned by `legacy-migration.json`.

The formal workflow uses `pull_request_target` so a pull request cannot replace the workflow applied to itself. Candidate execution has no environment secret; only prepare receives a read-only workflow token for approved acquisition. A separate report job, which never checks out candidate bytes or downloads candidate artifacts, uses the dedicated App to publish `repository-contract`, `skill-validator`, and `skill-tools` to the pull-request head.

Remote App, environment, Actions event-policy, and ruleset settings are user-controlled prerequisites. Repository files alone do not establish remote merge enforcement, and no repository may claim enforcement until the App checks and ruleset source restrictions described below are active.

## Consumer repository conversion

Convert repositories serially in this order: Knowledge Content, Code Collaboration, General, then Atlassian. Do not begin the next repository until the current repository has completed step 5. Darktide remains deferred in `legacy-migration.json`.

### 0. Prerequisites

Before any conversion:

1. The dedicated GitHub App exists with only Checks read/write and Metadata read permissions, is installed only on the repositories being converted, and its private key is never handled by an agent.
2. Each repository has a `consumer-gate` environment restricted to `main`, with `CONSUMER_GATE_APP_ID` as an environment variable and `CONSUMER_GATE_APP_PRIVATE_KEY` as an environment secret. The private key must not exist as a repository or account secret.
3. Actions explicitly permits `pull_request_target`; workflow permissions are read-only and Actions cannot create or approve pull requests.
4. The authority consumer-gate change is merged, and the remote prerequisite is verified: `main` can change only by pull request, `pull_request` and `non_fast_forward` rules are active, and `bypass_actors` is empty.

Atlassian has additional prerequisites: the approved exception-policy and knowledge-source changes must already be merged; its pin must include that authority revision; its exception set must contain the required review scope and evidence paths; and the user must sign it from a clean clone with the merged signing tool. Knowledge Content, Code Collaboration, and General have no exception set and may convert after the consumer gate is merged.

### 0.5 Inventory preflight and retry

This check is mandatory for every repository:

1. Read the current protected `main` commit and tree.
2. Compare both values with that repository's `inventoryCommit` and `inventoryTree` in the latest authority `consumer/legacy-migration.json`.
3. If both values match, continue to step 1.
4. If either differs, stop the conversion and:
   - create an authority pull request from the latest authority `main` that changes only the legacy manifest;
   - re-inventory every tracked path in `.github/**`, `config/**`, `scripts/**`, and `tests/**` at the exact consumer commit, including each disposition and every required repository check;
   - merge only after the authority regressions pass;
   - close and recreate any existing conversion pull request on the new base, or prove its event base is exactly the new `inventoryCommit` before retriggering it; and
   - point the conversion pin at an authority commit containing the refreshed manifest.
5. Do not substitute a rebase with stale dispositions, a hand-edited consumer config, or a ruleset bypass for this process.
6. Immediately before merge, re-check that the event base commit and tree still equal the manifest values.

### 1. Conversion pull request

Use an ordinary pull request without bypass:

1. Apply every file disposition for the repository from `legacy-migration.json`, preserving or splitting repository-specific behavior exactly as directed.
2. Copy these three authority files byte for byte:
   - `consumer/bootstrap/Invoke-PinnedAuthority.ps1` to `scripts/Invoke-PinnedAuthority.ps1`;
   - `consumer/workflows/consumer-gate.yml` to `.github/workflows/consumer-gate.yml`;
   - `consumer/workflows/consumer-gate-transition.yml` to `.github/workflows/consumer-gate-transition.yml`.
3. Add `config/authority-pin.json` using the published pin schema.
4. Add `config/consumer-gate.json`. Its `repositoryChecks` must contain exactly one matching entry for every required check in the manifest; do not add a separate `requiredRepositoryChecks` property.
5. Let the transition workflow validate the pull request. It must use the candidate bootstrap with `-TransitionFromLegacy`, and the protected base must contain neither the bootstrap nor pin.
6. Before merge, independently compare the SHA-256 of all three copied templates with the pinned authority and verify the pin is on official authority `main`. This human verification cannot be replaced by bypass.

### 2. First push after conversion

The formal push workflow sees that `event.before` has no bootstrap while the new candidate does. It records `transition push, gate skipped` and succeeds without invoking the candidate bootstrap. This one-time skip is expected; push does not use the App or an environment.

### 3. Cleanup pull request

Open a pull request whose only change is deletion of `.github/workflows/consumer-gate-transition.yml`. The protected `pull_request_target` workflow must validate it. Confirm all three App-produced checks appear on the pull-request head and succeed; this also establishes the App's recent check-run history required for source-restricted status checks.

### 4. Align the remote ruleset

Only after step 3 succeeds, the user updates the existing required-status-check rule without changing unrelated rules:

- `strict_required_status_checks_policy` is `true`;
- `do_not_enforce_on_create` is `false`;
- the only required contexts are `repository-contract`, `skill-validator`, and `skill-tools`;
- each context's expected source is the dedicated App integration ID.

Reconfirm that pull-request and non-fast-forward rules remain enabled and `bypass_actors` remains empty. Until this readback is complete, do not state that remote merge enforcement is active.

### 5. Complete cleanup

Merge the cleanup pull request. Future authority upgrades modify only the `commit` in `config/authority-pin.json`; the base bootstrap validates the candidate pin and rejects unsupported interface boundaries or non-main authority commits.

## Operational notes

- The formal workflow has three required platform legs: Windows, Linux, and macOS. An authority repository change that merely publishes these templates does not prove those consumer legs have run.
- `consumer-gate-transition.yml` is single-use and must be removed in the cleanup pull request.
- If `pull_request_target` cannot be explicitly allowed, stop. A `workflow_run` fallback requires a separate Standard and template change; do not improvise it in a consumer repository.
