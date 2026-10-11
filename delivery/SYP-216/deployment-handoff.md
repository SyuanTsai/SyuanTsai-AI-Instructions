# SYP-216 source-to-deployment handoff

Status: **merged source pinned in central candidate / not deployed**. The central catalog change is on a local candidate branch; a Draft pull request follows the final isolated validation. This package is for SYP-259 to select, release, install, and smoke in real USER scope after its own authorization. The source and isolated tests never changed a real user's Skills, manifest, adopter mapping, or memory records.

## Immutable inputs

| Input | Revision |
| --- | --- |
| Source PR | [Skill-General #32](https://github.com/SyuanTsai/Skill-General/pull/32) |
| Reviewed source PR head before merge | `66d00cb24b27a04209fb251612d9c8b337da33be` (tree `74daf1d4c88acef033d184fa33bb838719f0f54d`) |
| Source validation on that head | [Standard v1 run 38110520933](https://github.com/SyuanTsai/Skill-General/actions/runs/38110520933): four jobs succeeded; Core Pester 311/311 passed, 0 failed, 0 skipped; SourceValidation state PASS / exit 0; artifact `11691875619` |
| Source merge commit | `ef9b028d297fe69bdd1f16e5b35cad4e538374c4` (normal merge of the reviewed and approved head) |
| Central baseline used by the current lifecycle audit | `54fbb2229b0a662abac69bf0ac29f1ae0ef48a10` (`origin/main`) |
| Central candidate Draft PR / commit | To be filled after candidate push. |
| Previous production `general` pin | `7f8a3c3c8d535b2a0f8892103482bf2e942217c1` |
| Candidate catalog SHA-256 | `7df25238867104c65e5830d7e13a5444c24d5dc8610255cabd697bdaa923f696` |
| Candidate lock SHA-256 | `1af54d539934c81ad97ce315b05ca934ec0ec86217e676dc3d7a446bafd44d0a` |
| Merged `general` source archive SHA-256 | `c050f06c38fc3b5016fef6b3888ce5f413cf2f1da399f75aa3c345c4afb84d5c` |

The lifecycle script reads each checkout's actual `origin` and full `HEAD` commit. It requires distinct clean baseline and candidate checkouts from the same canonical GitHub repository as the script, archives each commit's catalog and runtime modules, and verifies each committed Catalog/Lock pair before building a desired state. The older `838ed0619c3703af207b836b74eec5576d738c45` baseline is historical and is not used by the current audit.

## Selection and compatibility

The opt-in `ai-memory` profile selects `manage-ai-memory` and the independent `manage-task-handoff` Skill. `manage-notion-ai-memory` is a removed catalog entry with `replacementId: manage-ai-memory`; the new active entry retains the old ID as an alias. An explicit include or exclude of the old ID resolves to the new ID. Default profile selection stays unchanged. Source runtime references recognize v3/v4 structured/pages history and legacy adopter mappings; they do not interpret an archived synthetic record as current memory. Customized or unmanaged consumer files are preserved by the catalog reconciler.

## Evidence index

- [AC01–AC18 matrix](acceptance-matrix.md) links the contract oracles and controlled behavior evidence.
- [Baseline red/green probes](baseline-red-green.md) identify the old role gate and missing explicit promotion rule while preserving existing same-key/index recovery behavior.
- [Controlled agent outcomes](controlled-agent-outcomes.json) and `controlled-agent-traces/` contain sixteen synthetic cases with actual calls, responses, decisions, and explicit verification limits. Earlier AC01/06/10/12/16 traces retain their older source candidate provenance; eleven additional cases used source content matching the reviewed PR head.
- [Isolated lifecycle exercise](test-candidate-user-lifecycle.ps1) archives both actual commits and verifies both Catalog/Lock pairs. It records explicit legacy-ID include and exclude resolution, performs baseline install, candidate upgrade, verification, idempotence, and rollback in an isolated user root, and checks that a customized old Skill and an unmanaged collision at the new Skill path fail closed without changing bytes, manifests, or backups.
- Independent central review of clean candidate `660b4ee018ab99f04cd6e5ab544d004fc810d399` found no actionable AC17/AC18 or deployment-boundary issue. Direct Catalog/Lock validation and selection checks passed, including one new Skill when both IDs are included. The reviewer inspected the earlier isolated lifecycle summary. The final merged-source pin and lock have since been generated and checked against exact source archives.
- Focused local ManageAiMemory and LegacyNotionMemory Pester 6.2.0 suites passed 21/21. Final central Pester, installer smoke, and lifecycle results will be recorded after the immutable candidate is built.

## Reproduce the candidate checks

1. Clone the source and central repositories and check out the exact source merge, central baseline, and central candidate commits shown above. The baseline and candidate checkouts must be separate and clean, with the same canonical origin as the checkout running the script. Keep this test outside any real HOME or Codex home.
2. Download source ZIP archives from `https://codeload.github.com/SyuanTsai/Skill-General/zip/<source-merge-sha>` and the other three exact source commits in `catalog/skills-catalog.sources.json`. Supply their local ZIP paths as `-SourceArchivePaths` to `scripts/update-skills-catalog-lock.ps1`, then run it again with `-Check`.
3. Run `Invoke-Pester -Script @('./tests/production-skills-catalog.Tests.ps1','./tests/skills-catalog-contract.Tests.ps1','./tests/skills-catalog-source-host.Tests.ps1','./tests/skills-selection.Tests.ps1') -PassThru` in the central checkout with Pester 4.10.1. Run `scripts/test-syp101-production-smoke.ps1` from a clean central candidate checkout; it creates and removes its own temporary Codex home and target Git repository.
4. Run `delivery/SYP-216/test-candidate-user-lifecycle.ps1` with `-BaselineRoot`, `-CandidateRoot`, `-BaselineGeneralArchive`, `-CandidateGeneralArchive`, `-BaselineCodeCollaborationArchive`, `-CandidateCodeCollaborationArchive`, and a fresh `-EvidenceRoot` outside both repositories and the invocation checkout. Supply source archives whose SHA-256 values match each checkout's lock. Check `summary.json` for the actual repository URL and both full commit SHAs, both committed Catalog/Lock hashes, the explicit legacy include/exclude results, the normal install/verify/idempotence/rollback outcomes, and `managed-local-drift` / `unmanaged-collision` refusal evidence with unchanged content hashes and manifests.

## SYP-259 deployment and rollback

After SYP-259 accepts this handoff, review the final Draft PR diff and its exact source pin/lock, then merge it through normal central protection. Publish the formal release, choose the `ai-memory` profile for the intended adopter, reconcile USER scope, switch only the approved adopter mapping, and run real post-deployment smoke against the intended memory entry points. Record the release and smoke results in SYP-259. None of those steps are complete in SYP-216.

For rollback, restore the prior central baseline catalog/lock and `general` source pin, reconcile USER scope to the prior `manage-notion-ai-memory` selection, verify its managed manifest and Skills, and preserve any customized or unmanaged files. Restore the adopter's prior mapping only from its verified backup and verify the old entry point. Do not delete or bulk rewrite real memory records as part of a Skill rollback.
