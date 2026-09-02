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

本文件的字元長度一律以有效 UTF-8 解碼後的 Unicode scalar value 數量計算；不得以 UTF-16 code unit、grapheme cluster 或 encoded byte 數量替代。無法解碼為有效 UTF-8 的文字 **MUST** fail closed。

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

### 3.2 Authority distribution and revision binding

唯一 authority 不代表 source repository 可以在未驗證的情況下複製本目錄。Conformant repository 的 canonical validator **MUST** 從受控 provider 取得一個 immutable authority snapshot，並在執行任何 authority-derived policy 前綁定及驗證：

- canonical authority repository identity；
- full immutable authority Git commit；
- acquired authority bundle/archive 的 SHA-256；
- snapshot 內實際使用的 Standard、machine-readable policy、schema 與 resolver file inventory/hash。

使用 mutable `main`、branch、moving tag、未驗證 working-tree copy，或只記錄 `v1` 而沒有 authority commit/hash，均 **MUST NOT** 作為 conformance 或 release gate authority。Vendored/cache copy **MAY** 存在，但只能是由上述 immutable snapshot 驗證出的 derived copy，不得成為第二份 authority。

Conformance evidence **MUST** 記錄 `standardVersion`、authority repository、authority commit、authority bundle hash 與實際 authority file inventory/hash，使同一份報告可重現其判斷基線。Authority revision 改變時必須重新驗證；舊 revision 的 conformance evidence 不得宣稱涵蓋新 revision。

### 3.3 Effective scope

本 normative authority 的 conformance regression **MUST** 與 Standard v1 的 normative change 在同一 PR 建立或更新；Standard 本身不得依賴未來 migration task 才獲得最基本的 regression protection。

Source repositories 在宣稱 Standard v1 conformant 前 **MUST** 實作本標準要求的 repository-level conformance tests。SYP-155 負責第一個完整 reference implementation；SYP-156～159 依序 migration。Migration window 允許尚未遷移的 repository 維持 legacy layout，但不得宣稱已 conformant。

### 3.4 Reference implementation

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

- 使用 lowercase kebab-case，exact grammar 為 `^[a-z0-9]+(?:-[a-z0-9]+)*$`（不得以 hyphen 開頭/結尾或使用 consecutive hyphens）；
- 最長 64 字元；
- 建立後不得因 repository、profile、host、版本或目錄 migration 改變 identity；
- 與 package directory 及 `SKILL.md` frontmatter `name` 一致。

Rename **MUST** 使用新 stable ID 並由 central Catalog lifecycle 處理 tombstone / replacement；不得原地 repurpose 舊 ID。未進 central Catalog 的獨立產品 **MUST** 在 product-local extension config 依同一 tombstone/replacement semantics 保存 lifecycle evidence，不得自行發明不同 rename 語意。

### 4.4 Required files

每個 active Skill package **MUST** 包含：

- `SKILL.md`；
- `agents/openai.yaml`。

Skill-specific `scripts/`、`references/`、`assets/` **MAY** 存在。Repository root script **SHOULD** 僅處理 repository-level validation、release、pin/provenance、orchestration 或 adapters；Skill 自己的 domain implementation **SHOULD** 保持在 Skill package 內。

### 4.5 `SKILL.md` contract

Standard v1 的 frontmatter baseline 以 [`openai/skills@49f948faa9258a0c61caceaf225e179651397431` 的 `quick_validate.py`](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.system/skill-creator/scripts/quick_validate.py) 為已 review evidence，並加上下列更嚴格的 parse/body requirements。採用新版 upstream baseline **MUST** 依第 19 節 review、更新 validator 與 regression；不得由 mutable branch 靜默改變 contract。

`SKILL.md` **MUST** 是有效 UTF-8 Markdown，並以第一行 `---` 開始、由後續獨立 `---` 行結束 YAML frontmatter。Frontmatter **MUST**：

- 可由 safe YAML parser 完整解析為單一 mapping/object；duplicate key、custom tag、malformed delimiter 或非 mapping root **MUST** fail closed；
- 只包含 `name`、`description`、`license`、`allowed-tools`、`metadata`；未知 top-level field **MUST** fail closed；
- 包含 string `name`，其值 **MUST** 符合第 4.3 節 stable ID grammar、最長 64 characters，且與 package directory exact case-sensitive match；
- 包含 non-empty string `description`，trim 後 **MUST** 非空、最長 1024 characters，且 **MUST NOT** 包含 `<` 或 `>`；
- 若 optional field 存在，其 value type **MUST** 通過該次 frozen `skill-validator` provider contract；validator 不得以 scalar coercion 接受錯誤 type，且 receipt 必須保留實際 provider/version 與結果。

Closing frontmatter delimiter 後 **MUST** 有至少一個 non-whitespace Markdown body character；只有 frontmatter 或空 body **MUST** fail closed。Validator **MUST** 使用完整 YAML/frontmatter parser；只以 regular expression 擷取 `name` 或檢查檔案存在不足以符合本節。

