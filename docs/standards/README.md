# Agent Skill Standards

本目錄是 `SyuanTsai-AI-Instructions` 對 Agent Skill repository、package、validation、security 與 lifecycle 的唯一 normative source of truth。

## Current version

- Standard version: **v1**
- Authority: `docs/standards/skill-repository-standard.md`
- Cross-repository evidence: `docs/standards/skill-repository-review-matrix.md`
- Validation tool policy: `docs/standards/validation-toolchain.json`
- Source inventory schema: `docs/standards/schemas/source-inventory-v2.schema.json`
- OpenAI metadata semantic schema: `docs/standards/schemas/openai-agent-metadata.schema.json`
- Managed replacement/migration contract: `docs/standards/managed-skill-lifecycle.md`
- Managed lifecycle evidence schema: `docs/standards/schemas/managed-skill-lifecycle-v1.schema.json`
- Upstream interoperability decision record: `docs/standards/upstream-interoperability.md`
- Canonical validation/security gate: `docs/standards/validation-security-gate.json`
- Canonical validation/security gate schema: `docs/standards/schemas/validation-security-gate-v1.schema.json`
- Validation tool resolver: `scripts/Resolve-StandardValidationTool.ps1`
- Verified Python wheel closure helper: `scripts/Resolve-PythonWheelClosure.py`
- Canonical authority gate: `scripts/Invoke-StandardAuthorityGate.ps1`
- Central validation runner: `scripts/Invoke-StandardValidation.ps1`
- Central runner contract: `docs/standards/standard-validation-contract-v1.json`
- Consumer adapter schema: `docs/standards/schemas/standard-validation-adapter-v1.schema.json`
- Candidate evidence schema: `docs/standards/schemas/standard-validation-evidence-v1.schema.json`
- Standard authority regression: `tests/skill-repository-standard.Tests.ps1`
- Workflow authority regression: `tests/skill-repository-workflows.Tests.ps1`
- Resolver-hardening authority regression: `tests/standard-validation-resolver-hardening.Tests.ps1`
- Central runner behavior regression: `tests/standard-validation-runner.Tests.ps1`
- Tracking: Jira `SYP-167`

## Scope

Standard v1 適用於由 SyuanTsai 維護、可被 Agent / Codex / GitHub Copilot 等 host 安裝或執行的 Agent Skill source repositories。

本標準定義：

- canonical source repository contract；
- Skill package 與 `agents/openai.yaml` metadata contract；
- source inventory、pin、provenance 與 integrity contract；
- managed replacement、known legacy migration、ownership evidence、rollback 與 post-install lifecycle contract；
- immutable authority distribution/revision binding；
- canonical validation / security lifecycle；
- local / pre-push / CI 共用 validation contract；
- trusted-source / trusted-endpoint + latest-stable validation tool policy；
- immutable workflow-action pin、checkout credential isolation、authority trigger 與 event-aware diff contract；
- run-owned isolated tool installation、static installed metadata verification 與 credential boundary；
- testing、release、publish、install 與 post-install verification；
- SkillSpector Static / Semantic Security Gate；
- canonical validation stage order、severity mapping 與 fail-closed semantics；
- Agent Plugins / Agent Skills adapter conformance in SYP-192 deterministic Gate 1；
- `upstream-adapter.json` and its executable adapter validator；
- AI Review / Human Release Approval boundary；
- approved immutable release installation semantics；
- repository-specific extension / adapter / exception policy。
- upstream Agent Skills / Agent Plugins interoperability and adapter boundary。

