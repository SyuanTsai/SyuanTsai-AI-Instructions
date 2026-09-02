# Agent Skill Repository Standard v1

Status: **Normative**
Authority: `SyuanTsai-AI-Instructions/docs/standards/`
Tracking: Jira `SYP-167`

## 1. Purpose

本標準定義 Agent Skill source repository 從 package、validation、security review、release 到 consumer installation 的共同 contract。Repository-specific 能力可透過 extension / adapter / config 接入，但不得另建第二套 lifecycle、Security Gate、severity policy、review policy 或 validation-tool policy。

## 2. Normative terms

- **MUST / MUST NOT**：Standard v1 conformance 必要條件。
- **SHOULD / SHOULD NOT**：預設要求；偏離必須記錄理由與 evidence。
- **MAY**：合法 extension。

## 3. Authority, effective scope and reference implementation

### 3.1 Normative authority

`SyuanTsai-AI-Instructions/docs/standards/` **MUST** 是共用 policy 的唯一 authority。

Source repository **MUST NOT** 私自重新定義：

- canonical lifecycle；
- validation tool source / version policy；
- security severity / block semantics；
- suppression / exception policy；
- AI Review / Human Approval boundary；
- cross-repository profile / dependency / lifecycle semantics。

### 3.2 Effective scope

本 normative authority 的 conformance regression **MUST** 與 Standard v1 的 normative change 在同一 PR 建立或更新；Standard 本身不得依賴未來 migration task 才獲得最基本的 regression protection。

Source repositories 在宣稱 Standard v1 conformant 前 **MUST** 實作本標準要求的 repository-level conformance tests。SYP-155 負責第一個完整 reference implementation；SYP-156～159 依序 migration。Migration window 允許尚未遷移的 repository 維持 legacy layout，但不得宣稱已 conformant。

### 3.3 Reference implementation

`Skill-General` 在 SYP-155 完成後 **SHOULD** 作為 implementation reference。若 reference implementation 與本標準衝突，**MUST** 修正 implementation，或先修改本標準並完成 review/tests；不得以 implementation 現況覆蓋 normative policy。

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

Historical `.agents/skills/<skill-id>` source repositories 可在 SYP-155～159 migration 完成前繼續存在，但屬 **legacy source layout**，不是 Standard v1 reference layout。

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

### 4.5 `agents/openai.yaml` contract

本 Standard 將 OpenAI upstream `openai/skills` / `openai/codex` 的 `agents/openai.yaml` interface constraints 視為最低相容性基線；內部規範可以更嚴格，但不得比上游最低 contract 更寬鬆。

`agents/openai.yaml` **MUST** 不只存在，還必須通過內容驗證：

- 檔案 **MUST** 是 syntactically valid YAML；
- root **MUST** 是 mapping/object；
- YAML keys **MUST** remain unquoted；all string scalar values **MUST** be quoted；
- `interface` **MUST** 存在且為 mapping/object；
- `interface.display_name` **MUST** 是 non-empty quoted string；
- `interface.short_description` **MUST** 是 25～64 characters inclusive 的 quoted string；
- `interface.default_prompt` **MUST** 是 non-empty quoted string；
- `interface.default_prompt` **MUST** 明確 reference exact `$<skill-id>` token，使 metadata routing identity 與 package stable ID 對得上；
- malformed YAML、quoted key、unquoted string value、缺欄位、空白欄位、`short_description` 長度超界或錯誤 Skill identity **MUST** fail closed。

Optional `interface` / dependency string fields若存在，也 **MUST** 遵守上游 quoted-string rule。Repository **MAY** 驗證額外 host metadata，但不得降低上述最低 contract。

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

下列 cross-source policy **MUST** 由 central Catalog / Standard 擁有，而非在 source repositories 重複成第二份 authority：

- profiles / selection；
- compatibility；
- cross-Skill dependencies；
- lifecycle / rename / removal；
- consumer routing policy；
- canonical validation tool source / version policy。

Source repository **MAY** 維護 derived/read-only display metadata，但 **MUST NOT** 讓 derived metadata 成為競爭 authority。