### 4.6 `agents/openai.yaml` contract

本 Standard 將 [`openai/skills@49f948faa9258a0c61caceaf225e179651397431` 的 `openai_yaml.md`](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.system/skill-creator/references/openai_yaml.md) 視為 Standard v1 已 review 的最低相容性基線；內部規範可以更嚴格，但不得比該 immutable upstream contract 更寬鬆。後續 upstream change 不會因 mutable default branch 自動改寫本 Standard；採用新版 baseline **MUST** 依第 19 節更新 pinned upstream revision、semantic schema、validator 與 regression evidence。

`agents/openai.yaml` **MUST** 不只存在，還必須通過內容驗證：

- 檔案 **MUST** 是 syntactically valid YAML；
- root **MUST** 是 mapping/object；
- YAML keys **MUST** remain unquoted；all string scalar values **MUST** be quoted；
- `interface` **MUST** 存在且為 mapping/object；
- `interface.display_name` **MUST** 是 non-empty quoted string；
- `interface.short_description` **MUST** 是 25～64 characters inclusive 的 quoted string；
- `interface.default_prompt` **MUST** 是 non-empty quoted string；
- `interface.default_prompt` **MUST** 明確 reference exact `$<skill-id>` token，使 metadata routing identity 與 package stable ID 對得上；
- `dependencies.tools[]` 若存在，`type` 在 Standard v1 **MUST** exact 為 quoted `"mcp"`；`value` / `description` / `transport` / `url` 若存在必須是 non-empty quoted string，且 `url` 必須是 absolute HTTPS URI；
- malformed YAML、quoted key、unquoted string value、缺欄位、空白欄位、`short_description` 長度超界或錯誤 Skill identity **MUST** fail closed。

Optional `interface` / dependency string fields 若存在，也 **MUST** 遵守上游 quoted-string rule。Repository **MAY** 驗證額外 host metadata，但不得降低上述最低 contract。

`docs/standards/schemas/openai-agent-metadata.schema.json` 只驗證 YAML 解析後的 semantic object/type/length baseline；quoted scalar、unquoted key 與 exact `$<skill-id>` binding 仍 **MUST** 由 YAML-aware validator 依本節驗證，不得誤稱 JSON Schema 能驗證 lexical YAML style。

## 5. Source inventory and central Catalog ownership

### 5.1 Source-owned inventory

Source repository **MUST** 提供 `catalog/source.json`，至少包含：

```json
{
  "schemaVersion": 2,
  "sourceId": "example-source",
  "repository": "https://github.com/example/example-source.git",
  "skillsRoot": "skills",
  "skills": [
    "example-skill"
  ]
}
```

Canonical semantic schema 是 `docs/standards/schemas/source-inventory-v2.schema.json`。`catalog/source.json` **MUST** 通過該 strict schema，且 executable validator **MUST** 另外驗證：

- 只允許 schema 宣告的 fields/types，unknown property **MUST** fail closed；
- `sourceId` 與該 repository 已核准的 stable source identity exact match；若 repository 參與 central composition，還必須與 central Catalog source ID exact match；
- `repository` 與正在驗證之 repository 的 canonical HTTPS clone identity exact match，不得含 credential、query、fragment 或 alternate host alias；
- `skillsRoot` exact 為 `skills`；
- `skills` 使用 ordinal ascending、沒有 duplicate 的 stable-ID string array；
- inventory 與 `skills/` 下實際 package directories 完全一致；未宣告 package 與宣告但不存在 package 都 **MUST** fail closed。

既有 `schemaVersion: 1` 曾同時出現 `skills: [{"id","path"}]` 與 `skills: ["id"]` 兩種不相容 shape，因此屬 ambiguous legacy input，不是 Standard v1 canonical source schema。Migration **MUST** 先辨識並完整驗證 legacy shape 與實際 directories，再明確輸出 schema v2；validator **MUST NOT** 以 shape guessing 將 schema v1 當作已符合 v2，或在原 `schemaVersion: 1` 下接受兩種 shape。

### 5.2 Central policy

下列 cross-source policy **MUST** 由 central Catalog / Standard 擁有，而非在 source repositories 重複成第二份 authority：

- profiles / selection；
- compatibility；
- cross-Skill dependencies；
- lifecycle / rename / removal；
- consumer routing policy；
- canonical validation tool source / version policy。

Source repository **MAY** 維護 derived/read-only display metadata，但 **MUST NOT** 讓 derived metadata 成為競爭 authority。

