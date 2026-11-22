# Revoked validation trust anchors

The following historical production trust anchors were revoked on 2026-11-20 because custody of their corresponding private keys is unknown:

- `trusted-supervisor-public-key.xml` (`supervisor`)
- `human-approval-public-key.xml` (`humanApproval`)

The public-key files and their pinned SHA-256 values are retained unchanged as audit records. They are not valid for new signatures and must not be deleted or treated as active trust anchors.

There is currently no active production trust anchor. The historical v1 `-CompleteLifecycle` route is therefore always `BLOCKED` before signature verification until a new trust anchor is established. Development-harness public keys remain test-only, caller-owned fixtures and cannot authorize production or release.

The user must personally generate and retain custody of any replacement key. Replacement-key generation, custody, activation, and rotation are outside the SYP-350 scope and require a separately reviewed trust-boundary change.