中央 validation runner contract (`standard-validation-contract-v1.json`) 是 consumer 可直接使用的共用執行層；consumer adapter 只能宣告 candidate-relative active Skill root、完整 active Skill set、已解析且受信任的工具命令與 repository-test dispatch，MUST NOT 宣告 stage order、severity、exception、approval 或 pre-Static hook。`scripts/Invoke-StandardValidation.ps1` MUST 以 read-only candidate snapshot 執行：Controlled Acquisition／Integrity 後，Package Validation（adapter、skill-validator、每個 active Skill 的 skill-tools）MUST 全部產生 candidate-bound actual process/output evidence，才可進入 SkillSpector Static；Static 失敗或 analyzer coverage 不完整時 MUST NOT dispatch candidate repository tests。未完成的 semantic consent、AI review、human approval、publish/install 或 post-install evidence MUST 保持 `BLOCKED`、`not-applicable` 或 `not-run` 的明確狀態，不得以十個 stage ID 或格式正確的 SHA 文字冒充完成。

Production adapter command specs MUST resolve to non-reparse, directly executable trusted files；known generic interpreters and script payloads are development-harness-only and MUST be rejected for production. Production acquisition MUST be backed by a provider archive plus a trusted-supervisor-signed receipt and the normalized extracted tree MUST equal the candidate tree; the same signed receipt boundary applies to the immutable authority revision/archive/file inventory. The runner MUST revalidate the snapshot, archive, receipt, and authority-file hashes before and after every child process, and MUST report cleanup failure until the full owned descendant process tree is gone. `canonicalValidatorPath` MUST identify the one candidate entry point checked by the central consumer entry-point inventory and invoked as the canonical gate. Human approval、publish/install 與 post-install evidence MUST be candidate-bound trusted-supervisor-signed RSA attestations；self-asserted approver/status/timestamp、authorization、release identity、installed inventory 或 integrity fields are insufficient。

Runner 的 terminal state 與 local／pre-push／CI exit semantics 必須一致：`PASS=0`、`BLOCKED=10`、`FAILED=20`、`INVALID=30`、`CANCELLED=40`。每個 event/candidate 最多一個 canonical execution；artifact 必須位於 checkout 外的 run-owned root，以 atomic create-only evidence 與 execution lock 防止覆寫／重播。development harness 可以執行無害 fixture 以驗證行為，但 `releaseEligible` MUST 為 false；AI Review 永遠不能取代 Human Approval。Runner 不替代 `Invoke-StandardAuthorityGate.ps1` 的 protected-base authority regression，也不得自行提升 trusted base。

## Normative language

- **MUST / MUST NOT**：conformance 必須遵守，違反即不符合 Standard v1。
- **SHOULD / SHOULD NOT**：預設應遵守；若偏離，必須有具體理由與可追蹤 evidence。
- **MAY**：允許的 extension，不影響基礎 conformance。

## Authority and precedence

