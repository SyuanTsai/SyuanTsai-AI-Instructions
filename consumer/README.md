# Consumer gate

This directory publishes the authority-owned bootstrap, workflow templates, schemas, interface contract, and legacy conversion inventory used by conformant Skill source repositories. A consumer copies the bootstrap and workflow templates byte for byte; routine authority upgrades then change only `config/authority-pin.json`.

The pin is valid only when `repository` is the fixed official authority URL, `commit` is an immutable commit on the official `main` ancestry, and the acquired checkout matches that commit tree file by file. `config/consumer-gate.json` declares only consumer identity, active Skills, and repository-specific checks. It must include every `requiredRepositoryChecks` entry assigned by `legacy-migration.json`.

The formal workflow uses `pull_request_target` so a pull request cannot replace the workflow applied to itself. Candidate execution has no environment secret; only prepare receives a read-only workflow token for approved acquisition. A separate report job, which never checks out candidate bytes or downloads candidate artifacts, uses the dedicated App to publish `repository-contract`, `skill-validator`, and `skill-tools` to the pull-request head.

Remote App, environment, Actions event-policy, and ruleset settings are user-controlled prerequisites. Repository files alone do not establish remote merge enforcement, and no repository may claim enforcement until the App checks and ruleset source restrictions described below are active.

## Consumer repository conversion

Convert repositories serially in this order: Knowledge Content, Code Collaboration, General, Atlassian, then Darktide. Do not begin the next repository until the current repository has completed step 5. Darktide remains `pending-prerequisites` until the section below is complete.

### 0. Prerequisites

Before any conversion:

1. The dedicated GitHub App exists with only Checks read/write and Metadata read permissions, is installed only on the repositories being converted, and its private key is never handled by an agent.
2. Each repository has a `consumer-gate` environment restricted to `main`, with `CONSUMER_GATE_APP_ID` as an environment variable and `CONSUMER_GATE_APP_PRIVATE_KEY` as an environment secret. The private key must not exist as a repository or account secret.
3. Actions `allowed_events` explicitly includes `push`, `pull_request`, `workflow_dispatch`, and `pull_request_target`; listing only `pull_request_target` disables existing CI. Workflow permissions are read-only and Actions cannot create or approve pull requests.
4. The authority consumer-gate change is merged, and the remote prerequisite is verified: `main` can change only by pull request, `pull_request` and `non_fast_forward` rules are active, and `bypass_actors` is empty.

During Atlassian conversion, the SkillSpector exception set may only shrink. This conversion removes five baseline files that no longer have findings and reduces both the registry and the remaining `review-bitbucket-pull-request` baseline to its three findings; those remaining findings stay in place until SYP-493 re-approval is handled. The source gate blocks every new or modified exception, including a new registry or baseline, a changed fingerprint or reason, and an expiry renewal.

The only exception is a human-approved transition from a retained approved scanner version to the authority registry's active scanner version. Both old and new wheel hashes must match their approved entries. The registry and baseline sets may still only shrink; only `scanner.version`, `scanner.wheelSha256`, each retained exception `fingerprint`, each retained baseline `scanner_version`, and each retained fingerprint `hash` may change. All other object fields and field sets must remain byte-semantically equivalent under the gate's strict JSON comparison. Every retained exception's safe `skills/<skillId>/<file>` path must also exist as the same regular Git blob, with identical mode and object ID, in the immutable base and candidate trees; scanner migration and referenced-content changes must be separate changes. Prepare and authority-owned finalize both enforce this tree binding. After the candidate scan, finalize re-derives the transition from those trees and requires every candidate fingerprint to be used exactly once by a suppressed finding whose skill, rule, file, and reason match that fingerprint and whose line matches the paired retained exception. A policy-validated `platform-unavailable` leg has no scanner suppressions to compare; every leg that ran the scanner remains subject to the complete suppression check. Any mismatch blocks the gate. The 2.13.4 to 2.13.6 transition was manually approved by the user on 2026-11-20 with “同意切換”.

Knowledge Content, Code Collaboration, and General have no exception set and may convert after the consumer gate is merged.

### 0.5 Inventory preflight and retry

This check is mandatory for every repository:

1. Read the current protected `main` commit and tree.
2. Compare both values with that repository's `inventoryCommit` and `inventoryTree` in the latest authority `consumer/legacy-migration.json`.
3. If both values match, continue to step 1.
4. If either differs, stop the conversion and:
   - create an authority pull request from the latest authority `main` that changes only the legacy manifest;
   - re-inventory every tracked path in `.github/**`, `config/**`, `scripts/**`, `tests/**`, and declared `additionalScope` at the exact consumer commit, including each disposition and every required repository check;
   - run `scripts/consumer/Test-ConsumerManifestClosure.ps1` against that immutable commit until it returns `PASS`, attach its complete JSON, and review every advisory that may construct a legacy target;
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

The transition gate runs manifest closure twice using the manifest and scanner from the pinned authority: once on the exact inventory tree and once on the candidate tree. A split source must be absent, and every `update-tests` record must be deleted or rewritten exactly as declared. Literal path tokens outside the document allowlist fail; dynamic references, documents, and binary files are advisory. Required checks run on the converted candidate on all three platforms as behavioral detection, but cannot prove that dynamic or unexecuted references do not exist. If closure or a required check fails, refresh the authority manifest; do not weaken the check.

