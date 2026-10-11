# Source baseline red/green evidence

Source baseline: [`96dd761fc73e555966be44a52ea10a4959a70c45`](https://github.com/SyuanTsai/Skill-General/tree/96dd761fc73e555966be44a52ea10a4959a70c45). The new behavior probes were evaluated before the migration against the baseline v4 contract and Skill instructions:

| Probe | Baseline observation | Final candidate expectation |
| --- | --- | --- |
| AC01 no role gate | **Red.** Baseline `SKILL.md` step 4 requires Owner/Member role evidence or a new user role confirmation before writing; the contract has no unique connected record-purpose default. | A unique connected record target is selected without a role probe or repeated authorization; exact body readback is required. |
| AC06 explicit promotion rule | **Red.** Baseline has `Pending`/`Inferred` states but no enumerated explicit/direct confirmation evidence or rule rejecting repeated citations and high confidence alone. | Only explicit user confirmation or direct authoritative evidence may yield `Active`/`Confirmed`; repeated inference remains `Pending`/`Inferred`. |
| AC10 same-key body check | **Green baseline regression.** `workflow.sameKeyAbsenceRequires` already requires a verified body-destination result. | Retain the behavior, including index-only repair after an index miss. |
| AC12 partial index failure | **Green baseline regression.** `workflow.partialIndexFailure.resumeAction` is already `read-current-state-repair-index-only`. | Retain the verified body and recover the index without duplicating that body. |

The final candidate adds Pester contract cases for these behaviors and keeps the legacy fixture under `tests/fixtures/manage-notion-ai-memory/`. The controlled agent traces in this delivery directory supply actual synthetic calls and judgments for AC01, AC06, AC10, and AC12. The baseline probes establish a behavior gap; they do not claim that a live memory target was exercised.