## 6. Pin, provenance and integrity contract

以下 properties **MUST** 分開命名與驗證：

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

Standard v1 將「release candidate 核准」與「安裝已核准 release」明確分開。

### 7.1 Development / release flow

```text
Controlled Candidate Acquisition
→ Integrity Verification
→ SkillSpector Static Security Scan
→ Repository Validation
→ Tests / Regression / Conformance
→ Conditional SkillSpector Semantic Scan
→ AI Review
→ Human Release Approval
→ Publish Approved Immutable Release
```

Human approval 在這條 flow 核准的是**特定 immutable release candidate**，不是核准某一台電腦的每次安裝。

### 7.2 Approved release installation flow

```text
Select Human-Approved Immutable Release
→ Controlled Acquisition
→ Integrity Verification
→ Install / Project to Consumer Location
→ Post-install Integrity Verification
```

使用者安裝已經 Human Approved 且綁定 immutable revision 的 released artifact **MUST NOT** 因 Standard v1 本身被要求再次取得 human approval。

Host、企業政策或實際操作若涉及新的外部寫入、credential grant、elevated permission 或其他使用者授權，仍 **MAY / MUST** 依該操作自己的 authorization boundary 取得同意；這與 release approval 是不同概念。

Repository **MUST** 維持上述 ordering semantics。Extension **MAY** 在相鄰 stage 內增加 stronger checks，例如 clean-HEAD、package binding、routing tests、credential E2E；不得跳過前置 gate 或另建不同 policy pipeline。

## 8. Canonical validation entry and validation tool policy

### 8.1 Single validation entry

每個 conformant repository **MUST** 提供一個 canonical validation entry point，例如 repository root script `scripts/Validate.ps1`（實際名稱可由 adapter/config 決定）。

Canonical entry **MUST**：

- 可由 developer local、pre-push（若存在）與 CI 呼叫；
- 執行同一 stage policy、severity policy 與 fail-closed semantics；
- 接受 host/CI 必要的 machine-readable output option；
- 在缺少 required analyzer、required test runner、required config 或 required evidence 時 fail closed；
- 不因 CI/local 而改變「什麼算 pass/block」；
- 只允許 execution adapter 差異，例如 path、credential source、artifact destination、TTY availability。

Component/diagnostic scripts **MAY** 存在，但 **MUST NOT** 成為繞過 canonical entry 的 release path。

### 8.2 Latest-stable tool and trusted-source policy

中央 machine-readable policy 位於 `docs/standards/validation-toolchain.json`；中央 resolver / trust anchor 位於 `scripts/Resolve-StandardValidationTool.ps1`。

正式 validation / conformance / security gate **MUST** 預設使用每個工具在 validation run 開始時從**核准來源**可解析到的 **latest stable** version，而不是 repository 各自長期 pin 不同版本。

`source` **MUST** 視為供應鏈安全屬性，不是描述性 metadata。Standard v1 的核准 source trust anchors 為：

- SkillSpector → `NVIDIA/SkillSpector`；
- skill-validator → `github.com/agent-ecosystem/skill-validator/cmd/skill-validator`；
- skill-tools → `npm:skill-tools`，且 approved registry **MUST** 為 `https://registry.npmjs.org/`；
- Pester → `PowerShellGallery:Pester`。

Canonical resolver **MUST** 在解析任何工具前先驗證 machine-readable policy 中**全部**正式工具的 exact approved source 與 `channel = latest-stable`。對具可替換 distribution endpoint 的 provider，實際 registry / repository endpoint 也 **MUST** 驗證；任一 source 或 endpoint 偏離 trust anchor，即使 package name 與 channel 不變，整個 canonical validation **MUST** fail closed。

對 `skill-tools`，resolver **MUST**：

- 驗證中央 policy 的 registry 為 `https://registry.npmjs.org/`；
- 在任何 package lookup 前拒絕不符的 `NPM_CONFIG_REGISTRY` 或 `npm config get registry`；
- 每個 `npm view` / `npm install` **MUST** 明確指定 approved registry；
- resolved identity **MUST** 包含 package integrity 與 registry evidence。