只服務單一獨立產品、且不進入 central Catalog/profile/lock/bootstrap 的 product-local orchestration metadata **MAY** 保留在該 product repository 的明確 extension config 中。`Skill-Darktide-Translate` 屬此類：它仍 **MUST** 提供 Standard v1 `catalog/source.json` source inventory，但其 Darktide-only selection、Standard-compatible lifecycle evidence、state/reservation 或 domain workflow metadata 可保留為 product-local extension；該 metadata **MUST NOT** 冒充 `catalog/source.json`、進入 `SyuanTsai-AI-Instructions` cross-source composition，或重新定義 canonical release lifecycle、Security Gate、severity、exception、Human Approval 或 validation-tool policy。

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
2. validator **MUST** 同時檢查 immutable Git tree mode 與 staged filesystem type；package tree 任一 symlink、junction/reparse point、device、socket、FIFO 或其他 non-regular/special entry **MUST** fail closed，不得 follow、忽略、依 archive materialization 偽裝成 regular file，或 hash link target；
3. path **MUST** 是有效 UTF-8 的 repository-relative forward-slash path；absolute/drive/UNC path、backslash、colon、U+0000～U+001F/U+007F control character（包含 tab/CR/LF）、empty segment、`.` 或 `..` segment 都 **MUST** fail closed；
4. path identity case-sensitive；validator 另 **MUST** 將每個 path 正規化為 Unicode NFC，先做 ordinal 比較，再至少將 ASCII `A`～`Z` 映射為 `a`～`z` 後做 ordinal 比較；任兩個不同 source paths 在任一比較下 collision，整個 package **MUST** fail closed。Consumer adapter 還 **MUST** 拒絕其 target filesystem 定義的額外 case/normalization collision；
5. ordinal 排序；
6. 每行為 `<path>\t<raw-file-sha256>\n`；由於第 3 點禁止 delimiter/control characters，record boundary 不得被 path 注入；
7. 串接 UTF-8 no-BOM bytes 後計算 SHA-256。

### 6.2 Immutable runtime source

Consumer/publisher **MUST NOT** 直接以 mutable `main`、branch 或 moving tag 作為 runtime content authority。Mutable ref **MAY** 作為 update-selection provenance，但內容執行、安裝與重現 **MUST** 綁定已解析的 immutable commit 與 integrity hashes。

### 6.3 Controlled acquisition

任何需要驗證/發布外部 candidate 的流程 **MUST**：

1. 解析候選 revision；
2. 以受控 provider 取得 immutable source；
3. 驗證 expected identity/hash；
4. 在隔離 staging 執行 security/validation；
5. 所有 preflight 完成前不得 mutation consumer target 或 publish state。

當流程使用本 Standard、中央 schema、machine-readable validation policy 或 resolver 時，controlled acquisition 還 **MUST** 依第 3.2 節取得及驗證同一 immutable authority snapshot。先從 mutable ref 或本機 copy 執行 resolver，再事後記錄 commit/hash，不符合「驗證後才執行」的 ordering。

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

Canonical CI 使用的 reusable action **MUST** 綁定 reviewed full commit SHA，不得只使用可移動的 major tag。Checkout **MUST** 關閉 persisted repository credentials；workflow 的 path trigger 與 merge-blocking bridge **MUST** 覆蓋所有 authority policy、resolver、workflow 與 authority-regression 檔案，且 whitespace/diff gate **MUST** 依實際 pull-request base 或 push-before SHA 驗證，不得在 `main` push 上退化成空 range。

對 `SkillSpector`，resolver **MUST**：

