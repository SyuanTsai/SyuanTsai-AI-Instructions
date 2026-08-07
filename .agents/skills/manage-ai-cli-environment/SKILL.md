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

The installer copies `assets/environment-layer/` so the target repository receives `.ai/config.json`, six worker wrappers, `ai-login.ps1`, `ai-usage.ps1`, `ai-doctor.ps1`, provider-owned tool directories, and the common modules.

## Configure resources

Set `enabled` and `hardLimitPercent` independently for every resource. Set `unknownUsagePolicy` to `allow`, `warn`, or `deny`. Treat a null percentage as unknown, never as zero.

Keep credentials outside the repository. Copilot OAuth login is stored in the system credential store and is not isolated by `COPILOT_HOME`. The default config therefore allows the Company profile to use that stored credential and requires `AI_CLI_COPILOT_PERSONAL_TOKEN` for Personal. Set `authenticationMode` to `token` for any profile that must never fall back to the stored account. The wrappers map only the selected token to the child process and use separate `COPILOT_HOME` directories for config and state.

Run `./tools/ai-login.ps1 -ResourceName <name>` for every interactive login or account-setup flow. It opens a visible PowerShell 7 window, removes runner-only `TERM=dumb` state so native TUIs can initialize, gives the user complete control of the provider CLI, pauses before browser-based flows, waits for that window to finish, and then lets the caller resume verification. Do not drive the delegated TUI, preselect a browser or browser profile, infer an account from an existing browser session, or relay each provider choice through chat. The user chooses the account, browser context/profile, model, import, trust, and other provider options in that window; after it closes, verify the resource once.

Copilot Personal uses a dedicated secure token prompt in the delegated window and persists `AI_CLI_COPILOT_PERSONAL_TOKEN` in the user's environment; it must not run the shared OAuth login used by Company. Copilot Company must use `copilot login --device-code` so the terminal displays the URL and code and the user can open them in any browser/profile; do not use the default desktop web flow, which may open an already signed-in account. For Junie subscription access, the user chooses the intended JetBrains identity and verifies it with `/account`, then runs a minimal interactive task. For headless usage-based billing, generate a token at `https://junie.jetbrains.com/cli` and store it as `JUNIE_API_KEY`; documented provider variables are also supported for BYOK. Never pass credentials through chat, command history, repository files, or logs.

Keep interactive subscription readiness separate from headless readiness. Locally verified Junie CLI 26.8.3 can run an interactive JetBrains AI task after account OAuth, while the same stored account does not satisfy `--task`. The non-interactive wrapper therefore requires `JUNIE_API_KEY` or a documented BYOK variable and otherwise returns `headless_credential_required` with `authenticationAction: interactive_login_or_configure_headless_key` before spending a task call.

## Run the tooling

- Run `./tools/ai-usage.ps1` to probe all resources in parallel and write `.ai/usage-state.json`.
- Run `./tools/codex/get-usage.ps1` for a machine-readable Codex provider snapshot. It starts the official `codex app-server`, calls `account/rateLimits/read`, and returns independent `codexMain` and `codexSpark` states without reading or returning authentication tokens. Add `-ResourceName codexMain` or `-ResourceName codexSpark` to select one state.
- Use `./tools/codex/get-usage.ps1 -PrivateEndpoint -ResourceName <name>` only as an explicit compatibility path when app-server is unavailable and the user accepts reliance on the non-public ChatGPT `/wham/usage` endpoint. Never fall back to it silently.
- Run `./tools/codex/login.ps1` and `./tools/codex/doctor.ps1` for Codex-owned login and diagnostics. Login remains fully user-controlled in its delegated PowerShell window.
- Run `./tools/ai-usage.ps1 -InteractiveResourceName <name>` when the user wants to inspect provider-owned usage in the official CLI. It opens one visible PowerShell 7 window with the selected resource profile environment and leaves all commands and choices to the user. Codex and Junie instruct the user to run `/usage`; Copilot shows Plan quota in its status line and uses `/statusline` when quota is hidden; Agy can only show accessible models because its verified CLI has no usage command. Treat this path as human review: do not parse its terminal output or write a guessed percentage to `.ai/usage-state.json`.
- Run `./tools/ai-doctor.ps1` for explicit installed/version/auth/config diagnostics. Add `-Repair` only when interactive install or login is intended.
- Run `./tools/ai-login.ps1 -ResourceName <name>` when the user needs to own the complete setup or login interaction in a separate visible PowerShell.
- Run a worker wrapper with the provider's normal arguments, for example `./tools/codex-spark.ps1 exec "<task>"`.
- Add `-NoRepair` to a worker when it must return a structured install/auth error without opening an interactive repair flow.

Apply the hard-limit guard in the wrapper before task execution. Codex consumes its provider-owned app-server result; when a provider or a distinct Codex meter has no safe machine-readable quota source, enforce `unknownUsagePolicy` and return `usageKnown: false`.

## Preserve probe efficiency

Use the adapter's primary probe first. On success, do not run `Get-Command`, version, auth, or health checks. On failure, classify the error before diagnostic fallback. After install or login, retry only the primary probe.

Treat Copilot task execution as the optimistic auth probe because its verified CLI exposes no non-consuming machine-readable auth-and-quota command. For Junie, use an interactive task to verify stored JetBrains Account authentication, and use the requested non-interactive task only after headless credential evidence exists. Do not add a second AI call merely as preflight.

Read [provider-capabilities.md](references/provider-capabilities.md) before changing commands, parsers, install flows, login flows, account isolation, Spark verification, or Junie consumption-mode detection.

## Keep output and logs safe

Return standardized JSON reasons. Log only operational fields from the allowlist in `logging.ps1`; never log raw arguments, prompts, stdout/stderr, environment values, tokens, keys, or credentials. Pass delegated profile values through the child-process environment rather than its command line. Do not screen scrape interactive `/usage` output, Copilot status lines, or infer quota from plan names.
