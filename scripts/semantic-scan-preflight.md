# Semantic scan preflight interface (SYP-220)

`Prepare-StandardSemanticScanEvidence.ps1` prepares an **unsigned, non-release**
artifact between a versioned semantic scanner adapter and a protected supervisor.
It does not call an LLM, obtain consent, validate installed analyzer inventory, sign
an attestation, or invoke the canonical Standard v1 runner. Its output has
`preflightType=semantic-scan-preflight-v1`, `consentStatus=pending`, `signed=false`,
`analyzerInventoryVerified=false`, and `releaseEligible=false`; the canonical
semantic receipt verifier rejects it.

The normative boundary is defined by `docs/standards/skill-repository-standard.md`
and `docs/standards/validation-security-gate.json`. Provider text must equal the
strict UTF-8 decoding of verified candidate source bytes. A stale or substituted
text cache fails before the provider result can inherit the candidate identity.

## Trusted caller inputs

The protected supervisor must get `CandidateId` and `InputInventorySha256` from
**verified candidate acquisition**, not from a candidate-provided JSON file.
It must get `ExpectedActiveSkills` from that candidate's complete active Skill
inventory and `ExpectedAnalyzerIds` from the **resolved, installed** scanner's
actual semantic analyzer inventory. This helper compares those inputs with the
scanner result, but it cannot authenticate their origins. It reports
`analyzerCompleteness=declared-set-complete` for that reason.

The scanner adapter writes one machine-readable UTF-8 JSON result outside the
source checkout. Its exact input shape is:

```json
{
  "schemaVersion": 1,
  "resultType": "standard-semantic-scan-result-v1",
  "candidateId": "<64 lowercase hex>",
  "inputInventorySha256": "<64 lowercase hex>",
  "provider": "<actual provider>",
  "purpose": "<approved purpose>",
  "scope": "<approved input scope>",
  "activeSkills": ["alpha-skill"],
  "analyzers": [
    {
      "identity": "semantic-intent",
      "status": "passed",
      "completeness": "complete",
      "coveredSkills": ["alpha-skill"],
      "findings": []
    }
  ]
}
```

Every required analyzer must report `passed`, `complete`, and the exact active
Skill set. The helper rejects unknown/duplicate JSON properties, missing or
extra analyzer identities, wrong candidate/inventory/provider/purpose/scope,
partial Skill coverage, unknown finding severity, unsupported finding fields,
and reparse files or parent paths. It reads and hashes the same exclusively
opened scanner file, then creates the output file once outside the authority
source tree. Findings are
kept in declared analyzer order and hashed using the canonical Standard
`findings` JSON bytes. High/Critical findings are retained with
`severityGate=blocked`; Medium findings get `severityGate=human-review`.

For the inspected SkillSpector 2.11.2 implementation, the scanner adapter must
compare **registered, graph-wired, and actually completed** semantic analyzers
for the frozen installed tool version. Its graph is wired at import time and
skips API-key analyzers when the provider is unavailable; a static-only graph
can honestly report global `analysis_completeness=complete` with no semantic
nodes executed. A fresh tool process and a check of per-analyzer work/LLM call
records are required after provider availability changes. The public JSON
report's `issues` array can be deduplicated, baseline-suppressed, and bounded;
it is not the raw complete semantic finding set. Derive this input from the
versioned graph's raw findings and emitted-finding ledger, with no unaccounted
or truncated result, then leave this helper's output unsigned until a protected
supervisor authenticates it.

`Inspect-InstalledSemanticScanner.py` is an earlier **pre-scan** probe. Run it
inside the resolver's isolated SkillSpector Python venv with its frozen
`--expected-version` and an output path outside this checkout. It hashes the
installed semantic module sources and compares the dynamically registered IDs
with nodes actually wired into the graph. The ordinary command returns a
nonzero result when a registered node was skipped; `--observe-only` preserves
an explicitly unready diagnostic. Its output always says `scanExecuted=false`,
`analyzerCoverageVerified=false`, `consentStatus=pending`, `signed=false`, and
`releaseEligible=false`. It cannot prove a completed analyzer invocation,
provider data scope, user consent, or a signer, and the formal semantic verifier
does not accept it. The future protected supervisor must restart this frozen
tool process if provider availability changes, then verify the subsequent raw
graph ledger before producing the normalized scanner input above.

`Normalize-InstalledSemanticGraph.py` is the next **unsigned, pure** adapter.
After a protected invocation has one raw graph state for every active Skill,
call `normalize_candidate_scan` with the candidate/inventory identities,
provider/purpose/scope, exact registered and graph-wired semantic IDs, and
the map of Skill IDs to those raw states. It also requires the protected
caller to provide one expected immutable package directory and complete
per-file committed byte SHA-256/length manifest for every active Skill.
It compares each graph's `input_path` and `skill_path` with that package,
rejects linked paths and extra/missing package files, and checks that both
the graph's raw byte cache **and** LLM-applicable file paths cover exactly
the reviewed manifest. The protected supervisor must still authenticate
the archive/acquisition and these caller inputs; this check cannot sign
itself or attest the provider's exact outbound prompt bytes. It rejects an
unwired node, global
`complete` without per-analyzer completed status, missing/partial/duplicate
planned work, gaps between completed file chunks, failed or missing provider
calls, output bounds, missing or ambiguous raw finding producer IDs, and a
missing active Skill graph. It maps every attributed semantic finding into
the existing scanner-result JSON shape, preserving one record per finding;
the **raw Finding objects and full ledger must also be retained** by the
protected supervisor for audit. The normalized fields are a bounded review
projection, and this helper does not authenticate the caller's metadata,
execute an LLM, prove consent, or sign a receipt. The synthetic interface
test passes its output through the unsigned preflight; an installed
SkillSpector 2.11.2 `no_llm` graph is rejected even while global static
completeness says `complete`.

## Remaining production bridge

The future protected producer must authenticate the actual scanner invocation,
resolved analyzer inventory, input-path scope, explicit user consent and
protected signer identity. The current canonical semantic receipt uses a
**scalar** `analyzerIdentity`, while this preflight records the complete
declared analyzer ID array. The producer must derive and authenticate one
stable identity for that exact resolved analyzer set; simply copying a single
ID or treating the caller-declared array as verified would lose coverage.
It must sign a fresh candidate-bound semantic
attestation with the central trust anchor's legitimate private key, then pass
the full receipt to `Invoke-StandardValidation.ps1` together with verified
source, authority, tool and launch receipts. A synthetic test key or a copied
preflight cannot supply those receipts. Signed AI Review, independent Human
Release Approval, publication and post-install verification remain later Gates.