- 只接受 `NVIDIA/SkillSpector` GitHub latest release 中符合 `v<release-semver>` 的非 draft、非 prerelease 版本；
- 將 release tag、resolved commit、預期 wheel filename、GitHub asset SHA-256、wheel `METADATA` Name/Version、安裝後 `dist-info/METADATA` Name/Version 與 `skillspector` console entry point 綁定為同一 identity；
- checkout **MUST NOT** persist Git credentials；GitHub release resolution／asset acquisition 完成後，resolver gate **MUST** 在任何 approved-index candidate request 或其他 tool resolution 前移除 process-level `GITHUB_TOKEN` 與 `GH_TOKEN`；
- 使用 Python `-I` isolated mode 執行 venv 建立、helper candidate acquisition 與 pip offline resolution／install，避免 `PYTHONPATH`、`PYTHONHOME`、user site 或其他 inherited `PYTHON*` interpreter control 介入 canonical resolution；安裝後的 distribution Name／Version 與 `skillspector` console entry point **MUST** 直接由 run-owned venv 的 `.dist-info/METADATA`／`entry_points.txt` 靜態驗證，在該驗證完成前 **MUST NOT** 啟動 installed interpreter 或處理 site-packages `.pth` startup code；
- 只允許 `https://pypi.org/simple` 作為 Python dependency index，隔離 pip config、停用 cache、只接受 wheels，且 inherited `PIP_*` environment 採 deny-by-default；只有值已等於 approved index 的 `PIP_INDEX_URL` 可被接受；`REQUESTS_CA_BUNDLE`、`CURL_CA_BUNDLE`、`SSL_CERT_FILE`、`SSL_CERT_DIR` 等可重定向 transport trust 的 inherited environment **MUST** 在任何 network request 前 fail closed；
- 在任何 dependency network resolution 前拒絕 SkillSpector root wheel 的 direct URL / VCS / local-file dependency reference；approved-index acquisition **MUST** 由受版本與 SHA-256 綁定的 helper 直接讀取 `https://pypi.org/simple` 的 PEP 691 Simple JSON，依 PEP 440 版本與目前 interpreter wheel tag 明確排序，排除 yanked files，並在任何 candidate 進入 run-owned pool 前驗證 HTTPS endpoint／redirect、Simple JSON SHA-256、wheel filename／tag／`Requires-Python`、`METADATA` Name/Version、archive safe path 與所有 `Requires-Dist` direct references；pip **MUST NOT** 在線上探索 dependency metadata；
- root 與每個 dependency wheel 的 `METADATA` **MAY** 省略 `Requires-Python`，但若存在必須恰有一個非空、有效的 `SpecifierSet` 且涵蓋目前 interpreter；對 approved Simple JSON candidate，index `requires-python` 與 wheel `METADATA` 值必須各自有效，並在 PEP 440 parser 正規化後形成相同的 specifier set（允許不影響解析結果的空白與順序差異）；index 缺值／`null` 只允許 wheel 同樣省略。任何重複、錯型、不相容或 normalized set 不一致都必須在 candidate 進入 pip local pool 前 fail closed；
- candidate materialization **MUST** 採 lazy expansion：先只加入每個已知 project 的最高相容 candidate；若目前 local pool 無解，再為每個仍有候選的已知 project 加入下一個較舊 candidate，掃描其 metadata 並發現新 project，直到 pip 在 `--no-index --find-links=<verified-pool> --only-binary=:all:` 下完成 backtracking，或所有可用候選耗盡後 fail closed。不得把單一版本組合衍生的 transitive constraints 當成不可回溯的 top-level constraints；
- 將 offline pip selection report 嚴格限制於 verified pool，核對每個 selected path／Name／Version／SHA-256，再只複製 selected wheels 到 final wheelhouse；wrapper **MUST** 重新讀取 candidate inventory、raw report 與 selected closure，跨檔重算並核對 stable identities；resolver receipt **MUST** 綁定 exact helper SHA-256、stable candidate inventory identity、normalized selection-plan identity、selected closure identity、pip version 與 resolution rounds。Raw pip report hash 屬 run-local evidence，不得冒充 reproducible package identity；
- 在 run-owned isolated venv 與 wheelhouse 解析 direct/transitive dependency closure，依 normalized distribution name 的 ordinal order 記錄每個 selected wheel SHA-256 與 deterministic closure identity，再以 `--no-index --require-hashes --no-deps` 從該 wheelhouse 安裝；`-Install` 產物只屬於同一 frozen validation run，由 central gate 控制 lifecycle，不得跨 run 當成一般 persistent install 重用；
- installed metadata 與 entry-point path **MUST** 拒絕 reparse-backed content；resolved identity 與 machine-readable receipt **MUST** 綁定 `credentialIsolation=github-token-cleared-before-python`、`installedMetadataVerification=static-dist-info-metadata`、console entry point、helper／candidate／plan／selected-closure identity、pip version／resolution rounds／candidate count、dependency closure、executable 與 installed closure SHA-256；
- 在 release、wheel metadata、asset digest、dependency closure、installed metadata、entry point 或 executable identity 任一不一致時 fail closed。

對 `skill-tools`，resolver **MUST**：

- 驗證中央 policy 的 registry 為 `https://registry.npmjs.org/`；
- 在任何 package lookup 前拒絕不符的 `NPM_CONFIG_REGISTRY` 或 `npm config get registry`；
- 以空白 user/global config 與受控 project config 隔離 npm 設定，並在任何 lookup 前拒絕 inherited `NPM_CONFIG_*`（唯一例外為值已等於 approved registry 的 `NPM_CONFIG_REGISTRY`）、`NODE_*`、`SSL_CERT_FILE` 與 `SSL_CERT_DIR` transport/runtime overrides；
- 每個 `npm view` / `npm install` **MUST** 明確指定 approved registry；
- resolved identity **MUST** 包含 package integrity 與 registry evidence。

對 `skill-validator`，Go `@latest` 解析結果只有純 release SemVer（例如 `v1.6.1`）可視為 latest stable；prerelease（例如 `v1.7.0-rc1`）與 pseudo-version **MUST** fail closed，不得因 Go 能解析就當成 stable release。

