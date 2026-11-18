---
name: fixture
description: Use when an agent needs to validate, test, or verify the authority-owned consumer transition end-to-end probe with a minimal Skill package.
---

# Consumer transition fixture

Use this package only to verify the authority-owned consumer transition gate. Keep the fixture deterministic and confined to the generated probe repository.

## Procedure

1. Confirm that the generated candidate contains this Skill and the expected repository checks.
2. Run the authority-owned prepare, validate, and finalize phases in order.
3. Inspect the formal validation evidence and require a passing release-eligible result.
4. Preserve the leg receipt, diagnostics, and validation artifacts for the aggregate job.

## Example

```text
Validate the consumer transition fixture and preserve its gate evidence.
```

Expected result: all production validators inspect the fixture, the candidate-owned Pester case passes, and finalize writes one platform receipt.

## Failure handling

If validation fails, preserve the generated diagnostics and return the failure without bypassing the gate. Do not replace the resolver, validator, adapter, or repository check with a stub. Treat missing evidence, incomplete tool output, and unexpected fixture files as failures.
