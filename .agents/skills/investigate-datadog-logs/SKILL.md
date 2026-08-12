---
name: investigate-datadog-logs
description: Investigate errors, incidents, logs, and traces through a configured Datadog purpose-built connector. Use when a user provides a Datadog URL, asks to search error logs, needs log counts or trends, wants logs correlated with APM traces, or investigates an incident backed by Datadog telemetry.
---

# Investigate Datadog Logs

## Establish Scope

1. Read the Datadog connector's built-in Skill or usage guide in full before calling its tools. If no guide is exposed, inspect the available Datadog connector tool descriptions and report that limitation.
2. Extract the exact time range, filters, query text, service, environment, identifiers, grouping, and timezone from the user's request and any Datadog URL. Treat explicit URL state as part of the requested scope; preserve encoded filters and time semantics instead of silently broadening or replacing them.
3. Do not infer a service, environment, or time range. Ask for any missing value that is required to run a meaningful query, while retaining every condition already supplied.

## Choose the Query Path

Use the configured Datadog connector before any general-purpose Browser tool. A Datadog URL is query input, not by itself a reason to operate the web UI.

- Use raw log search for individual events, exact messages, stack traces, request or correlation identifiers, and field-level inspection.
- Use log aggregation for counts, trends, distributions, group-by analysis, and top values. Use it first when the question is about frequency or change over time, then inspect representative raw events when needed.
- Use APM trace search or trace inspection for trace or span identifiers, latency, dependency paths, failing spans, and log-trace correlation.
- Combine these paths only when the investigation requires it, carrying the same service, environment, time range, and identifiers between queries.

Keep queries bounded and request only the fields and samples needed to answer the question. Follow the connector guide's query syntax rather than guessing unsupported filters.

## Fallback Safely

Use a Browser only when the Datadog connector is unavailable, unauthorized, or does not support the required operation, or when the user explicitly asks to interact with the Datadog UI. State the connector limitation before falling back. Preserve the original URL filters and time range, use an existing authorized session, and do not substitute a different Datadog site or dataset.

If neither path can access the requested scope, stop and report the missing access or unsupported operation instead of inventing results.

## Report Findings

Summarize the effective time range, filters, service and environment when supplied, query path, evidence, and remaining uncertainty. Redact credentials and sensitive URL parameters, and distinguish observed data from inferences.