1. `docs/standards/skill-repository-standard.md` 是 normative authority。
2. `docs/standards/schemas/source-inventory-v2.schema.json` 是 canonical `catalog/source.json` semantic shape；legacy schema v1 的兩種不相容 shape 都不是 Standard v1 conformance output。
3. `docs/standards/schemas/openai-agent-metadata.schema.json` 只驗 YAML parse 後的 semantic baseline；quoted-string/unquoted-key lexical style 與 exact Skill identity binding 仍由 YAML-aware validator 負責。
5. `docs/standards/validation-security-gate.json` 是 canonical validation stage order、security severity mapping、local/pre-push/CI pass-block semantics 與 consumer entry-point contract 的 machine-readable authority；schema 與 executable gate 必須同時更新。
6. Standard v1 的 consumer entry-point contract 要求每個 event/candidate 只有 one canonical validation execution，並 inventory workflows、hooks 與 public release commands；component scripts、compatibility status lanes 與本 authority repository 的四個 workflow roles 不得被誤判為 alternate gate。
7. `scripts/Resolve-StandardValidationTool.ps1` 是 tool source / endpoint trust anchor 與 provider-specific resolution authority；`scripts/Resolve-PythonWheelClosure.py` 是其 hash-bound SkillSpector approved-index candidate materializer／offline backtracking helper，workflow 不得另建第二套 acquisition logic。
8. `scripts/Invoke-StandardAuthorityGate.ps1` 是 workflow 共用的 executable authority adapter；`.github/workflows/standards-conformance.yml` 與 `.github/workflows/pr8-powershell-validation.yml` 的 Ruleset-required Linux Composition job 必須呼叫同一 gate、執行相同的三個 authority regression suites、live resolver receipt checks 與 formal tool execution，且不得各自重建 resolver／tool execution sequence。
9. `scripts/Invoke-StandardValidation.ps1` 是 consumer-facing central orchestration contract 的唯一 runner；其 adapter、evidence schema 與 behavior regression 必須在同一 protected-base authority path 驗證，且 runner 的 development harness 不得成為 release approval。
10. `tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1`、`tests/standard-validation-resolver-hardening.Tests.ps1` 與 `tests/standard-validation-runner.Tests.ps1` 共同保護 Standard、merge-blocking workflow、resolver supply-chain 與 central runner contract；normative 或 executable authority change 必須在同一 PR 更新相關 regression。
11. `Skill-General` 在 SYP-155 完成後是 reference implementation，但不得反向覆寫或私自擴充 normative policy。
12. `Skill-Knowledge-Content`、`Skill-Code-Collaboration`、`Skill-Darktide-Translate`、`Skill-Atlassian-Ecosystem` 依 SYP-156～159 做 conformance migration。
13. 舊文件若與 Standard v1 衝突，以本目錄為準；歷史文件應保留歷史語意並加上 superseded notice，不得重寫歷史。

Conformant source repository 不得直接信任 mutable branch 或未驗證 copy。Canonical validator 必須在執行 authority-derived policy 前取得並驗證一個 immutable authority snapshot，記錄 authority repository、full commit、bundle SHA-256 與實際使用的 Standard/policy/schema/resolver file inventory/hash。只記錄 `v1` 不足以重現 conformance。

Machine-readable policy 中未標 optional/conditional 的 formal baseline tools 必須在同一 frozen run 實際執行於完整 active Skill inventory；resolve/install/version receipt 本身不是 validation pass。Authority repository 沒有 active shared Skill source 時，必須改以 candidate-bound controlled Skill fixture 加上 authority regressions 實跑四個 formal tools，不得用 empty inventory vacuously pass。

`Skill-Darktide-Translate` 仍是不得加入本 Repository Catalog/profile/lock/bootstrap 的獨立產品。它的 Standard v1 source inventory 仍使用 schema v2；Darktide-only selection/state/domain metadata 可作 product-local extension config 保留，但不得成為 cross-source authority 或重新定義共用 lifecycle/security/tool/approval policy。

## Change rule

任何會改變 MUST / MUST NOT、canonical lifecycle、validation tool source / endpoint / version policy、security gate semantics、metadata contract、integrity contract、approval boundary、workflow authority enforcement 或 exception policy 的變更，必須：

1. 在本目錄修改 normative 文件；
2. **同一 PR** 更新三個 authority regression suite 中受影響的 tests（`skill-repository-standard`、`skill-repository-workflows`、`standard-validation-resolver-hardening`）與受影響的 machine-readable policy；
3. tool source / endpoint / resolver behavior 變更時，同一 PR 更新 `scripts/Resolve-StandardValidationTool.ps1` 與負向 regression；
4. workflow action、trigger、credential 或 merge-blocking bridge 變更時，同一 PR 更新 workflow regression，並確認 dedicated／required gate 都會執行；
5. 說明對 reference implementation 與已遷移 repositories 的影響；
6. 執行 authority-level conformance regression；
7. 經 Human Release/Policy Review 後才可 merge；merge 後才可 fan out。

這項 self-conformance rule 從 Standard v1 首次 merge 前即生效，不延後到 SYP-155。

Repository-specific implementation 不得自行建立第二套 lifecycle、security、validation-tool 或 release policy。
