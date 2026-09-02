# Agent Skill Repository Standard v1

Status: **Normative**  
Authority: `SyuanTsai-AI-Instructions/docs/standards/`  
Tracking: Jira `SYP-167`

## 1. Purpose

本標準定義 Agent Skill source repository 從 acquisition、package、validation、security review 到 publish/install 的共同 contract。Repository-specific 能力可透過 extension / adapter / config 接入，但不得另建第二套 lifecycle、Security Gate、severity policy 或 review policy。

## 2. Normative terms

- **MUST / MUST NOT**：Standard v1 conformance 必要條件。
- **SHOULD / SHOULD NOT**：預設要求；偏離必須記錄原因與 evidence。
- **MAY**：合法 extension。

## 3. Ownership boundaries

### 3.1 Normative authority

`SyuanTsai-AI-Instructions/docs/standards/` **MUST** 是共用 policy 的唯一 authority。

Source repository **MUST NOT** 私自重新定義：

- canonical lifecycle；
- security severity / block semantics；
- suppression / exception policy；
- AI Review / Human Approval boundary；
- cross-repository profile / dependency / lifecycle semantics。

### 3.2 Reference implementation

`Skill-General` 在 SYP-155 完成後 **SHOULD** 作為 implementation reference，但若 reference implementation 與本標準衝突，**MUST** 修正 reference implementation 或先修改本標準並 review；不得以 implementation 現況覆蓋 normative policy。

## 4. Repository and Skill package contract

### 4.1 Canonical source layout

Dedicated Skill source repository **MUST** 使用 flat stable-ID source root：

```text
skills/
  <skill-id>/
    SKILL.md
    agents/
      openai.yaml
    scripts/        # optional
    references/     # optional
    assets/         # optional
catalog/
  source.json
scripts/
tests/
.github/workflows/
```

`skillsRoot` **MUST** 由 source metadata 宣告，Standard v1 canonical value 為 `skills`。

Historical `.agents/skills/<skill-id>` source repositories可在 SYP-155～159 migration 完成前繼續存在，但屬 **legacy source layout**，不是 Standard v1 reference layout。

### 4.2 Consumer projection

Source path 與 consumer/runtime path **MUST** 分離。

合法 consumer projection 可包含，例如：

- `.agents/skills/<skill-id>`；
- `.github/skills/<skill-id>`；
- `.claude/skills/<skill-id>`；
- `$HOME/.agents/skills/<skill-id>`；
- host 定義的其他 managed Skill location。

Source repository **MUST NOT** 為不同 host fork 相同 Skill content；host adapter 僅負責 projection、installation、capability binding 或 host-specific acceptance。

### 4.3 Stable identity

Skill ID **MUST**：

- 使用 lowercase kebab-case；
- 最長 64 字元；
- 建立後不得因 repository、profile、host、版本或目錄 migration 改變 identity；
- 與 package directory 及 `SKILL.md` frontmatter `name` 一致。

Rename **MUST** 使用新 stable ID 並由 central Catalog lifecycle 處理 tombstone / replacement；不得原地 repurpose 舊 ID。

### 4.4 Required files

每個 active Skill package **MUST** 包含：

- `SKILL.md`；
- `agents/openai.yaml`。

Skill-specific `scripts/`、`references/`、`assets/` **MAY** 存在。Repository root script **SHOULD** 僅處理 repository-level validation、release、pin/provenance、orchestration 或 adapters；Skill 自己的 domain implementation **SHOULD** 保持在 Skill package 內。

## 5. Source inventory and central Catalog ownership

### 5.1 Source-owned inventory

Source repository **MUST** 提供 `catalog/source.json`，至少包含：

```json
{
  "schemaVersion": 1,
  "sourceId": "example-source",
  "repository": "https://github.com/example/example-source.git",
  "skillsRoot": "skills",
  "skills": [
    "example-skill"
  ]
}
```

Inventory **MUST** 與實際 package directories 完全一致；未宣告 package 與宣告但不存在 package 都 **MUST** fail closed。

### 5.2 Central policy

下列 cross-source policy **MUST** 由 central Catalog 擁有，而非在 source repositories 重複成第二份 authority：

- profiles / selection；
- compatibility；
- cross-Skill dependencies；
- lifecycle / rename / removal；
- consumer routing policy。

Source repository **MAY** 維護 derived/read-only display metadata，但 **MUST NOT** 讓 derived metadata 成為與 central Catalog 競爭的 authority。

## 6. Pin, provenance and integrity contract

以下 security properties **MUST** 分開命名與驗證：

