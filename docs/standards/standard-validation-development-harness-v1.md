# Standard v1 CI1 Development Harness

This document describes the non-production harness used to obtain CI1 behavior evidence. It is not a release gate, a formal authority adoption, or a substitute for `Invoke-StandardAuthorityGate.ps1`.

## Trust boundary

`scripts/Invoke-StandardValidationDevelopmentHarness.ps1` has three deliberately separate roles:

1. The central `Invoke-StandardValidation.ps1` is the independent pre-candidate oracle. It runs in `-DevelopmentHarness` mode and owns the `controlled-acquisition` → `integrity-verification` → `package-validation` → `skillspector-static` → `repository-tests` order.
2. The adapter and harmless tool fixtures are supplied outside the candidate and artifact roots. The harness rejects reparse roots, overlapping roots, unsafe paths, changed source or adapter bytes, and a barrier that is not a development-only `PASS` with `releaseEligible=false`.
3. Only after that barrier passes, the harness copies the candidate to an external run-owned snapshot and invokes the candidate's adapter-declared `canonicalValidatorPath` through the same central process-containment primitive. The source checkout is never used as the candidate execution directory.

The evidence records the central runner and process-host hashes, candidate identity, barrier evidence hash, candidate execution result, bounded child output, and fail-closed recovery state. The authority is intentionally labelled `local-development-only-unpinned`; `candidateIsTrustRoot=false`, `releaseEligible=false`, and `formalAdoption=not-authorized` are invariant results of this entry point. Network isolation is not claimed by the harness, so fixtures must not depend on network access.

## Invocation contract

The caller supplies a candidate checkout, a development-harness adapter, a trusted tool root, and an artifact root that is external to the candidate. Candidate validator arguments may use `__CANDIDATE_ROOT__`; the harness substitutes the immutable snapshot path. Parent-directory traversal, artifact-root exposure, and other absolute paths are rejected.

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File scripts/Invoke-StandardValidationDevelopmentHarness.ps1 `
  -CandidateRoot <candidate-root> `
  -AdapterPath <development-adapter.json> `
  -TrustedToolRoot <trusted-tool-root> `
  -CandidateValidatorPath scripts/Validate.ps1 `
  -ArtifactsRoot <external-artifacts-root> `
  -OutputPath <external-artifacts-root>/ci1-evidence.json `
  -SourceRepository https://example.invalid/example/skills.git `
  -SourceRevision <40-hex-source-revision> `
  -BaseRevision <40-hex-base-revision> `
  -EventName local `
  -ValidatorArguments __CANDIDATE_ROOT__
```

The normal `TimeoutSeconds` bounds the central barrier. `CandidateTimeoutSeconds` is optional and exists to exercise candidate timeout behavior independently; when omitted it uses the same bound. A timeout, cancellation, startup failure, cleanup failure, mutation, or nonzero candidate result is never promoted to `PASS`.

## Formal adoption remains a separate gate

The harness does not perform production wiring. Formal adoption still requires an immutable authority archive and file inventory, an independently trusted launcher and expected-head binding, the approved CI event/context, native Linux isolation evidence, required reviews and security findings closure, and any separately approved ruleset or release change. Until those conditions are independently satisfied, this harness can provide development evidence only.

## Regression coverage

`tests/standard-validation-development-harness.Tests.ps1` covers:

- successful barrier-before-candidate execution and canonical first-five stage order;
- failed Static barrier with no candidate dispatch;
- candidate snapshot mutation and candidate timeout fail-closed behavior; and
- unsafe argument rejection before candidate execution.

The tests also verify that inherited secret-shaped environment variables are not visible to either owned child process.
