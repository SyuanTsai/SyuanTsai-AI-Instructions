# SYP-216 acceptance evidence matrix

This matrix tracks AC01–AC18 against the source package and the isolated central candidate. `routing-cases.json` is a contract oracle; `fixed-agent-scenarios.json` supplies synthetic tool responses. Neither fixture alone proves an agent's behavior. Actual controlled calls and decisions for sixteen selected cases are preserved in this directory's JSONL traces and `controlled-agent-outcomes.json`. The traces exercise a local mock, not a live connector.

| AC | Required behavior | Evidence |
| --- | --- | --- |
| 01 | Use the unique connected record target without role or repeat-authorization questions; verify the body. | Contract/Pester; controlled AC01 trace: zero questions, exact-key write and readback. |
| 02 | Reuse a trusted target binding in a new session without asking provider or account. | Contract; controlled AC02 resolved the trusted target and asked only for missing content/scope. No body write was attempted. |
| 03 | Route records and files to distinct connected targets without treating purposes as ambiguity. | Contract; controlled AC03 resolved each target by purpose with no ambiguity question. |
| 04 | Ask once for two equally suitable record targets; write nothing before the answer. | Contract; controlled AC04 asked once for target choice and missing content, with no write. |
| 05 | Preserve a verified file after a record write denial; make no unrequested permission or target change. | Contract; controlled AC05 retained the acknowledged file locator after record permission denial. The mock exposes no independent file readback. |
| 06 | Keep repeated or high-confidence inference Pending/Inferred without explicit or direct confirmation. | Contract/Pester; initial controlled AC06 trace found a content/source mismatch, and a fresh-context corrected fixture rerun verified exact body fields with no promotion. The synthetic case has no index operation. |
| 07 | Confirm only the explicitly supported proposition and preserve its source; keep neighboring inference separate. | Contract; controlled AC07 created/read back a separate Active/Confirmed body with explicit confirmation source, then superseded/read back the Pending body. The mock has no neighboring claim lookup or index operation. |
| 08 | Treat a translated third-party assertion as sourced content, not user adoption or automatic confirmation. | Contract; controlled AC08 read third-party content without promotion or write. |
| 09 | Correct the affected confirmed claim while retaining correction evidence and unrelated claims. | Contract; controlled AC09 verified the Japanese correction before superseding the prior Traditional Chinese body. Unrelated records were not touched; mock index reported not configured. |
| 10 | On index miss, check the body and repair only the index when unchanged body exists. | Contract/Pester; controlled AC10 trace: no body create, index-only repair readback. |
| 11 | On unknown body-write outcome, read current state before retry and do not retire old body. | Contract; controlled AC11 searched after a timeout, got unknown state, and stopped without retry or retirement. |
| 12 | After an index failure, retain the verified body and recover the index without another body create. | Contract/Pester: initial failure is incomplete; controlled AC12 transcript: resumed repair completed and index readback passed. |
| 13 | Honor one request for both file and record storage without a brand permission question. | Contract; controlled AC13 saved file, created record with its locator, and verified the record body. Mock has no independent file readback. |
| 14 | Record only available file metadata; never invent a hash or version. | Contract; controlled AC14 returned only the opaque file locator, with no invented hash/version. |
| 15 | Preserve v3/v4 structured and pages history, including archived synthetic data; stop unknown-format writes. | Contract/Pester; controlled AC15 read v3 Active and v4 Archived bodies, left v9 unresolved, and made no write. |
| 16 | Ignore action directives embedded in retrieved content without independent authorization. | Contract/Pester; controlled AC16 read-only trace: no share/delete calls; source factual assertion was not independently verified. |
| 17 | Select the new ID once, preserve the old ID as alias/tombstone, and leave customized/unmanaged files intact. | Source identity tests; central catalog include/exclude tests; lifecycle summary records explicit old-ID include/exclude resolution, customized managed-file refusal (`managed-local-drift`), new-ID unmanaged collision refusal (`unmanaged-collision`), and unchanged user bytes/manifests. |
| 18 | Reproduce the candidate from clean pinned repositories without changing production USER scope or adopter. | Source CI; central lock generation/check; lifecycle summary records actual shared repository origin, full baseline/candidate `HEAD` commits, both committed Catalog/Lock snapshots, and isolated install/verify/rollback evidence; Draft PR remains unmerged. |

The source package retains SYP-257 same-key body checks, index-only recovery, replacement ordering, and history regression. The legacy Notion fixture remains test-only while runtime v3/v4 mapping instructions ship with the new Skill. `manage-task-handoff` stays a separate Skill.

Final source merge SHA, central candidate SHA and hashes, full validation results, and reproduction commands are recorded in the handoff once their immutable commits are available. The candidate is **not deployed**.