- `resolvedCommit`：immutable full Git commit identity；
- `archiveSha256`：controlled acquisition 取得的 source archive raw bytes hash；
- `contentSha256`：單一 Skill package deterministic content inventory hash；
- `repositoryTreeSha256`：若需要，代表整個 repository tracked tree fingerprint；不得冒充 `contentSha256`；
- installed manifest file hash：consumer target 實際 bytes hash。

### 6.1 Per-Skill content hash

`contentSha256` **MUST** 使用 deterministic inventory：

1. package root 下所有 regular files 都納入，包括 dot files / binary assets；
2. path 使用 repository-relative forward-slash path；
3. path identity case-sensitive；
4. ordinal 排序；
5. 每行為 `<path>\t<raw-file-sha256>\n`；
6. 串接 UTF-8 no-BOM bytes 後計算 SHA-256。

### 6.2 Immutable runtime source

Consumer/publisher **MUST NOT** 直接以 mutable `main`、branch 或 moving tag 作為 runtime content authority。Mutable ref **MAY** 作為 update-selection provenance，但內容執行、安裝與重現 **MUST** 綁定已解析的 immutable commit 與 integrity hashes。

### 6.3 Controlled acquisition

任何需要驗證/發布外部 candidate 的流程 **MUST**：

1. 解析候選 revision；
2. 以受控 provider 取得 immutable source；
3. 驗證 expected identity/hash；
4. 在隔離 staging 執行 security/validation；
5. 所有 preflight 完成前不得 mutation consumer target 或 publish state。

## 7. Canonical lifecycle

Standard v1 canonical flow 為：

```text
Controlled Acquisition
→ Integrity Verification
→ SkillSpector Static Security Scan
→ Repository Validation
→ Tests / Regression / Conformance
→ Conditional SkillSpector Semantic Scan
→ AI Review
→ Human Approval
→ Publish / Install
→ Post-install Integrity Verification
```

Repository **MUST** 維持此 stage ordering semantics。Extension **MAY** 在相鄰 stage 內增加 stronger checks，例如 clean-HEAD、package binding、routing tests、credential E2E；不得跳過前置 gate 或另建不同 policy pipeline。

## 8. Single validation entry contract

每個 repository **MUST** 提供一個 canonical validation entry point，例如 repository root script `scripts/Validate.ps1`（實際名稱可由 adapter/config 決定）。

Canonical entry **MUST**：

- 可由 developer local、pre-push（若存在）與 CI 呼叫；
- 執行同一 stage policy、severity policy 與 fail-closed semantics；
- 接受 host/CI 必要的 machine-readable output option；
- 在缺少 required analyzer、required test runner、required config 或 required evidence 時 fail closed；
- 不因 CI/local 而改變「什麼算 pass/block」；
- 只允許 execution adapter 差異，例如 path、credential source、artifact destination、TTY availability。

Component/diagnostic scripts **MAY** 存在，但 **MUST NOT** 成為繞過 canonical entry 的 release path。

## 9. SkillSpector Static Security Gate

### 9.1 Required stage

所有 active Skill packages **MUST** 在 Repository Validation 之前通過 SkillSpector Static Security Scan。

Catalog-driven repository **MUST** 自動從 source inventory discover 所有 active Skill；新增 Skill **MUST NOT** 能因忘記修改 CI hard-coded list 而繞過 scan。

### 9.2 Fail-closed requirements

Static gate 在下列任一情況 **MUST BLOCK**：

- scanner process error / crash；
- required analyzer 未載入、未完成或結果缺失；
- output 無法解析或 schema/version 不支援；
- candidate Skill inventory 與 scan inventory 不一致；
- policy 定義的 blocking finding 存在且沒有有效 suppression/exception；
- scanner 無法證明完整掃描 expected package set。

「scanner 沒產生 findings」與「scanner 沒有完整執行」**MUST** 被視為不同狀態；後者不得 pass。

### 9.3 Analyzer completeness

Validation **MUST** 檢查預期 analyzer set / capabilities 已完成，而不是只看 exit code。若 scanner 版本改變 analyzer inventory，CI **MUST** 顯示 resolved scanner version 與 analyzer completeness evidence。

Tool version **MUST** 可重現：release/conformance gate **MUST NOT** 永久依賴無版本約束的 `latest`。允許 scheduled update job 評估新版工具，但 production gate 使用的版本 **MUST** 經 review/pin。

### 9.4 Severity handling

Repository **MUST** 使用 central severity semantics：