對 `skill-validator`，Go `@latest` 解析結果只有純 release SemVer（例如 `v1.6.1`）可視為 latest stable；prerelease（例如 `v1.7.0-rc1`）與 pseudo-version **MUST** fail closed，不得因 Go 能解析就當成 stable release。

Canonical workflow **MUST** 透過中央 resolver 取得 validation tool；**MUST NOT** 在 workflow 另寫一套獨立 `Install-Module`、`npm install`、`go install`、`pip install` 或其他來源選擇邏輯來繞過中央 policy。Resolver 可以使用 provider-specific package manager，但 provider、package/repository identity 與 validation semantics 由中央 resolver 決定。

`validation-toolchain.json` 的 `recordResolvedIdentityWhenAvailable` **MUST** 為 `true`，並由 authority regression 保護。

每次 canonical validation run **MUST**：

1. 在 run 開始時驗證所有 tool source trust anchors；
2. 依中央 policy 從 approved source / endpoint 解析該 run 所需工具的 latest stable version；
3. 記錄 resolved version；
4. provider 可提供 immutable identity、module/package coordinate、package integrity、release commit 或 asset digest 時 **MUST** 記錄 resolved identity；
5. 將 resolved toolset freeze 到該次 run 結束，避免同一 candidate 的不同 stage 在 run 中途漂移；
6. 顯示足以 audit 的 source、endpoint、version 與 identity evidence；
7. 若 approved source/endpoint、latest stable、identity/integrity evidence 無法依 provider contract 解析、取得或驗證，fail closed，不得 silent fallback 到 cached old version 或另一個 source。

合法 validation tool source / endpoint 變更是**trust-root change**。此類 PR **MUST** 同時修改：

- `validation-toolchain.json`；
- `Resolve-StandardValidationTool.ps1` trust anchor / resolver adapter；
- authority regression；
- 變更理由與供應鏈 review evidence。

只修改 JSON `source` / registry 而沒有同步更新 resolver/test **MUST** 被 conformance gate 阻擋。

Scheduled update job 與正式 validation 不需要兩套版本政策；下一次正式 validation run 自然重新解析當時 latest stable。

**Compatibility lane exception**：為證明 Windows PowerShell 5.1、舊 Pester 或其他明確 legacy compatibility，額外 test lane **MAY** pin 舊版，但必須記錄 explicit purpose，且該 lane **MUST NOT** 成為唯一或 canonical release/security gate。

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

Validation **MUST** 檢查預期 analyzer set / capabilities 已完成，而不是只看 exit code。每次 run **MUST** 顯示 resolved SkillSpector source、version、identity 與 analyzer completeness evidence。

因 Standard v1 預設使用 latest stable，analyzer inventory 可能隨 release 變更；adapter **MUST** 針對實際 resolved version 驗證其完整性，不能拿舊版 analyzer allowlist 假裝新版完整。

### 9.4 Severity handling

Repository **MUST** 使用 central severity semantics：

- **Critical / High**：預設 BLOCK；只有正式 approved exception 才可放行。
- **Medium**：需要 triage。若屬 exploit/security boundary violation 或 analyzer 明確定義為 blocking 類型，BLOCK；其餘需有 resolution/suppression evidence 才可 release。
- **Low / Informational**：可不阻擋，但 **SHOULD** 保留 evidence 供 trend/review；不得藉由降級 severity 隱藏實質 High/Critical risk。

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

例如下列風險可能 BLOCK：

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
- `agents/openai.yaml` YAML syntax、unquoted keys、quoted string values、required fields、`short_description` 25～64 character bound 與 `$<skill-id>` identity binding；
- safe relative paths；
- source/inventory integrity contract；
- repository-specific declared adapters/config；
- no unapproved policy fork。

### 12.2 Tests

本 authority repository **MUST** 維護 `tests/skill-repository-standard.Tests.ps1`，至少保護：

