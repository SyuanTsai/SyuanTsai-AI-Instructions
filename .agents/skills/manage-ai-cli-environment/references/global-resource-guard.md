# Global AI Resource Guard contract

The Global AI Resource Guard is a user/machine execution layer shared by Codex, Agents, Skills, Goals, scripts, and future orchestration. It does not belong to the current Repository and does not require Repository-local files.

## Design boundaries

| Principle | Required behavior |
| --- | --- |
| Global | Resolve one user/machine root from `AI_RESOURCE_GUARD_HOME` or `%LOCALAPPDATA%\ai-resource-guard`. |
| Lazy | Do nothing until a caller requests one named resource. |
| Goal-triggered | Evaluate immediately before the Goal needs the resource, not at Goal startup. |
| Resource-specific | Read or refresh only the requested resource. |
| No Repository dependency | Never require or create `<repository>/.ai/` or `<repository>/tools/`. |
| No usage collection in evaluation | Evaluation reads a previously persisted snapshot and never invokes provider tools. |
| Hard-limit enforcement | Execution must call evaluation internally and block the provider process on rejection. |
| Structured result | Return stable fields and machine-readable reasons. |

Routing and fallback are intentionally absent. A future orchestrator may request another resource after a rejection, but the Guard never selects it.

## Installed layout

```text
<global-root>/
├─ config.json
├─ bin/
│  ├─ evaluate-resource.ps1
│  ├─ execute-resource.ps1
│  └─ refresh-resource-state.ps1
├─ lib/
├─ provider-tools/
├─ state/resources/<resource>.json
├─ profiles/
└─ logs/
```

`AI_RESOURCE_GUARD_HOME` is checked in process scope and then user scope. When absent, the root is `%LOCALAPPDATA%\ai-resource-guard`.

Supported names are `codexMain`, `codexSpark`, `copilotPersonal`, `copilotCompany`, `agy`, and `junie`.

## Configuration contract

```json
{
  "schemaVersion": 1,
  "unknownUsagePolicy": "warn",
  "stateMaxAgeSeconds": 900,
  "probeTimeoutSeconds": 30,
  "commandTimeoutSeconds": 86400,
  "resources": {
    "junie": {
      "enabled": true,
      "hardLimitPercent": 90,
      "stateMaxAgeSeconds": 600,
      "unknownUsagePolicy": "deny"
    }
  }
}
```

Per-resource freshness and unknown-usage values override global defaults. `hardLimitPercent` is applied inclusively. Disabling a resource always rejects it.

## Persisted state contract

Each resource owns one independently replaceable file:

```json
{
  "schemaVersion": 1,
  "resource": "junie",
  "updatedAt": "2026-08-08T12:00:00.0000000+08:00",
  "readiness": {
    "known": true,
    "available": true,
    "cliReady": true,
    "authenticationReady": true,
    "reason": null
  },
  "usage": {
    "provider": "junie",
    "source": "jetbrains-central-console",
    "acquisitionMode": "csv_import",
    "machineReadable": true,
    "queriedAt": "2026-08-08T12:00:00.0000000+08:00",
    "known": true,
    "usageAmountKnown": true,
    "limitAmountKnown": true,
    "remainingAmountKnown": true,
    "usedPercent": 40,
    "remainingPercent": 60,
    "usedQuantity": 40,
    "limitQuantity": 100,
    "remainingQuantity": 60,
    "unitType": "ai_credits",
    "scope": "junie",
    "unlimited": false,
    "reason": null,
    "actions": []
  }
}
```

The collector writes a temporary file in the same state directory and atomically moves it over the destination. State must not contain prompts, command arguments, stdout/stderr, tokens, headers, raw provider payloads, source CSV rows, email addresses, account IDs, or tenant identifiers.

## Evaluation contract

Conceptual interface:

```text
EvaluateResource(resource) -> ResourceEvaluation
```

Result shape:

```json
{
  "resource": "junie",
  "available": true,
  "reason": null,
  "warning": null,
  "usageKnown": true,
  "usedPercent": 40,
  "hardLimitPercent": 90,
  "stateUpdatedAt": "2026-08-08T12:00:00.0000000+08:00",
  "stateAgeSeconds": 30
}
```

Evaluation order:

1. Validate global configuration and the selected resource policy.
2. Reject a disabled resource.
3. Read only `state/resources/<resource>.json`.
4. Reject missing, malformed, mismatched, or stale state.
5. Reject unknown readiness or a known readiness failure.
6. Reject when known `usedPercent` is greater than or equal to the hard limit.
7. Apply `unknownUsagePolicy` only to a valid fresh state whose usage percentage is unknown.
8. Allow otherwise.

Important rejection reasons are `configuration_missing`, `configuration_invalid`, `resource_disabled`, `resource_state_missing`, `resource_state_invalid`, `resource_state_stale`, `resource_readiness_unknown`, `resource_not_ready`, `resource_hard_limit_reached`, and `usage_unknown`. A provider readiness reason may be returned when it is already present in state.

`warn` allows unknown usage and returns `warning: usage_unknown`. `allow` permits it without a warning. `deny` rejects it with `reason: usage_unknown`. Missing or stale state never becomes an unknown-usage allow case.

## Execution contract

Conceptual interface:

```text
ExecuteResource(resource, resourceArguments, workingDirectory) -> ResourceExecution
```

The execution layer evaluates internally on every invocation. It must not start a process when evaluation rejects. The provider executable and mandatory arguments are Guard-owned mappings; callers cannot inject a different executable through the public entry point.

Successful result:

```json
{
  "resource": "junie",
  "success": true,
  "executed": true,
  "reason": null,
  "evaluation": { "available": true },
  "exitCode": 0,
  "result": "provider output"
}
```

Rejected execution returns `success: false`, `executed: false`, the evaluation reason, a null exit code, and no provider result. Provider nonzero exit returns `success: false`, `executed: true`, its exit code, and a classified reason such as `provider_error`, `authentication_required`, or `permission_denied`.

## Collector contract

Conceptual interface:

```text
RefreshResourceState(resource) -> PersistedResourceState
```

The collector is a separate mechanism. It may invoke the selected provider's official or explicitly approved usage source, but it must not evaluate policy, execute the Goal's task, or refresh other resources. Scheduling or deciding when to refresh belongs to the caller or a future orchestration layer.