Canonical authority workflow **MUST** 在中央 resolver 前，以 full commit SHA 固定受信任的 Go setup action、停用 cross-run cache，並安裝 `validation-toolchain.json` `goRuntimeVersion` 指定的 exact security-patched Go runtime。Resolver **MUST** 在任何 `go list` / `go install` 前以 native `go version` 驗證 exact runtime version，並把它綁入 resolved identity 與 machine-readable receipt；不得以 runner 預裝版本、mutable action tag 或 `GOTOOLCHAIN=auto` 取代這項證據。

`skill-validator` 的 module resolution 與 installation **MUST** 使用該次 resolver invocation 專用、初始為空的暫存 `GOMODCACHE` 與 `GOCACHE`，並在 invocation 結束後移除。Resolver **MUST** 在任何 `go list` / `go install` 前拒絕 inherited `GOMODCACHE`、inherited `GOCACHE`、`GOROOT`、`GOTOOLDIR`、target/build selector 與非空 `GOFLAGS`：shared module cache 可能重用 caller-controlled 的下載/解壓縮內容，shared build cache 可能重用非本次 trusted resolution 產生的 compilation output，`GOROOT` / target selectors 可替換 compiler、stdlib 或產物目標，而 `GOFLAGS` 可注入改變 build behavior 的參數。鎖定 `GOPROXY` / `GOSUMDB` 不能取代這些 build-input 與 cache isolation controls。

當受驗 package 包含本 Standard 定義的 `agents/openai.yaml` 時，central adapter **MUST** 以 exact `--allow-dirs=agents` 執行 `skill-validator validate structure`，明確宣告這個 platform metadata directory；不得以接受 exit code `2`、忽略 warning 或允許任意其他目錄取代。Machine-readable report 仍 **MUST** 為 `passed = true`、`errors = 0`、`warnings = 0`，且 central gate **MUST** 另外驗證 exact fixture/package inventory 與 `agents/openai.yaml` contract。

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

**Compatibility lane exception**：為證明 Windows PowerShell 5.1、舊 Pester 或其他明確 legacy compatibility，額外 test lane **MAY** pin 舊版，但必須記錄 explicit purpose，且該 lane **MUST NOT** 成為唯一或 canonical release/security gate。Central resolver **MUST** 驗證這三項 compatibility-lane boundary，而不是只讓 authority test 讀取 JSON metadata。

### 8.3 Required tool-to-stage execution contract

Resolver 的成功 receipt 只證明 acquisition/resolution，不代表 candidate 通過 validation。`validation-toolchain.json` `tools` 中沒有明確標為 optional/conditional 的每個 tool，都是 formal baseline tool；canonical validation **MUST** 在 run 開始時一次解析及 freeze 完整 required toolset，並實際執行：

- resolved SkillSpector executable：對 source inventory 中每個 active Skill 執行 Static Scan，並在第 11 節 trigger 成立時執行 Semantic Scan；
- resolved `skill-validator` executable：對每個 active Skill package 執行完整 package/spec validation，至少涵蓋第 4.5 節 `SKILL.md` contract；
- resolved `skill-tools` executable：使用該次已解析、已驗證的 package 執行 `check`（不得由 `npx` 或其他 wrapper 再解析另一版本）於每個 active Skill package；
- resolved Pester module：執行該 repository 的 Standard conformance、repository contract、security adapter 與適用的 domain regression suites。

Dedicated source repository **MUST** 以上述完整 active source inventory 作 coverage authority；不得因 inventory empty、hard-coded list empty 或 discovery failure 而 vacuously pass。Authority repository 本身刻意不保存 active shared Skill source，因此其 authority gate **MUST** 改用 candidate-bound、version-controlled 的受控 Skill fixture inventory 實際執行 SkillSpector Static Scan、`skill-validator` 與 `skill-tools check`，並用 resolved Pester 執行 authority regressions；fixture 至少包含一個完整有效的 canonical Skill package，且 fixture identity/content hash/coverage 必須進入同一 run evidence。Authority active inventory 為空 **MUST NOT** 成為略過四個 formal tools 的理由。

每個 stage evidence **MUST** 綁定同一 run ID、candidate identity、frozen tool identity、exact package inventory、invocation mode、exit status 與 machine-readable result（provider 支援時）；provider 沒有 machine-readable output 時，central adapter **MUST** 產生 deterministic structured receipt，且不得把 unparsable console prose 當成 pass。漏執行 tool/package、只 install/resolve/print version、使用不同 tool identity、non-zero exit、timeout、crash 或缺少 required result，都 **MUST** fail closed。

若未來某 baseline tool 改為 conditional、被替代或只作 diagnostic，該變更屬 validation-tool policy change，**MUST** 先依第 19 節在 central machine-readable policy、resolver/adapter 與 authority regression 明確建模；source repository 不得自行略過。

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

