# SYP-20 source delivery; SYP-259 deployment input

SYP-20 delivers the environment-authorized SQL Skill, strict authorization/request/response contracts, workflow/policy/installation documents, offline cases, complete source validation and normal source PR merge. Per the user's 2026-10-08 scope decision, SYP-259 owns real installation and discovery/load acceptance, and integrates deployment inputs through its existing one-time USER-scope rollout. Deployment remaining here does not reopen SYP-20 source delivery.

## Fixed source and verification

- Source: [Skill-General PR33](https://github.com/SyuanTsai/Skill-General/pull/33), merged normally.
- Reviewed/tested head: `b55665174fc4ab02d8cd941348fb4e0394042aec`.
- Final merge: `191db6b3380eee697285dc5a4e3a3390ec8379c3`; tree `8117924a1edb9045d442cb1ae97145ec48dfcf7a` is identical to the head. All83 regular-file bytes of the merged archive were compared with the verified head archive and matched.
- [Immutable merged archive](https://codeload.github.com/SyuanTsai/Skill-General/legacy.zip/191db6b3380eee697285dc5a4e3a3390ec8379c3), SHA256 `1cd51e97f3e80c12e5933e04118b6bc834e1435cf3446c6fa12c6da7d8c6e784`.
- Skill ID `operate-environment-authorized-sql`; source path `skills/operate-environment-authorized-sql`; consumer target `.agents/skills/operate-environment-authorized-sql`; central content SHA256 `89586f3808e86b676d53d2d880af9b5f7b382d212b1edb210c5f1f6fcf77be91`.
- [Canonical source CI37636532090](https://github.com/SyuanTsai/Skill-General/actions/runs/37636532090): 7 active packages/14 SV-ST/21 native reports, 37 complete Static/no-LLM files, full17 Pester files/290PASS with no skips or not-run cases. The original report remains bound to head b556 and reports `releaseEligible=false`; tree/archive equality is separate merge binding evidence.
- Offline SQL contracts: 13/13 PASS. Actual SQL execution, AST enforcement, OS isolation, login and24 later runtime acceptance cases are not claimed.

## Central candidate

The accompanying nine-file Catalog/sources/Lock/example/test change is a Draft receiving input based on central `14ee2535e43e7c5b4d0992594aa01b31e8f3aa5c`. It adds the Skill and binds the general source to the exact merged commit through the unmodified lock generator. The other three source pins are unchanged. SYP-259 must integrate its final SYP-195/216/275 inputs and existing personal selection before normal review/merge/enablement; this branch must not be blindly treated as the final combined rollout.

Current Catalog regression: 48/48 PASS using PowerShell7.6.6/Pester4.10.1, zero fail/skip/pending. Load the repository's specified Pester runtime, then run `Invoke-Pester -Script tests/skills-catalog-contract.Tests.ps1,tests/production-skills-catalog.Tests.ps1 -PassThru`. The earlier46/48 failed run caught two assertions still referring to the pre-merge head; those exact revision assertions were updated to the actual merge. Assertions and source gates were not weakened.

## Receiver acceptance

SYP-259 owns required release/security dispositions, normal central CI/review/merge and production pin activation; actual USER-scope installation/update/removal/version/idempotence/recovery; preservation of customized/unmanaged content and existing selections; and actual client discovery/load. Use its existing deployment prerequisites and one-time rollout. This delivery changes no USER scope, credentials, DB roles, Entra or PRD, and adds no signing service or external policy change.

`delivery.json` records exact identities, evidence hashes and false/not-executed deployment flags. `source-core-report.json` and `source-canonical-scope-audit.json` retain the original source evidence. No unsigned review, isolated test or WhatIf is represented as formal signed lifecycle or real installation acceptance.
