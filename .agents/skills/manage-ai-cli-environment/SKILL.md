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

The installer copies `assets/environment-layer/` so the target repository receives `.ai/config.json`, six worker wrappers, `ai-login.ps1`, `ai-usage.ps1`, `ai-doctor.ps1`, and the common modules.

## Configure resources

Set `enabled` and `hardLimitPercent` independently for every resource. Set `unknownUsagePolicy` to `allow`, `warn`, or `deny`. Treat a null percentage as unknown, never as zero.

Keep credentials outside the repository. Copilot OAuth login is stored in the system credential store and is not isolated by `COPILOT_HOME`. The default config therefore allows the Company profile to use that stored credential and requires `AI_CLI_COPILOT_PERSONAL_TOKEN` for Personal. Set `authenticationMode` to `token` for any profile that must never fall back to the stored account. The wrappers map only the selected token to the child process and use separate `COPILOT_HOME` directories for config and state.

Run `./tools/ai-login.ps1 -ResourceName <name>` for every interactive login or account-setup flow. It opens a visible PowerShell 7 window, gives the user complete control of the provider CLI, waits for that window to finish, and then lets the caller resume verification. Do not drive the delegated TUI, preselect a browser or browser profile, infer an account from an existing browser session, or relay each provider choice through chat. The user chooses the account, browser context/profile, model, import, trust, and other provider options in that window; after it closes, verify the resource once.

Copilot Personal uses a dedicated secure token prompt in the delegated window and persists `AI_CLI_COPILOT_PERSONAL_TOKEN` in the user's environment; it must not run the shared OAuth login used by Company. For Junie subscription access, the user chooses the intended JetBrains identity and verifies it with `/account`, then runs a minimal interactive task. For headless usage-based billing, generate a token at `https://junie.jetbrains.com/cli` and store it as `JUNIE_API_KEY`; documented provider variables are also supported for BYOK. Never pass credentials through chat, command history, repository files, or logs.

Keep interactive subscription readiness separate from headless readiness. Locally verified Junie CLI 26.8.3 can run an interactive JetBrains AI task after account OAuth, while the same stored account does not satisfy `--task`. The non-interactive wrapper therefore requires `JUNIE_API_KEY` or a documented BYOK variable and otherwise returns `headless_credential_required` with `authenticationAction: interactive_login_or_configure_headless_key` before spending a task call.

## Run the tooling

- Run `./tools/ai-usage.ps1` to probe all resources in parallel and write `.ai/usage-state.json`.
- Run `./tools/ai-doctor.ps1` for explicit installed/version/auth/config diagnostics. Add `-Repair` only when interactive install or login is intended.
- Run `./tools/ai-login.ps1 -ResourceName <name>` when the user needs to own the complete setup or login interaction in a separate visible PowerShell.
- Run a worker wrapper with the provider's normal arguments, for example `./tools/codex-spark.ps1 exec "<task>"`.
- Add `-NoRepair` to a worker when it must return a structured install/auth error without opening an interactive repair flow.

Apply the hard-limit guard in the wrapper before task execution. When a provider has no safe machine-readable quota source, enforce `unknownUsagePolicy` and return `usageKnown: false`.

## Preserve probe efficiency

Use the adapter's primary probe first. On success, do not run `Get-Command`, version, auth, or health checks. On failure, classify the error before diagnostic fallback. After install or login, retry only the primary probe.

Treat Copilot task execution as the optimistic auth probe because its verified CLI exposes no non-consuming machine-readable auth-and-quota command. For Junie, use an interactive task to verify stored JetBrains Account authentication, and use the requested non-interactive task only after headless credential evidence exists. Do not add a second AI call merely as preflight.

Read [provider-capabilities.md](references/provider-capabilities.md) before changing commands, parsers, install flows, login flows, account isolation, Spark verification, or Junie consumption-mode detection.

## Keep output and logs safe

Return standardized JSON reasons. Log only operational fields from the allowlist in `logging.ps1`; never log raw arguments, prompts, stdout/stderr, environment values, tokens, keys, or credentials. Do not screen scrape interactive `/usage` output or infer quota from plan names.