- immutable authority snapshot revision/hash binding；
- `catalog/source.json` schema v2、repository binding、ordinal unique inventory；
- stable IDs；
- package inventory exact match；
- required files；
- `SKILL.md` valid YAML frontmatter、allowed fields/types、required `name`/`description`、length/identity 與 non-empty body；
- `agents/openai.yaml` YAML syntax、unquoted keys、quoted string values、required fields、`short_description` 25～64 character bound 與 `$<skill-id>` identity binding；
- safe relative paths、non-regular entry rejection 與 normalization/case collision rejection；
- source/inventory integrity contract；
- repository-specific declared adapters/config；
- no unapproved policy fork。

### 12.2 Tests

本 authority repository **MUST** 維護下列 authority regression：

- `tests/skill-repository-standard.Tests.ps1`：normative policy、toolchain trust anchors、approved Simple JSON acquisition／offline backtracking／cross-file evidence 與核心 contract；
- `tests/skill-repository-workflows.Tests.ps1`：immutable action pin、credential isolation、authority path trigger、required bridge 與 event-aware diff range；
- `tests/standard-validation-resolver-hardening.Tests.ps1`：static dist-info／entry-point verification、metadata header boundary、`.pth` startup-code avoidance、GitHub token ordering、ordinal dependency closure、native-command resolution、exact release-asset URI 與 compatibility-lane enforcement。

上述 regression 至少保護：

- normative documents / evidence index；
- validation-tool approved sources 與 approved distribution endpoints；
- latest-stable channel、resolved identity recording 與 central resolver trust boundary；
- 負向 source / registry / compatibility-policy tampering fail-closed behavior；
- stable Go release semantics，包含 prerelease / pseudo-version rejection；
- `agents/openai.yaml` unquoted-key / quoted-string / 25～64 / identity contract；
- `SKILL.md` parsed frontmatter、required fields、allowed fields/types、length、identity 與 non-empty body contract；
- source inventory schema v2、authority distribution binding 與 delimiter-safe portable path contract；
- formal tools 必須實際覆蓋完整 active package inventory，而不只是 resolution/install receipt；
- authority repository 沒有 active Skill source 時，四個 formal tools 仍必須對 candidate-bound controlled fixture/test inventory 實際執行，不得 vacuous pass；
- immutable workflow action pin、non-persisted checkout credentials、authority trigger/path-filter coverage、event commit range 與共用 merge-blocking gate wiring；
- SkillSpector run-owned isolated installation、resolver credential lifetime、static installed dist-info／entry-point verification，以及禁止 identity verification 階段執行 installed `.pth` startup code；
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

自動化 **MAY** 在沒有 blocking finding 且 policy 未要求人工 security exception review 時準備 candidate，但不得將「AI 認為合理」等同 human approval。

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

- analyzer finding，或本 Standard 明確標示為 exception-capable 的 requirement；
- business/technical necessity；
- affected Skill(s)；
- risk assessment；
- compensating controls；
- owner；
- review/expiry condition。

Exception **MUST NOT** 建立替代 lifecycle、永久排除 Security Gate，或把「使用舊 validation tool / 未核准 tool source」變成無期限預設。若 compatibility lane 需要舊版工具，必須使用 8.2 的 compatibility-lane boundary；未核准 source 不屬於 compatibility exception。

### 14.3 Non-waivable core

除非先依第 19 節修改 normative authority，repository exception **MUST NOT** 豁免或降低下列 core requirements：

- immutable authority/candidate acquisition、identity、provenance、integrity 與 post-install verification；
- complete active package inventory discovery，以及 required Static Scan、Repository Validation、formal baseline tool execution、tests 與 triggered Semantic Scan；
- canonical gate 的 approved tool source/endpoint、latest-stable resolution、stable-release semantics、resolved identity 與 per-run freeze；第 8.2 節明確隔離的 non-canonical compatibility lane 仍依其 boundary 處理；
- scanner/analyzer completeness、unparsable/missing/error fail-closed semantics；
- single canonical validation entry 與 local/pre-push/CI 相同 pass/block policy；
- Human Release Approval、approval-to-immutable-candidate binding，以及 AI Review 不得替代 human approval；
- suppression/exception 的 narrow scope、owner、expiry、evidence 與 Human Approval；
- Standard/Catalog 的唯一 policy authority 與禁止競爭 authority。

第 9.4 節允許 Human Approved High/Critical accepted-risk exception，僅豁免該 exact finding 的 release outcome；它 **MUST NOT** 豁免 scanner 執行、finding preservation、candidate binding、compensating controls 或 approval evidence。未被本 Standard 明確標成 exception-capable 的 MUST/MUST NOT 若無法遵守，repository 必須回報 non-conformant，而不是用 local exception 宣稱 conformant。

## 15. Repository-specific extension points

Repository **MAY** 增加 extension stage/check，例如：

- clean-HEAD binding；
- package/source receipt binding；
- deterministic source pin evidence；
- routing regression；
- `gh skill publish --dry-run`（僅在 `gh` 已有 central extension-tool declaration 後）；
- Jira/MCP/credential E2E；
- state/reservation/recovery validation；
- Windows byte-preservation tests。

