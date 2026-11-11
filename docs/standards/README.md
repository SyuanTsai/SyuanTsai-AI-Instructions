# Agent Skill Standards

本目錄是 `SyuanTsai-AI-Instructions` 對 Agent Skill repository、package、validation、security 與 lifecycle 的唯一 normative source of truth。

## Current version

- Standard version: **v1**
- Authority: `docs/standards/skill-repository-standard.md`
- Cross-repository evidence: `docs/standards/skill-repository-review-matrix.md`
- Validation tool policy: `docs/standards/validation-toolchain.json`
- SkillSpector approved sources: `docs/standards/skillspector-approved-sources.json`
- SkillSpector approved-source schema: `docs/standards/schemas/skillspector-approved-sources-v1.schema.json`
- Source inventory schema: `docs/standards/schemas/source-inventory-v2.schema.json`
- OpenAI metadata semantic schema: `docs/standards/schemas/openai-agent-metadata.schema.json`
- Managed replacement/migration contract: `docs/standards/managed-skill-lifecycle.md`
- Managed lifecycle evidence schema: `docs/standards/schemas/managed-skill-lifecycle-v1.schema.json`
- Upstream interoperability decision record: `docs/standards/upstream-interoperability.md`
- Canonical validation/security gate: `docs/standards/validation-security-gate.json`
- Canonical validation/security gate schema: `docs/standards/schemas/validation-security-gate-v1.schema.json`
- Internal source continuation policy: `docs/standards/internal-source-continuation.json`
- Internal source continuation schema: `docs/standards/schemas/internal-source-continuation-v1.schema.json`
- Internal source review assessment schema: `docs/standards/schemas/internal-source-review-assessment-v1.schema.json`
- Static parser host ownership policy: `docs/standards/static-parser-host-ownership.json`
- Static parser profile execution schema: `docs/standards/schemas/static-parser-profile-execution-v1.schema.json`
- Native static profile execution schema: `docs/standards/schemas/static-native-profile-execution-v1.schema.json`
- Static scanner bridge: `scripts/Invoke-StandardStaticScan.ps1`
- Validation tool resolver: `scripts/Resolve-StandardValidationTool.ps1`
- Verified Python wheel closure helper: `scripts/Resolve-PythonWheelClosure.py`
- Canonical authority gate: `scripts/Invoke-StandardAuthorityGate.ps1`
- Central validation runner: `scripts/Invoke-StandardValidation.ps1`
- Ordinary local core contract (v2): `docs/standards/standard-core-validation-v2.json`
- Ordinary core adapter schema (v2): `docs/standards/schemas/standard-core-adapter-v2.schema.json`
- Ordinary core evidence schema (v2): `docs/standards/schemas/standard-core-evidence-v2.schema.json`
- Central runner contract: `docs/standards/standard-validation-contract-v1.json`
- Consumer adapter schema: `docs/standards/schemas/standard-validation-adapter-v1.schema.json`
- Candidate evidence schema: `docs/standards/schemas/standard-validation-evidence-v1.schema.json`
- Standard authority regression: `tests/skill-repository-standard.Tests.ps1`
- Workflow authority regression: `tests/skill-repository-workflows.Tests.ps1`
- Resolver-hardening authority regression: `tests/standard-validation-resolver-hardening.Tests.ps1`
- Central runner behavior regression: `tests/standard-validation-runner.Tests.ps1`
- Tracking: Jira `SYP-167`

普通 local consumer call 以 runner 的 v2 core adapter 為預設入口，執行 adapter 明確列出的 repository checks；v2 結果固定 `releaseEligible=false`，不表示 CI、外部安全掃描或 release admission。歷史 v1 adapter 與完整生命週期保留原契約，必須明確選用 `-CompleteLifecycle`；`-DevelopmentHarness` 僅供 legacy fixture regression，結果不可 release。v2 core 與 v1 歷史契約各用版本化 descriptor/schema 描述，不以新 core 語意改寫 v1 evidence。