## Darktide 轉換前提

Darktide is blocked while its manifest status is `pending-prerequisites`. S8 owns the prerequisite runtime-and-content pull request. At the exact re-inventory commit, S8 must:

- make every retained or rewritten test, support file, development entry, and all 15 files under `skills/auto-update-darktide-mod/scripts/` portable on Windows, Linux, and macOS;
- extract the repository-specific part of `scripts/Test-Repository.ps1` into `scripts/Test-DarktideRepository.ps1`, remove legacy `scripts/Validate.ps1` and old workflow/config dependencies from retained files, and support the consumer layout in `tests/TestSupport.ps1`;
- replace unconditional Junction, `pwsh.exe`, Windows long-path, case-insensitive path, and Windows-native-type assumptions with native-host registration plus corresponding Unix behavior; do not use Pester skip or add skip inventory;
- run both `repository-darktide` and the complete `repository-pester` discovery on a simulated converted tree on `windows-latest`, `ubuntu-latest`, and `macos-latest`, with zero failures and no added skips; and
- bind the evidence to commit, tree, commands, run ID, both check IDs, and each platform result.

After S8 merges, the authority owner reruns inventory and closure at the new Darktide commit in a manifest-only pull request. Only after the output is `PASS`, the three-platform evidence is verified, status is changed to `ready`, and `prerequisites` is removed may the Darktide conversion pull request be created.

Darktide uses a two-stage required-context switch because its conversion removes the legacy workflow that produces `Darktide Translate Windows Latest Stable PowerShell`:

1. Keep the existing ruleset unchanged through S8 and while the conversion pull request is being validated. After the three mirror jobs (`repository-contract`, `skill-validator`, and `skill-tools`) have succeeded on the pull-request head and the inventory and template pre-merge checks are complete, the user temporarily changes the required contexts to those three mirror jobs before merging the Darktide conversion pull request.
2. From that temporary switch until the conversion pull request is merged, do not merge any other pull request.
3. If the conversion is withdrawn after the temporary switch, first GET the ruleset and restore the exact pre-switch `required_status_checks` value without changing unrelated rules. Other pull requests may be merged, or conversion retried, only after that readback and restoration. The user performs both the temporary switch and any restoration; an agent must not apply either ruleset change.
4. After the cleanup pull request's three App-produced checks succeed, the user performs the final switch described in step 4 below: require the same three contexts with `strict_required_status_checks_policy=true`, each restricted to the dedicated App integration ID.

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
- The authority-owned `Invoke-ConsumerRepositoryCheck.ps1` uses a normal non-positional parameter block. The consumer adapter executes the setup-bound pwsh runtime with `-File` pointing to the copied trusted repository check; both runtime and script paths and SHA-256 values must be present exactly once in `sourceValidation.frozenFiles`.
- Core-check `-File` has two closed modes: a candidate-relative tracked snapshot path, or an absolute trusted script used only by a frozen source-validation adapter. The trusted form must remain under `TrustedToolRoot`, outside candidate/artifact/authority roots, and pass canonical regular-file, no-reparse, single-link, and pre/post-launch hash checks.
- Resolver and validator stdout/stderr are persisted as bounded, create-only UTF-8 diagnostics. A prepare credential sentinel is replaced with `[REDACTED]` before any console or evidence write, still makes the gate fail closed, and is followed by the complete gate-owned surface scan.
- The authority-owned deadline budget is phase-specific because prepare, validate, and finalize are independent processes. It covers ConsumerGate, the resolver, validator, gate Git, and manifest-closure Git. Prepare reserves 1,800 seconds for three PowerShell acquisition requests, 1,440 seconds for four resolver invocations including process grace, and 600 seconds for Git (3,840 seconds total). Validate reserves 1,920 seconds for validation including process grace and 600 seconds for Git (2,520 seconds total). Finalize reserves 600 seconds for Git. Adding the three phases and 300 seconds for checkout and tool setup gives a 7,260-second inner bound; with the 600-second evidence buffer, 7,860 seconds is strictly below the 140-minute (8,400-second) gate-leg deadline. Git commands remain limited to 120 seconds each. Aggregate and report jobs use 15-minute and 10-minute deadlines respectively. The bootstrap template (`scripts/Invoke-PinnedAuthority.ps1`) still launches its own Git commands without deadlines; the SYP-488 bootstrap change will bound those calls and add them to the budget, so this is not yet a complete upper bound for the whole job.
- Resolver, validator, and Git children run through the platform runtime's owned-process boundary: Windows uses a hidden process in an owned Job, while Linux and macOS use an independent process group. Every child has an explicit deadline and verified descendant cleanup. Text capture is limited to 1,048,576 characters per stream; exceeding that bound fails the gate instead of accepting truncated output. Git byte-oriented calls use an owned capture helper to preserve undecoded stdout in create-only files before reading it back, with an explicit 2 GiB read bound; their bounded textual stderr still fails on the per-stream character limit.