`validation-toolchain.json` 的 baseline tool set 與 repository-specific extension tool 必須明確區分。任何會影響 canonical pass/block/release outcome 的額外 executable（例如 `gh`）**MUST** 先由 central machine-readable policy 宣告其 provider、package/repository identity、distribution endpoint、version/stability rule、resolved identity evidence 與 resolver/host-tool verification adapter。Source repository **MAY** 宣告需要哪一個已核准 extension tool 及其 stage arguments，但 **MUST NOT** 自行選擇 tool source、endpoint 或 version policy。尚無 central declaration 的 executable 只能作 non-authoritative diagnostic，**MUST NOT** 成為 required release gate。

Remote API、MCP 或 connector capability 若沒有 package-manager/latest-stable 語意，不得虛構 tool version；其 extension config 仍 **MUST** 綁定 endpoint/transport、required capability、credential/permission boundary、read/write authorization 與 deterministic test adapter。這些 product capability metadata 不改變 baseline validation-tool authority。

Extension **MUST**：

- 由 config/adapter/declared stage 表達；
- 對 executable tool 使用上述 central trusted-source/version policy，並一律沿用 canonical severity/fail semantics；
- 不得跳過 Static Security、Repository Validation、Tests 或 required Semantic Scan；
- local/CI/pre-push 使用同一判斷；
- 不得把 temporary evidence 寫成 uncontrolled tracked state。

## 16. Release, publish and install

### 16.1 Publish approved immutable release

Release candidate **MUST** 綁定單一 immutable candidate revision，且所有 canonical validation stages 與 Human Release Approval **MUST** 對同一 candidate identity 生效。

在 validation/approval 完成後 candidate bytes 改變，**MUST** 重新執行受影響 stages 並重新取得 release approval；不得將舊 scan/test/approval evidence 套用到新 commit。

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

1. immutable authority snapshot repository/commit/bundle hash/file inventory；
2. source/package/schema-v2 inventory contract；
3. `SKILL.md` 與 `agents/openai.yaml` metadata contract；
4. canonical lifecycle stage ordering；
5. single validation entry contract；
6. validation tool approved-source / approved-endpoint enforcement；
7. latest-stable resolution / stable-release semantics / resolved identity / complete per-run toolset freeze evidence；
8. every formal baseline tool 的 actual invocation 與完整 active package coverage；
9. immutable workflow action pin、non-persisted checkout credentials、authority trigger coverage 與 event-aware diff evidence；
10. SkillSpector Static Gate + analyzer completeness；
11. severity/fail-closed semantics；
12. tests/regression/conformance；
13. semantic trigger handling；
14. AI Review / Human Release Approval boundary；
15. approved-release installation semantics；
16. suppression/exception contract 與 non-waivable core；
17. release/install/post-install integrity；
18. repository-specific deviations 僅存在於 approved adapter/config/exception。

Conformance report **MUST** 明確記錄 `standardVersion`、authority repository、authority commit、authority bundle hash、authority file inventory、candidate identity、validation run/toolset identity、covered Skill inventory 及 deviations；若沒有 deviation，記錄 `None`，不得省略此欄位。只寫 `Standard v1` 而沒有 immutable authority revision/hash 的 report 不可作為可重現 conformance evidence。

## 18. Migration and backward compatibility

SYP-167 **MUST NOT** 直接改寫五個 source repositories 或 production Catalog/Lock pins。

Migration 順序：

1. SYP-167：建立 Standard v1、cross-repository review、machine-readable validation-tool policy、trusted-source resolver、authority-level regression tests 與 Standards Conformance CI；
2. SYP-155：`Skill-General` 建立第一個完整 canonical validator、source inventory schema v2、SkillSpector integration 與 repository conformance tests；
3. SYP-156～159：其餘 repositories fan-out migration；
4. 第一次將 production source path repin 到 `skills/<id>` 前，central Catalog/Lock schema、parser、lock generator、acquisition/composition 與 manifest provenance contract **MUST** 先以明確 versioned migration 支援 source/target 分離；不得讓既有只接受 `.agents/skills/<id>` 的 executable contract 先讀到新 path；
5. 每個 source migration 合併並驗證後，才以同一受驗證 migration 更新 central Catalog/Lock source path / immutable pins；
6. production consumer migration 必須維持 transactional/fail-closed integrity guarantees。

因此現行 central Catalog/Lock 仍可在 migration window pin legacy `.agents/skills/...` source path。Standard v1 定義的是 migration target，不要求 SYP-167 在尚未遷移 source repositories 時破壞 production runtime。

## 19. Standard change contract

任何修改 MUST / MUST NOT、canonical lifecycle、tool source/version policy、security gate、metadata contract、integrity contract、approval boundary 或 exception policy 的 PR **MUST**：

