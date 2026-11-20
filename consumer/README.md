# Consumer gate

This directory publishes the authority-owned bootstrap, workflow templates, schemas, interface contract, and legacy conversion inventory used by conformant Skill source repositories. A consumer copies the bootstrap and workflow templates byte for byte; routine authority upgrades then change only `config/authority-pin.json`.

The pin is valid only when `repository` is the fixed official authority URL, `commit` is an immutable commit on the official `main` ancestry, and the acquired checkout matches that commit tree file by file. `config/consumer-gate.json` declares only consumer identity, active Skills, and repository-specific checks. It must include every `requiredRepositoryChecks` entry assigned by `legacy-migration.json`.

The formal workflow uses `pull_request_target` so a pull request cannot replace the workflow applied to itself. Candidate execution has no environment secret; only prepare receives a read-only workflow token for approved acquisition. A separate report job, which never checks out candidate bytes or downloads candidate artifacts, uses the dedicated App to publish `repository-contract`, `skill-validator`, and `skill-tools` to the pull-request head.

Remote App, environment, Actions event-policy, and ruleset settings are user-controlled prerequisites. Repository files alone do not establish remote merge enforcement, and no repository may claim enforcement until the App checks and ruleset source restrictions described below are active.

## Temporary `@skill-tools/core` Windows path patch

The resolver applies a narrowly pinned patch to `@skill-tools/core` 0.2.2 after npm installation. That release compares resolved Windows paths against a literal `/` suffix, so it drops every `SKILL.md` file reference on Windows. Without the patch, Progressive Disclosure scores 8/15 on Windows instead of 15/15, and the `file-reference-exists` rule incorrectly accepts missing references on Windows.

The patch changes only the platform-specific path comparison in the ESM and CJS distributions. It does not change scoring logic or thresholds. Package name and version, both pre-patch SHA-256 values, and both post-patch SHA-256 values are fixed in the resolver; any mismatch fails closed. Consequently, a `skill-tools` release that selects a different core package will fail the gate and requires human review.

Remove the patch function, its resolver call, its tests, and the three-platform probe workflow after upstream publishes a corrected `@skill-tools/core` release and `skill-tools` depends on that corrected release. Do not keep the workaround by merely updating its pins.

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

Merge the cleanup pull request. Future authority upgrades use one re-pin pull request: update the `commit` in `config/authority-pin.json` and project the bootstrap/workflow templates published by that candidate authority. The protected base bootstrap drives the new authority, while `Assert-GateProtectedFiles` accepts each protected file only when it equals either the protected base bytes or the candidate pin's authority template. It still rejects unsupported interface boundaries, non-main authority commits, and any third byte form.

## Operational notes

- The formal workflow has three required platform legs: Windows, Linux, and macOS. An authority repository change that merely publishes these templates does not prove those consumer legs have run.
- `consumer-gate-transition.yml` is single-use and must be removed in the cleanup pull request.
- If `pull_request_target` cannot be explicitly allowed, stop. A `workflow_run` fallback requires a separate Standard and template change; do not improvise it in a consumer repository.
- The authority-owned `Invoke-ConsumerRepositoryCheck.ps1` uses a normal non-positional parameter block. The consumer adapter executes the setup-bound pwsh runtime with `-File` pointing to the copied trusted repository check; both runtime and script paths and SHA-256 values must be present exactly once in `sourceValidation.frozenFiles`.
- Core-check `-File` has two closed modes: a candidate-relative tracked snapshot path, or an absolute trusted script used only by a frozen source-validation adapter. The trusted form must remain under `TrustedToolRoot`, outside candidate/artifact/authority roots, and pass canonical regular-file, no-reparse, single-link, and pre/post-launch hash checks.
- Resolver and validator stdout/stderr are persisted as bounded, create-only UTF-8 diagnostics. A prepare credential sentinel is replaced with `[REDACTED]` before any console or evidence write, still makes the gate fail closed, and is followed by the complete gate-owned surface scan.
- The consumer bootstrap is intentionally thin. Before authority verification it performs only strict input/revision/pin/binding checks and Git acquisition/tree verification. Its Git launcher asynchronously drains stdout/stderr, limits fetch to 300 seconds and every other command to 60 seconds, disables `maintenance.auto` and detached GC, and enforces shared phase reserves of 720 seconds for prepare/aggregate and 180 seconds for validate/finalize. After `Assert-AuthorityTree` succeeds, it imports `scripts/platform-runtime.psd1` and `scripts/consumer/ConsumerBootstrapSupervisor.psm1` only from that verified authority worktree. The authority supervisor then owns phase environment filtering, prepare-only token delivery, output limits and create-only diagnostics, credential-sentinel suppression, exit-code normalization, phase deadlines, process ownership, and cleanup evidence.
- The authority-owned deadline budget is phase-specific because prepare, validate, and finalize are independent processes. ConsumerGate keeps its existing inner reserves: prepare 3,840 seconds, validate 2,520 seconds, and finalize 600 seconds. Adding bootstrap Git reserves of 720/180/180 seconds and 60 seconds of supervisor grace to each phase yields 4,620/2,760/840 seconds. Their 8,220-second sum plus 300 seconds for workflow setup is an 8,520-second inner bound; with a 300-second evidence buffer, 8,820 seconds is strictly below the 150-minute (9,000-second) gate-leg deadline. Aggregate reserves 60 seconds for the gate, 720 seconds for bootstrap Git, and 60 seconds of supervisor grace; with 120 seconds each for setup and evidence, 1,080 seconds is strictly below its 20-minute deadline. Report jobs remain limited to 10 minutes. Authority-owned gate Git commands remain limited to 120 seconds each.
- Resolver, validator, authority Git, and the gate child run through the platform runtime's owned-process boundary: Windows uses a hidden process in an owned Job, Linux uses its process-group/subreaper boundary, and macOS uses an independent process group. Every child has an explicit deadline and verified descendant cleanup. Text capture is limited to 1,048,576 characters per stream; exceeding that bound fails the gate instead of accepting truncated output. Git byte-oriented calls use an owned capture helper to preserve undecoded stdout in create-only files before reading it back, with an explicit 2 GiB read bound; their bounded textual stderr still fails on the per-stream character limit.
- The pre-authority Git launcher cannot use the authority platform runtime before the authority has been authenticated. On Linux and macOS it therefore has no independent process group: it relies on `.NET` process-tree termination, the fixed command/phase deadlines, and disabled detached maintenance. This is a narrower best-effort cleanup boundary than the verified authority supervisor and must not be described as §8.4 process-group evidence.