中央 `internal-source-continuation.json` 與 `New-StandardValidationInternalSourceReviewAssessment` 僅提供 `consistent`／`inconsistent` 審查資料，固定 applicability/execution provenance 未驗證、`authorizationGranted=false`、空 authorizedOperations、不可發布且無任何操作授權。Canonical FAILED/20 保留；完整 applicability、可信 execution 與 protected adoption 為 deferred integration，詳見 [§9.3.1](skill-repository-standard.md#931-internal-source-continuation)。

## Scope

Standard v1 適用於由 SyuanTsai 維護、可被 Claude Code / GitHub Copilot / Codex 等 host 安裝或執行的 Agent Skill source repositories。

Tracking: `SYP-352`。本次規範要求支援 Windows、Linux、macOS（WSL 視同 Linux），三 AI 共用 canonical source 與一致的 instructions；環境區隔依 Standard §15.1，平台路徑／鎖／程序安全依 §8.4。文件修訂不表示 runtime／tests／CI 已完成；Consumer 的舊 pin 不追溯變更，升級 pin 時必須同時採用 SYP-353 三平台 matrix 與完整 leg 聚合。本 authority repository 自身 CI 依 Standard §18.1.1 過渡，追蹤 SYP-353／SYP-354；目前兩個 required contexts 都仍只有 Windows 平台，Windows Core context 由多個內部 Windows jobs 彙總，不宣稱已通過三平台驗證。SkillSpector 僅可依 §9.1.1 的實測證據將非 Windows 步驟列為非必要，不得偽報 PASS。

本 authority repository 的目前 CI／支援驗證狀態如下；目標為三平台 Core／Install Smoke matrix，後續更新 **MUST** 反映實際採用與驗證證據：

| 平台 | 目前 Core／Install Smoke CI | 實際驗證狀態與待完成條件 |
|---|---|---|
| Windows | 兩個 workflow 都已有 Windows job，為目前唯一 required 平台 | 維持既有 required gate；不以此代表其他平台已通過。 |
| Linux | 尚未加入 | SYP-351 已記錄 Pester 失敗；installer 的非 Windows handle-bound mutation 仍 fail closed。待 SYP-353／SYP-354 的該平台條件完成。 |
| macOS | 尚未加入 | 尚未完成該平台驗證；installer 的非 Windows handle-bound mutation 仍 fail closed。待 SYP-353／SYP-354 的該平台條件完成。 |

Linux／macOS leg 依各自平台與 lane 的完成條件加入，加入後即為 required，不得再移除或降為非必要；過渡期結束條件依 Standard §18.1.1。

本標準定義：

- canonical source repository contract；
- 三 AI 共用 Skill package 與存在時的 optional `agents/openai.yaml` adapter metadata contract；
- source inventory、pin、provenance 與 integrity contract；
- managed replacement、known legacy migration、ownership evidence、rollback 與 post-install lifecycle contract；
- immutable authority distribution/revision binding；
- canonical validation / security lifecycle；
- local / pre-push / CI 共用 validation contract；
- trusted-source / trusted-endpoint + approved-channel validation tool policy（SkillSpector 使用 approved-source registry，其餘正式工具維持 latest-stable）；
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

Production invocation MUST receive `-SupervisorLaunchBindingPath`, a trusted-supervisor-signed `validation-launch-binding-v1` JSON. The supervisor creates the fresh `resolutionRunId`, passes that exact ID to the resolver before receipt creation, and binds the candidate, adapter, artifact/output, tool-root, source/archive, authority revision, validity window, and a supervisor-owned `consumptionPath` outside the caller-controlled roots. Before authority or resolver work, the runner MUST atomically create a create-only consumption marker at that signed path and reject an existing marker as a replay; evidence registration MUST retain the marker hash. The runner MUST read the launch-binding, adapter, and resolver receipt bytes once, retain each snapshot SHA-256, parse those same bytes, and authenticate the snapshot hashes against their bindings; any binding, adapter-path, or receipt-path substitution during handoff or receipt validation MUST fail closed before adapter validation, and evidence registration MUST retain the authenticated binding snapshot hash. It authenticates the binding before validating the package-adapter receipt and rechecks its file hash around every child process. The signed handoff uses lowercase 32-character hexadecimal N-format; the emitted `evidence.launchBinding.resolutionRunId` serializes the same GUID as a canonical hyphenated UUID so the evidence schema remains valid.

Production adapter command specs MUST resolve to non-reparse, directly executable trusted files；known generic interpreters and script payloads are development-harness-only and MUST be rejected for production. Production acquisition MUST be backed by a provider archive plus a trusted-supervisor-signed receipt and the normalized extracted tree MUST equal the candidate tree; the same signed receipt boundary applies to the immutable authority revision/archive/file inventory. The runner MUST use the immutable authority trust-anchor root (with pinned public-key hashes) for production supervisor and human-approval signatures, clear inherited child environments to an approved OS/runtime plus `STANDARD_VALIDATION_*` allowlist, reserve the final output with an exclusive supervisor-owned handle before child processes, and fail closed on output substitution. The runner MUST revalidate the snapshot, archive, receipt, and authority-file hashes before and after every child process, and MUST report cleanup failure until the full owned descendant process tree is gone. `canonicalValidatorPath` MUST identify the one candidate entry point checked by the central consumer entry-point inventory and invoked as the canonical gate. Human approval、publish/install 與 post-install evidence MUST be candidate-bound trusted-supervisor-signed RSA attestations；self-asserted approver/status/timestamp、authorization、release identity、installed inventory 或 integrity fields are insufficient。

Runner 的 terminal state 與 local／pre-push／CI exit semantics 必須一致：`PASS=0`、`BLOCKED=10`、`FAILED=20`、`INVALID=30`、`CANCELLED=40`。每個 event/candidate 最多一個 canonical matrix，每個平台 leg 最多一個 canonical execution；artifact 必須位於 checkout 外的 run-owned root，以 atomic create-only evidence 與 execution lock 防止覆寫／重播。development harness 可以執行無害 fixture 以驗證行為，但 `releaseEligible` MUST 為 false；AI Review 永遠不能取代 Human Approval。Runner 不替代 `Invoke-StandardAuthorityGate.ps1` 的 protected-base authority regression，也不得自行提升 trusted base。

## Normative language

- **MUST / MUST NOT**：conformance 必須遵守，違反即不符合 Standard v1。
- **SHOULD / SHOULD NOT**：預設應遵守；若偏離，必須有具體理由與可追蹤 evidence。
- **MAY**：允許的 extension，不影響基礎 conformance。

## Authority and precedence

1. `docs/standards/skill-repository-standard.md` 是 normative authority。
2. `docs/standards/schemas/source-inventory-v2.schema.json` 是 canonical `catalog/source.json` semantic shape；legacy schema v1 的兩種不相容 shape 都不是 Standard v1 conformance output。
3. `docs/standards/schemas/openai-agent-metadata.schema.json` 只驗 YAML parse 後的 semantic baseline；quoted-string/unquoted-key lexical style 與 exact Skill identity binding 仍由 YAML-aware validator 負責。
5. `docs/standards/validation-security-gate.json` 是 canonical validation stage order、security severity mapping、local/pre-push/CI pass-block semantics 與 consumer entry-point contract 的 machine-readable authority；schema 與 executable gate 必須同時更新。
6. Standard v1 的 consumer entry-point contract 要求每個 event/candidate 只有一個 canonical matrix、每個平台 leg 只有 one canonical validation execution，並 inventory workflows、hooks 與 public release commands；component scripts、compatibility status lanes 與本 authority repository 的四個 workflow roles 不得被誤判為 alternate gate。
7. `scripts/Resolve-StandardValidationTool.ps1` 是 tool source / endpoint trust anchor 與 provider-specific resolution authority；SkillSpector 由已審核來源清單的 active immutable pin 選擇，不使用 mutable latest release；`scripts/Resolve-PythonWheelClosure.py` 是其 hash-bound approved-index candidate materializer／offline backtracking helper，workflow 不得另建第二套 acquisition logic。
8. scripts/Invoke-StandardAuthorityGate.ps1 是共用的 executable authority adapter。本 Repository 的三平台 Core／Install Smoke 為目標要求，分階段落實及當前 required gate 依 Standard §18.1.1；以下不表示目前 workflow 已具備或通過全部平台。現行 pr8 workflow 沒有 workflow-level paths filter；pull_request、push 與 workflow_dispatch 的 Windows lane 都以 full plan → authority／parallel non-authority Pester shards／fixtures → fail-closed `Windows Core` aggregate 執行全部保留的 source tests，名稱不變的 aggregate 是唯一 required context。未來 Core lane 仍必須在 ubuntu-latest、windows-latest、macos-latest 各具必要 platform leg，使用各平台官方 release asset 與 SHA-256 驗證的最新穩定 PowerShell 7，並以名稱不變的 fail-closed aggregate 彙整全部 canonical legs。目標 syp101 workflow 的 Install Smoke lane 必須在三平台各執行一個必要 leg，設定 fail-fast: false，承接 production lock、真實安裝與 idempotence checks。standards-conformance.yml 僅由 workflow_dispatch 手動啟動，以 Windows、Linux、macOS 三個 fail-closed leg 提供診斷證據；它不是三平台 required 驗證，也不改變 Standard §18.1 的 required 平台狀態。SYP86 lock 與 validator maintenance 維持既有診斷角色。此 gate 輸出 source-bound releaseEligible=false 結果，不執行外部 consumer tools，也不宣稱完整 consumer lifecycle。
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
