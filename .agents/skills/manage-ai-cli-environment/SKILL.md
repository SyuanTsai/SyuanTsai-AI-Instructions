---
name: manage-ai-cli-environment
description: Install, configure, evaluate, refresh, diagnose, and safely execute global Codex Main, Codex Spark, GitHub Copilot Personal, GitHub Copilot Company, Google Antigravity (agy), and JetBrains Junie CLI resources. Use when Codex or GitHub Copilot needs a machine-wide Resource Guard, independent usage limits, isolated Copilot accounts, official login guidance, provider diagnostics, or enforced AI CLI execution without routing or repository dependencies.
---

# Manage AI CLI Environment

Manage one shared user/machine resource reality. Answer whether a specifically requested AI CLI resource may be used, and enforce that decision before execution. Keep goal planning, resource selection, routing, fallback, and multi-agent strategy outside this skill.

Read [global-resource-guard.md](references/global-resource-guard.md) before changing the guard contract, state schema, freshness policy, execution boundary, or install location. Read [provider-capabilities.md](references/provider-capabilities.md) before changing provider commands, usage acquisition, login, account isolation, or consumption-mode detection.

## Install the Global Resource Guard

1. Require PowerShell 7 or newer on Windows.
2. Run `scripts/install-global-ai-resource-guard.ps1` without a target to install under `%LOCALAPPDATA%\ai-resource-guard`.
3. Set the user or process variable `AI_RESOURCE_GUARD_HOME` to choose another global location. Use `-TargetRoot` only for controlled installation or testing.
4. Use `-Force` to refresh managed scripts. Reinstallation always preserves an existing `config.json`.

The installer creates `bin/`, `lib/`, `provider-tools/`, `state/resources/`, `profiles/`, and `logs/` under the global root. It must not inspect or modify the current Repository, create Repository-local `.ai/` or `tools/` files, or update `.gitignore`.

The older `scripts/install-ai-cli-environment.ps1 -TargetRoot <repository-root>` workflow is compatibility-only. Do not select it for new Global Resource Guard installations.

## Use lazy, resource-specific evaluation

Evaluate only when a Goal, Agent, Skill, Script, or orchestration layer is about to use a named resource:

```powershell
& "$env:LOCALAPPDATA\ai-resource-guard\bin\evaluate-resource.ps1" -ResourceName junie
```

`EvaluateResource(resource)` reads `config.json` and only `state/resources/<resource>.json`. It performs no CLI call, network request, usage refresh, scan of other resources, routing, or fallback. Missing, invalid, or stale state fails closed. A valid fresh state with unknown usage follows `unknownUsagePolicy` (`allow`, `warn`, or `deny`); null usage is never treated as zero.

Configure `enabled`, `hardLimitPercent`, optional per-resource `stateMaxAgeSeconds`, and optional per-resource `unknownUsagePolicy` independently. The hard limit is inclusive: `usedPercent >= hardLimitPercent` blocks the resource.

## Refresh usage state separately

The collector is independent from evaluation. Refresh exactly the resource whose reality needs updating:

```powershell
& "$env:LOCALAPPDATA\ai-resource-guard\bin\refresh-resource-state.ps1" -ResourceName codexMain
```

The collector invokes only that provider, normalizes readiness and usage, strips raw output and identity data, and atomically replaces `state/resources/<resource>.json`. It never evaluates policy or executes the requested AI task. Do not refresh every resource at Goal start.

Provider adapters declare usage acquisition as `official_api`, `provider_api`, `csv_import`, `interactive`, or `unsupported`. Only `usage.known: true` with a non-null `usedPercent` may drive the percentage hard limit. Amount-only data remains informational and must not become a guessed percentage.

For an administrator-provided JetBrains Central Console export, refresh Junie with explicit column mapping:

```powershell
& "$env:LOCALAPPDATA\ai-resource-guard\bin\refresh-resource-state.ps1" `
  -ResourceName junie `
  -JunieCentralConsoleCsvPath <csv> `
  -JunieUsedColumn <column> `
  -JunieLimitColumn <column>
```

Use the export as Junie quota only when its filtered scope is compatible. Otherwise treat it as informational combined JetBrains AI Credits.

## Enforce execution through the Guard

Run AI CLI work only through the execution entry point:

```powershell
& "$env:LOCALAPPDATA\ai-resource-guard\bin\execute-resource.ps1" `
  -ResourceName junie `
  -WorkingDirectory <working-directory> `
  -ResourceArguments @('review this change')
```

`ExecuteResource(resource, arguments)` calls evaluation internally. When unavailable, it returns a structured rejection and does not start the provider process. When available, it resolves the Guard-owned executable, mandatory model or mode prefix, profile environment, and then runs the CLI. Callers supply resource arguments, not an arbitrary executable. Codex Spark always receives `-m gpt-5.3-codex-spark`; Junie headless execution always receives `--task`.

Do not bypass this entry point after reading an evaluation result. The execution layer is the enforcement point, not an advisory message.

## Configure authentication outside repositories

Keep credentials in the system credential store, environment variables, or other global user configuration. Never put them in the Guard state, Repository files, chat, command history, or logs.

Copilot OAuth login is stored in the system credential store and is not isolated by `COPILOT_HOME`. The default Company profile may use that stored credential. Personal requires a dedicated token under `ai-cli/copilot/personal` in Windows Credential Manager; `AI_CLI_COPILOT_PERSONAL_TOKEN` is a read-only migration fallback. Set `authenticationMode: token` for any profile that must not fall back to the stored account. The child wrapper removes inherited `GH_TOKEN` and `GITHUB_TOKEN`, maps only the selected token, and uses separate global profile directories.

Use the provider-owned login scripts under `<global-root>/provider-tools/`. Login opens a visible PowerShell window and leaves account, browser profile, model, import, trust, and other provider choices to the user. Copilot Personal uses its secure token prompt. Copilot Company uses `copilot login --device-code`. Junie subscription access is interactive; headless `--task` requires `JUNIE_API_KEY` or a documented BYOK variable.

## Preserve safe boundaries

- Return standardized structured reasons such as `resource_state_missing`, `resource_state_stale`, `resource_hard_limit_reached`, and `usage_unknown`.
- Keep evaluation read-only and deterministic for the selected state snapshot.
- Do not infer quota from installation, authentication, plan names, accessible models, or a non-null amount.
- Do not parse interactive `/usage`, TUI output, Copilot status lines, or terminal screens.
- Log only operational allowlisted fields; never log prompts, arguments, stdout/stderr, environment values, tokens, keys, account identifiers, or raw provider responses.
- If a resource is unavailable, return the reason to the caller. Another orchestration layer may choose a fallback, but this skill must not choose one.
