# External Research Rules

## Data and Query Boundary

- Start with evidence already present in the current conversation, repository, and local files. Use an external search provider only when freshness, multi-source exploration, multilingual search, or unknown authoritative-source location adds value. <!-- ai-invariant:external-research.local-first -->
- Send an external provider only a neutral public query that stands on its own. Never send repository content, code, diffs, tests, logs, stack traces, internal documents, customer data, credentials, unpublished names, or other private content. <!-- ai-invariant:external-research.public-query-boundary -->
- When a meaningful query requires private content, use local tools or an approved internal source. In software work, search only for public external facts that can be separated from the code; determine code impact from repository evidence. <!-- ai-invariant:external-research.private-content-boundary -->

## Source Selection and Verification

- Use a known authoritative page directly when it can answer the question by itself. Verify high-risk legal, contractual, security, medical, or financial conclusions against authoritative original text; never treat a search summary as final authority. <!-- ai-invariant:external-research.authoritative-verification -->
- Keep responsibility for whether to trust, further verify, or use a result with the calling agent. An external provider performs only search and preliminary synthesis.
- A self-managed CLI or third-party provider adapter must receive results through a validated compact wrapper that filters raw stdout, stderr, internal identifiers, query analysis, duplicate sources, and excess sources. A platform-managed connector or native web search may return structured identifiers and snippets internally under the host contract. Do not return raw logs or private metadata to the user; use snippets only for initial triage and open and verify every source relied upon for a conclusion. <!-- ai-invariant:external-research.adapter-output-boundary -->

## Failure Handling

- When the external provider fails, prefer a suitable already-approved connector. When none is suitable, use the platform's native web-search capability. <!-- ai-invariant:external-research.approved-fallback -->
- Report that current verification is unavailable only when both fallbacks fail. Never relax the data boundary or send private content merely to complete the search. <!-- ai-invariant:external-research.fallback-preserves-boundary -->
