# Provider capabilities

Verified against local `--help` where executable access was available and official documentation on 2026-08-07. Re-check the linked official documentation before changing an adapter because CLI surfaces and billing models evolve.

## Capability matrix

| Resource | Daily primary probe | What it verifies | Machine-readable account usage | Install | Login |
| --- | --- | --- | --- | --- | --- |
| Codex Main | `codex login status` | CLI start and active authentication mode | Unsupported; `/usage` is interactive | `npm install --global @openai/codex` | `codex login` |
| Codex Spark | `codex login status`, then the requested task with `-m gpt-5.3-codex-spark` | CLI/auth first; actual task verifies account model access | Unsupported; `/usage` is interactive | Same as Codex Main | `codex login` |
| Copilot Personal | Requested task under the personal profile | CLI, selected account authentication, and entitlement | Unsupported by the CLI; `/usage` is interactive/session-scoped | `winget install GitHub.Copilot` | `copilot login` under personal `COPILOT_HOME` |
| Copilot Company | Requested task under the company profile | CLI, selected account authentication, and entitlement | Unsupported by the CLI; organization billing API needs separate permissions and does not by itself supply this wrapper's quota denominator | Same as Copilot Personal | `copilot login` under company `COPILOT_HOME` |
| Agy | `agy models` | CLI, Google authentication, and available model list | Unsupported by the verified CLI | Official Antigravity PowerShell installer | Start `agy` and complete the official browser flow |
| Junie | Requested task; `junie --version` in usage/doctor diagnostics | Actual task verifies CLI/auth; version verifies executable only | Unsupported; `/usage` is session cost, not account quota | Official Junie PowerShell installer | Start `junie` and choose an official authentication option |

No listed daily probe currently returns a reliable account `usedPercent`. Keep the default `usageSource` as `unsupported` and return UNKNOWN until an official machine-readable source supplies both current usage and a compatible limit.

## Provider-specific rules

### Codex

- Use `codex login status` as the non-interactive auth probe.
- Do not parse TUI `/usage`; official documentation describes it as an interactive menu/action.
- Keep Main and Spark as separate resource states and hard limits even when they share CLI authentication.
- Force `gpt-5.3-codex-spark` in the Spark wrapper. Mark `modelAvailable: true` only after a real Spark task succeeds; classify an explicit provider model error as `model_unavailable`. Leave it null in non-consuming status reports.

Official sources:

- https://learn.chatgpt.com/docs/developer-commands?surface=cli
- https://learn.chatgpt.com/docs/auth
- https://learn.chatgpt.com/docs/models

### GitHub Copilot

- Use separate `COPILOT_HOME` values for personal and company state.
- Prefer separate user environment token names for deterministic automation; map only the selected value to `COPILOT_GITHUB_TOKEN` in the child process.
- Do not use `/user switch` as the daily isolation mechanism.
- Do not parse `/usage`, the footer, or status line. Add an official billing API only when the caller provides scoped credentials, account scope, and a compatible quota denominator outside version control.

Official sources:

- https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference
- https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli
- https://docs.github.com/en/rest/billing/usage

### Google Antigravity

- Use `agy models`; local help describes it as the available-model command, and its failure distinguishes missing authentication.
- Treat model-list success as CLI/auth/account readiness, not as quota knowledge.
- Use the official Windows installer only after `command_not_found`.

Official sources:

- https://antigravity.google/docs/cli-install
- https://antigravity.google/docs/cli/features

### JetBrains Junie

- Use task execution as the optimistic auth probe; avoid a paid no-op preflight.
- Mark `byok` verified only when a documented `JUNIE_*_API_KEY` provider variable is present.
- Mark `jetbrains-ai` verified when `JUNIE_API_KEY` is present. Otherwise keep consumption mode unknown; a stored interactive login or custom config cannot be distinguished safely without task/config evidence.
- Do not treat session `/usage` as account quota.

Official sources:

- https://junie.jetbrains.com/docs/junie-cli.html
- https://junie.jetbrains.com/docs/parameters.html
- https://junie.jetbrains.com/docs/environment-variables.html