- **Critical / High**：預設 BLOCK；只有正式 approved exception 才可放行。
- **Medium**：需要 triage。若屬 exploit/security boundary violation 或 analyzer 明確定義為 blocking 類型，BLOCK；其餘需有 resolution/suppression evidence 才可 release。
- **Low / Informational**：可不阻擋，但 SHOULD 保留 evidence 供 trend/review；不得藉由降級 severity 隱藏實質 High/Critical risk。

實際 scanner severity 名稱若不同，adapter **MUST** 做 deterministic mapping，mapping 必須受版本控制與 tests 保護。

### 9.5 Capability is not automatically vulnerability

下列 capability 本身 **MUST NOT** 因存在就自動 BLOCK：

- network access；
- environment variables；
- executable PowerShell/shell；
- Jira/Confluence/Bitbucket REST；
- MCP / connectors；
- Git / GitHub CLI；
- credential lookup from approved secret source。

Gate **MUST** 評估 capability 的 declared purpose、scope、permission、data flow、secret handling 與 observed behavior。

例如下列風險則可能 BLOCK：

- Prompt Injection enabling unsafe instruction override；
- MCP Tool Poisoning / description-behaviour mismatch；
- excessive permissions without need；
- secret printing/logging/embedding；
- credential in command arguments when safer channel exists；
- undeclared or unjustified data exfiltration；
- hidden network destination or behavior inconsistent with Skill description。

## 10. Static scan artifacts

Scanner JSON / SARIF / intermediate files **MUST**：

- 寫入 temporary / CI artifact directory，而非 tracked source tree；
- 不得讓正常 local/pre-push validation 造成 dirty working tree；
- 若上傳 CI artifact，**MUST** 先做 secret/redaction check；
- 不得將 credentials、tokens、raw secret-bearing environment dumps 包入 artifact；
- retention **SHOULD** 最小化到 review/audit 所需期間。

Machine-readable JSON/SARIF **SHOULD** 作為 canonical evidence；human-readable summary **MAY** 由它產生，不應反過來 parse console prose 作 release authority。

## 11. Conditional SkillSpector Semantic Scan

Semantic Scan **MUST** 在下列任一情況觸發：

- static finding 需要 intent/context 判斷；
- Skill 新增或修改 external tool/network/MCP/credential capability；
- Skill description / declared behavior 與 implementation 可能不一致；
- static analyzer 標示 prompt injection、tool poisoning、data exfiltration 或 permission ambiguity；
- security suppression / exception 候選需要 context evidence；
- repository adapter 明確要求 semantic scan 的 high-risk domain change。

單純格式、文件文字且 security-relevant behavior 未改變時 **MAY** 不執行 semantic scan，但 trigger decision **MUST** 可追蹤且由 canonical validator deterministic 判斷或明確記錄。

Semantic Scan failure、timeout、unavailable 或 unparsable result，在已觸發的情況 **MUST** fail closed；不得退化成「略過但 pass」。

## 12. Repository validation and tests

### 12.1 Repository validation

Repository Validation **MUST** 驗證至少：

- source metadata schema；
- stable IDs；
- package inventory exact match；
- required files；
- `SKILL.md` name identity；
- safe relative paths；
- source/inventory integrity contract；
- repository-specific declared adapters/config；
- no unapproved policy fork。

### 12.2 Tests

Repository **MUST** 有：

- Standard v1 conformance regression；
- repository contract regression；
- domain behavior regression（當 package 存在 executable/domain logic 時）；
- security adapter/severity/suppression regression（當使用 adapter 或 exception 機制時）。

Tests **MUST NOT** 因 migration 而弱化既有 integrity/security/regression guarantees。

## 13. AI Review and Human Approval

### 13.1 AI Review

AI Review **SHOULD** 聚焦：

- Skill intent 與實作一致性；
- capability/permission/data-flow 合理性；
- static/semantic findings triage；
- test gap / regression risk；
- release evidence completeness；
- suppression/exception 是否真的符合 policy。

AI Review **MUST NOT** 自行批准 High/Critical accepted-risk exception 或繞過 Human Approval。

### 13.2 Human Approval

Human Approval **MUST** 是下列事項的最終邊界：

- publish/release candidate；
- new/changed security exception；
- accepted High/Critical risk；
- intentional analyzer suppression that affects release outcome；
- normative policy change。

自動化 **MAY** 在沒有 blocking finding 且 policy 未要求人工 security exception review 時準備 candidate，但不得將「AI 認為合理」等同 human approval。

## 14. Suppression and exception policy

### 14.1 Suppression

Suppression **MUST**：