1. 修改本 normative document；
2. 同一 PR 更新 `tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1`、`tests/standard-validation-resolver-hardening.Tests.ps1` 中受影響的 regression 與必要 machine-readable policy；
3. tool source / resolver behavior 變更時，同一 PR 更新 `scripts/Resolve-StandardValidationTool.ps1` trust anchor / adapter 與負向 regression；
4. workflow authority/merge enforcement 變更時，同一 PR 更新 workflow regression、dedicated authority trigger 與 Ruleset-required bridge；
5. 說明對 reference implementation 與已 conformant repositories 的影響；
6. 重新執行 authority-level conformance regression；
7. 經 Human Release/Policy Review 後才可 merge/fan out。

這項規則自 Standard v1 首次 merge 前即生效；不延後到 SYP-155。

## 20. Prohibited patterns

下列做法 **MUST NOT**：

- 以 mutable ref、未驗證 copy 或只有 `v1` label 取代 immutable authority commit/bundle/file hashes；
- source repo 與 consumer host 各維護一份 Skill fork；
- hard-code CI Skill list 造成新增 Skill 可繞過 security gate；
- 只 resolve/install/print formal validation tool receipt，卻未對完整 active package inventory 實際執行 tool-to-stage contract；
- local、pre-push、CI 使用不同 pass/block policy；
- scanner/analyzer 未完整執行仍 pass；
- 只驗證 validation tool `channel = latest-stable` 而不驗證 exact approved `source` / distribution endpoint；
- reusable workflow action 只綁定 mutable major tag，或 checkout 對後續 subprocess 持久化 repository credentials；
- authority workflow 的 path filter 未涵蓋 required merge-blocking bridge／regression，或 `main` push 的 whitespace gate 使用會退化成空 diff 的 range；
- `skill-tools` 受 `.npmrc` / `NPM_CONFIG_REGISTRY` 導向未核准 registry，或 `npm view/install` 未顯式指定 approved registry；
- `SkillSpector` 的 Python invocation 未使用 `-I` isolated mode，dependency acquisition 可繼承 caller-controlled Python/pip import、config、index、link、certificate 或 requirement controls，或 root/direct dependency metadata 可在 preflight 後進入 installation；
- 讓任何 root／transitive candidate 的 direct-reference metadata、未核准 endpoint／redirect 或未驗證 artifact 進入 offline pip candidate pool，或讓 pip 在線探索 dependency metadata；
- canonical CI 在第三方 validation-tool/package-manager/VCS subprocess 前保留 `actions/checkout` 或等效 checkout 的 persisted repository credential；
- `SkillSpector` resolver 在 helper／Python／pip／其他 tool resolution 前仍暴露 `GITHUB_TOKEN`／`GH_TOKEN`，或為了 installed-version verification 啟動已安裝的 interpreter 並處理 package-controlled `.pth` startup line；
- 將同一 validation run 的 run-owned validation tool 跨 run 重用，或把 application-level endpoint/direct-reference checks 說成完整 process network-egress sandbox；需要完整 egress guarantee 時 **MUST** 另加 transport/sandbox control；
- 將 Go prerelease / pseudo-version 當成 `skill-validator` latest stable；
- authority workflow 使用 mutable Go setup action、未安裝 policy 指定的 exact security-patched Go runtime，或 resolver 未在 module resolution 前驗證並記錄 runtime identity；
- 讓 `skill-validator` 解析或安裝繼承 shared / caller-controlled `GOMODCACHE`、`GOCACHE` 或非空 `GOFLAGS`，而未使用該次 invocation 專用的空白暫存 caches 與乾淨 build flags；
- workflow 自行從 package manager / repository 安裝 canonical tool 而繞過中央 resolver；
- canonical validation 長期固定舊工具而不解析中央 latest-stable policy；
- compatibility lane 可成為 canonical release/security gate，或 resolver 不驗證 compatibility-lane boundary；
- 同一 validation run 中途漂移 tool version；
- provider 可提供 resolved identity / integrity evidence 卻不記錄；
- 將 repository tree fingerprint 稱為 per-Skill `contentSha256`；
- 接受可將 tab/newline/control character 注入 inventory delimiter 的 path，或忽略 symlink/reparse/special/case-colliding package entry；
- 使用 broad scanner suppression 隱藏 findings；
- 用 repository-local exception 豁免第 14.3 節 non-waivable core；
- 將 legitimate network/MCP/script capability 一律視為 vulnerability；
- 將 AI Review 當作 Human Release Approval；
- 將每次 approved release installation 誤當成新的 release approval；
- 只檢查 `agents/openai.yaml` 存在而不驗證 YAML、unquoted keys、quoted strings、25～64 `short_description`、required fields 與 Skill identity；
- 在 source repository 私自建立與本標準競爭的 lifecycle/security/tool policy。