- normative documents / evidence index；
- validation-tool approved sources 與 approved distribution endpoints；
- latest-stable channel、resolved identity recording 與 central resolver trust boundary；
- 負向 source / registry tampering fail-closed behavior；
- stable Go release semantics，包含 prerelease / pseudo-version rejection；
- `agents/openai.yaml` unquoted-key / quoted-string / 25～64 / identity contract；
- release/install approval boundary；
- Standard self-conformance requirement；
- review matrix 與 SYP-167 authority deliverables 不得過期。

每個 conformant Skill repository **MUST** 有：

- Standard v1 conformance regression；
- repository contract regression；
- domain behavior regression（當 package 存在 executable/domain logic 時）；
- security adapter/severity/suppression regression（當使用 adapter 或 exception 機制時）。

Tests **MUST NOT** 因 migration 而弱化既有 integrity/security/regression guarantees。

## 13. AI Review and Human Release Approval

### 13.1 AI Review

AI Review **SHOULD** 聚焦：

- Skill intent 與實作一致性；
- capability/permission/data-flow 合理性；
- static/semantic findings triage；
- test gap / regression risk；
- release evidence completeness；
- suppression/exception 是否符合 policy。

AI Review **MUST NOT** 自行批准 High/Critical accepted-risk exception 或繞過 Human Release Approval。

### 13.2 Release Approval

Human Release Approval **MUST** 是下列事項的最終邊界：

- publish/release candidate；
- new/changed security exception；
- accepted High/Critical risk；
- intentional analyzer suppression that affects release outcome；
- normative policy / validation source trust-root change。

Approval **MUST** 綁定被 review 的 immutable candidate identity；candidate bytes / commit 改變後，舊 approval 不得沿用。

自動化 **MAY** 在沒有 blocking finding且 policy 未要求人工 security exception review 時準備 candidate，但不得將「AI 認為合理」等同 human approval。

### 13.3 Approved Release Installation

安裝流程的 authority 是**已 Human Approved 的 immutable released artifact**與其 integrity/provenance evidence。

Standard v1 **MUST NOT** 要求同一 approved release 每次在不同 consumer 安裝時重新做人工作品核准。安裝時仍必須做 acquisition/integrity/post-install verification，並遵守 host 對實際權限、credential 或 external-write operation 的獨立 authorization policy。

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

Exception **MUST NOT** 建立替代 lifecycle、永久排除 Security Gate，或把「使用舊 validation tool / 未核准 tool source」變成無期限預設。若 compatibility lane 需要舊版工具，必須使用 8.2 的 compatibility-lane boundary；未核准 source 不屬於 compatibility exception。

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
- 使用 canonical trusted-source + latest-stable tool policy、severity/fail semantics；
- 不得跳過 Static Security、Repository Validation、Tests 或 required Semantic Scan；
- local/CI/pre-push 使用同一判斷；
- 不得把 temporary evidence 寫成 uncontrolled tracked state。

## 16. Release, publish and install

### 16.1 Publish approved immutable release

Release candidate **MUST** 綁定單一 immutable candidate revision，且所有 canonical validation stages 與 Human Release Approval **MUST** 對同一 candidate identity 生效。

在 validation/approval 完成後 candidate bytes 改變，**MUST** 重新執行受影響 stages並重新取得 release approval；不得將舊 scan/test/approval evidence 套用到新 commit。

GitHub-hosted dedicated Skill repositories **SHOULD** 執行 host publishing compatibility dry run 作 extension acceptance。

### 16.2 Install approved immutable release

Install **MUST**：

- 只選擇已核准且可追溯到 immutable candidate 的 release/package；
- controlled acquisition validated immutable commit/package；
- 保存必要 provenance；
- 不把 secret 寫入 package/manifest；
- 安裝後重新驗證 expected package identity / per-file integrity；
- integrity mismatch 時 fail closed / rollback，不得 silent repair 成未知內容。

只要安裝的是相同 approved immutable release，Standard v1 本身不要求重複 Human Release Approval。

## 17. Conformance levels

Repository 要宣稱 Standard v1 conformant，**MUST** 證明：