- 精確綁定 analyzer/rule/finding fingerprint 或足夠窄的 scope；
- 記錄理由、owner、建立日期；
- 說明為何 capability 合法及有哪些 compensating controls；
- 可被 conformance tests 驗證仍只作用在預期範圍；
- 在 finding 不再存在時 **SHOULD** 移除。

Broad wildcard suppression、停用整個 scanner、忽略 scanner exit code、以 console filtering 隱藏 finding 都 **MUST NOT** 作為合法 suppression。

### 14.2 Exception

Exception **MUST** 是顯式、可追蹤、Human Approved 的 repository-specific config/evidence，並包含：

- Standard requirement / analyzer finding；
- business/technical necessity；
- affected Skill(s)；
- risk assessment；
- compensating controls；
- owner；
- review/expiry condition。

Exception **MUST NOT** 建立替代 lifecycle 或把 repository 永久排除於 Security Gate。

## 15. Repository-specific extension points

Repository **MAY** 增加 extension stage/check，例如：

- clean-HEAD binding；
- package/source receipt binding；
- deterministic source pin evidence；
- routing regression；
- `gh skill publish --dry-run`；
- Jira/MCP/credential E2E；
- state/reservation/recovery validation；
- Windows byte-preservation tests。

Extension **MUST**：

- 由 config/adapter/declared stage 表達；
- 使用 canonical severity/fail semantics；
- 不得跳過 Static Security、Repository Validation、Tests 或 required Semantic Scan；
- local/CI/pre-push 使用同一判斷；
- 不得把 temporary evidence 寫成 uncontrolled tracked state。

## 16. Release, publish and install

Release candidate **MUST** 綁定單一 immutable candidate revision，且所有 canonical stages **MUST** 對同一 candidate 執行。

在 validation 完成後 candidate bytes 改變，**MUST** 重新執行受影響 stages；不得將舊 scan/test evidence 套用到新 commit。

GitHub-hosted dedicated Skill repositories **SHOULD** 執行 host publishing compatibility dry run（例如 GitHub Skill publishing dry-run）作 extension acceptance。

Publish/install **MUST**：

- 使用 validated immutable commit / package；
- 保存必要 provenance；
- 不把 secret 寫入 package/manifest；
- 安裝後重新驗證 expected package identity / per-file integrity；
- integrity mismatch 時 fail closed / rollback，不得 silent repair 成未知內容。

## 17. Conformance levels

Repository 要宣稱 Standard v1 conformant，**MUST** 證明：

1. source/package/inventory contract；
2. canonical lifecycle stage ordering；
3. single validation entry contract；
4. SkillSpector Static Gate + analyzer completeness；
5. severity/fail-closed semantics；
6. tests/regression/conformance；
7. semantic trigger handling；
8. AI/Human review boundary；
9. suppression/exception contract；
10. release/install/post-install integrity；
11. repository-specific deviations 僅存在於 approved adapter/config/exception。

Conformance report **MUST** 明確列出 deviations；若沒有，記錄 `None`，不得省略此欄位。

## 18. Migration and backward compatibility

SYP-167 **MUST NOT** 直接改寫五個 source repositories 或 production Catalog/Lock pins。

Migration 順序：

1. SYP-167：建立 Standard v1 與 cross-repository review；
2. SYP-155：`Skill-General` 建立 reference implementation + conformance tests；
3. SYP-156～159：其餘 repositories fan-out migration；
4. 每個 source migration 合併並驗證後，才更新 central Catalog/Lock source path / immutable pins；
5. production consumer migration 必須維持 transactional/fail-closed integrity guarantees。

因此現行 central Catalog/Lock 仍可在 migration window pin legacy `.agents/skills/...` source path。Standard v1 定義的是 migration target，不要求 SYP-167 在尚未遷移 source repositories 時破壞 production runtime。

## 19. Prohibited patterns

下列做法 **MUST NOT**：

- source repo 與 consumer host 各維護一份 Skill fork；
- hard-code CI Skill list 造成新增 Skill 可繞過 security gate；
- local、pre-push、CI 使用不同 pass/block policy；
- scanner/analyzer 未完整執行仍 pass；
- release gate 永久依賴 unpinned latest tool；
- 將 repository tree fingerprint 稱為 per-Skill `contentSha256`；
- 使用 broad scanner suppression 隱藏 findings；
- 將 legitimate network/MCP/script capability 一律視為 vulnerability；
- 將 AI Review 當作 Human Approval；
- 在 source repository 私自建立與本標準競爭的 lifecycle/security policy。
