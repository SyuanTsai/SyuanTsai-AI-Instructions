---
name: manage-ai-cli-environment
description: Install, configure, probe, diagnose, and safely invoke Codex Main, Codex Spark, GitHub Copilot Personal, GitHub Copilot Company, Google Antigravity (agy), and JetBrains Junie CLI resources. Use when Codex or GitHub Copilot needs to answer whether one of these AI CLI resources is currently usable, enforce independent usage limits, isolate Copilot accounts, bootstrap a missing CLI, guide official login, refresh usage-state.json, or run ai-doctor without adding routing or orchestration.
---

# Manage AI CLI Environment

Manage resource reality only: determine whether a named AI CLI resource can run and explain why it cannot. Keep routing, fallback, task classification, and multi-agent strategy out of this layer.

## Install the environment layer

1. Require PowerShell 7 or newer on Windows.
2. Run `scripts/install-ai-cli-environment.ps1 -TargetRoot <repository-root>`.
3. Preserve an existing `.ai/config.json`; pass `-Force` only to refresh managed tool scripts.
4. Keep `.ai/logs/`, `.ai/usage-state.json`, and any profile state ignored by Git.

The installer copies `assets/environment-layer/` so the target repository receives `.ai/config.json`, six worker wrappers, `ai-usage.ps1`, `ai-doctor.ps1`, and the common modules.

## Configure resources

Set `enabled` and `hardLimitPercent` independently for every resource. Set `unknownUsagePolicy` to `allow`, `warn`, or `deny`. Treat a null percentage as unknown, never as zero.

Keep credentials outside the repository. For strict Copilot account isolation, set `AI_CLI_COPILOT_PERSONAL_TOKEN` and `AI_CLI_COPILOT_COMPANY_TOKEN` in the user environment. The wrappers map only the selected token to the child process and also use separate `COPILOT_HOME` directories under the local AI CLI state root.

## Run the tooling

- Run `./tools/ai-usage.ps1` to probe all resources in parallel and write `.ai/usage-state.json`.
- Run `./tools/ai-doctor.ps1` for explicit installed/version/auth/config diagnostics. Add `-Repair` only when interactive install or login is intended.
- Run a worker wrapper with the provider's normal arguments, for example `./tools/codex-spark.ps1 exec "<task>"`.
- Add `-NoRepair` to a worker when it must return a structured install/auth error without opening an interactive repair flow.

Apply the hard-limit guard in the wrapper before task execution. When a provider has no safe machine-readable quota source, enforce `unknownUsagePolicy` and return `usageKnown: false`.

## Preserve probe efficiency

Use the adapter's primary probe first. On success, do not run `Get-Command`, version, auth, or health checks. On failure, classify the error before diagnostic fallback. After install or login, retry only the primary probe.

Treat Copilot and Junie task execution as the optimistic auth probe because their verified CLIs expose no non-consuming machine-readable auth-and-quota command. Do not add a second AI call merely as preflight.

Read [provider-capabilities.md](references/provider-capabilities.md) before changing commands, parsers, install flows, login flows, account isolation, Spark verification, or Junie consumption-mode detection.

## Keep output and logs safe

Return standardized JSON reasons. Log only operational fields from the allowlist in `logging.ps1`; never log raw arguments, prompts, stdout/stderr, environment values, tokens, keys, or credentials. Do not screen scrape interactive `/usage` output or infer quota from plan names.