1. source/package/inventory contract；
2. `SKILL.md` 與 `agents/openai.yaml` metadata contract；
3. canonical lifecycle stage ordering；
4. single validation entry contract；
5. validation tool approved-source / approved-endpoint enforcement；
6. latest-stable resolution / stable-release semantics / resolved identity / per-run freeze evidence；
7. SkillSpector Static Gate + analyzer completeness；
8. severity/fail-closed semantics；
9. tests/regression/conformance；
10. semantic trigger handling；
11. AI Review / Human Release Approval boundary；
12. approved-release installation semantics；
13. suppression/exception contract；
14. release/install/post-install integrity；
15. repository-specific deviations 僅存在於 approved adapter/config/exception。

Conformance report **MUST** 明確列出 deviations；若沒有，記錄 `None`，不得省略此欄位。

## 18. Migration and backward compatibility

SYP-167 **MUST NOT** 直接改寫五個 source repositories 或 production Catalog/Lock pins。

Migration 順序：

1. SYP-167：建立 Standard v1、cross-repository review、machine-readable validation-tool policy、trusted-source resolver、authority-level regression tests 與 Standards Conformance CI；
2. SYP-155：`Skill-General` 建立第一個完整 canonical validator、SkillSpector integration 與 repository conformance tests；
3. SYP-156～159：其餘 repositories fan-out migration；
4. 每個 source migration 合併並驗證後，才更新 central Catalog/Lock source path / immutable pins；
5. production consumer migration 必須維持 transactional/fail-closed integrity guarantees。

因此現行 central Catalog/Lock 仍可在 migration window pin legacy `.agents/skills/...` source path。Standard v1 定義的是 migration target，不要求 SYP-167 在尚未遷移 source repositories 時破壞 production runtime。

## 19. Standard change contract

任何修改 MUST / MUST NOT、canonical lifecycle、tool source/version policy、security gate、metadata contract、integrity contract、approval boundary 或 exception policy 的 PR **MUST**：

1. 修改本 normative document；
2. 同一 PR 更新 `tests/skill-repository-standard.Tests.ps1` 與必要 machine-readable policy；
3. tool source / resolver behavior 變更時，同一 PR 更新 `scripts/Resolve-StandardValidationTool.ps1` trust anchor / adapter 與負向 regression；
4. 說明對 reference implementation與已 conformant repositories 的影響；
5. 重新執行 authority-level conformance regression；
6. 經 Human Release/Policy Review 後才可 merge/fan out。

這項規則自 Standard v1 首次 merge 前即生效；不延後到 SYP-155。

## 20. Prohibited patterns

下列做法 **MUST NOT**：

- source repo 與 consumer host 各維護一份 Skill fork；
- hard-code CI Skill list 造成新增 Skill 可繞過 security gate；
- local、pre-push、CI 使用不同 pass/block policy；
- scanner/analyzer 未完整執行仍 pass；
- 只驗證 validation tool `channel = latest-stable` 而不驗證 exact approved `source` / distribution endpoint；
- `skill-tools` 受 `.npmrc` / `NPM_CONFIG_REGISTRY` 導向未核准 registry，或 `npm view/install` 未顯式指定 approved registry；
- 將 Go prerelease / pseudo-version 當成 `skill-validator` latest stable；
- workflow 自行從 package manager / repository 安裝 canonical tool 而繞過中央 resolver；
- canonical validation 長期固定舊工具而不解析中央 latest-stable policy；
- 同一 validation run 中途漂移 tool version；
- provider 可提供 resolved identity / integrity evidence 卻不記錄；
- 將 repository tree fingerprint 稱為 per-Skill `contentSha256`；
- 使用 broad scanner suppression 隱藏 findings；
- 將 legitimate network/MCP/script capability 一律視為 vulnerability；
- 將 AI Review 當作 Human Release Approval；
- 將每次 approved release installation 誤當成新的 release approval；
- 只檢查 `agents/openai.yaml` 存在而不驗證 YAML、unquoted keys、quoted strings、25～64 `short_description`、required fields 與 Skill identity；
- 在 source repository 私自建立與本標準競爭的 lifecycle/security/tool policy。
