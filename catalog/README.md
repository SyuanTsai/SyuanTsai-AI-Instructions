# Agent Skills Catalog contract

本目錄定義 AI Instructions Repository、外部 Agent Skills repositories 與目標 Repository 之間的 production 契約。Installer 與 multi-source bootstrap 直接使用這些 checked-in schemas、source pins、Catalog 與 immutable lock。共用 Skill source 只存在於 Catalog 列出的 external repositories；本 Repository 不保存副本。`Skill-Darktide-Translate`（SYP-88／SYP-92）維持獨立，不加入本 Catalog 或 Lock。

## 文件責任

| 文件 | Schema | 責任 |
| --- | ---: | --- |
| Skills Catalog | 1 | 宣告可用來源、穩定 Skill ID、群組、profiles、compatibility、dependencies 與 lifecycle。不得包含已解析 commit 或目標 Repository 的安裝狀態。 |
| Catalog source pins | 1 | 記錄維護者選定的 requested ref、完整 resolved commit 與顯示版本，供 lock generator 重現與 stale-check。 |
| Catalog lock | 1 | 將 catalog 及每個來源的 branch／tag／commit ref 鎖定到完整 commit SHA、archive hash 與每個 Skill 的 deterministic content hash。 |
| Managed manifest | 2 | 記錄目標 Repository 實際套用的每個檔案及完整 provenance，用於 customized／unmanaged 保護與安全更新。 |
| Personal sync configuration | 3 | 記錄個人 allowlist／exclusions、已安裝 AI-Instructions runtime/Catalog bundle 的 GitHub Repository 與完整 commit SHA、啟用 profiles，以及個別 Skill include／exclude。 |
| Runtime bundle metadata | 1 | 安裝時產生 `runtime-bundle.json`，記錄目前安裝的 AI-Instructions GitHub Repository 與 commit；launcher 必須與 schema v3 config 完全比對後才可啟動。 |

正式 schema 位於 [`schemas/`](schemas/)，去識別化、可通過 parser 的完整文件位於 [`examples/`](examples/)。`scripts/skills-catalog-contract.psm1` 負責 PowerShell 5.1 相容的跨文件驗證；JSON Schema 負責標準工具可讀的結構契約。

## Stable ID、rename 與 removal

- Skill `id` 使用 lowercase kebab-case，最長 64 個字元；建立後不得改作其他 Skill，也不得因目錄搬移、profile 或版本更新而改變。
- Group 與 profile 只是 metadata，不是 Skill identity；實體來源永遠維持 `.agents/skills/<skill-id>/**` 平面結構。
- Rename 必須新增新的 stable ID，並保留舊 ID tombstone：舊 entry 設為 `lifecycle.status = removed`、`replacementId = <new-id>`；新 entry 在 `aliases` 記錄舊 ID。
- Resolver 會把個人 `includeSkills`／`excludeSkills` 中的 removed ID 或 alias 遷移到 replacement stable ID；實體安裝目錄只使用 replacement ID。
- 無替代品的 removal 保留 `status = removed` tombstone，但不設定 `replacementId`；明確選取此類 removed Skill 必須 fail closed。
- Stable ID、source ID、profile ID、target path 或 alias 衝突都必須停止；不得使用 first-wins 或 last-wins。

## Profile 與 dependency resolution

Resolver 依固定順序處理：

1. 合併所有選定 profile 的 `includes`。
2. 套用個人 `includeSkills`，並遷移 alias／replacement ID。
3. 套用個人 `excludeSkills`，並遷移 alias／replacement ID；明確 exclude 最終優先。
4. 過濾 platform、shell 與 capability compatibility；profile 帶入但不相容的 Skill 會被移除，明確 `includeSkills` 指定但不相容則 fail closed。
5. 驗證 dependencies：
   - `hard`：必須存在且相容；若被 exclude 或無法滿足，整次 resolution 失敗。
   - `conditional`：依 `condition.operator` 判斷條件，且 `fallback.capability` 不可用時才要求 dependency。
   - `recommended`：只產生建議，不自動改變 resolved set。

Conditional operator 的 production semantics：

- `available`：condition capability 有 evidence 時成立。
- `missing`：condition capability 沒有 evidence 時成立。
- `unavailable`：目前 evidence model 中等同沒有可用 evidence。
- `missing-or-invalid`：無有效 evidence 時成立；格式不合法的 evidence 會在載入時直接拒絕。

`work-with-jira` 對 `configure-jira-api-access` 使用 `missing-or-invalid` conditional dependency。若已有核准且已設定的 `jira-cloud-connector` fallback，不強制安裝 API setup Skill。

## Compatibility contract

- `platforms` 至少一項；`any` 表示沒有作業系統限制。
- `shells` 使用可判讀的 capability expression，例如 `pwsh>=7`。
- `requiredCapabilities` 中每一項都必須滿足。
- `anyOfCapabilities` 的每個內層集合代表 alternatives；每個集合至少滿足一項。
- Capability `kind` 為 `command`、`connector` 或 `environment`；`state` 為 `available`、`authenticated` 或 `configured`。
- `command` + `available` 可由本機 `Get-Command` 驗證；authentication、connector、API/environment readiness 不得由名稱猜測，必須有明確 runtime evidence。
- Runtime evidence 透過 `AI_INSTRUCTIONS_CAPABILITY_EVIDENCE` 傳入 JSON array，例如：

```json
[
  { "kind": "connector", "id": "jira-cloud-connector", "state": "configured" },
  { "kind": "connector", "id": "datadog", "state": "configured" },
  { "kind": "command", "id": "felo-ai", "state": "authenticated" }
]
```

- 沒有 evidence 時採 fail-closed；不得只因 profile 被選取就假設 connector、authentication 或 API capability 可用。

## Source acquisition、pin 與 hash contract

- Catalog source `repository` 在 schema v1 僅接受 `https://github.com/<owner>/<repository>[.git]`。這是刻意的 deterministic boundary；其他 Git host 留待後續 schema version 擴充。
- GitHub source 一律使用完整 `resolvedCommit` 的 codeload ZIP。Lock generator 與 bootstrap 使用相同 archive provider，因此 `archiveSha256` 可直接比對同一 immutable archive bytes。
- `requestedRef` 保存 branch、tag 或 commit；`requestedRefType` 明確區分類型。
- `requestedRef` 與 `requestedRefType` 是維護者在 pin 更新當下記錄的 provenance metadata，不是 runtime 的安全輸入；branch 或 tag 後續可移動，因此 `-Check` 不以目前 remote ref 反推歷史關係。PR 必須審查 pin 更新時的 ref 解析證據，runtime 與 stale-check 則只以 `resolvedCommit`、`archiveSha256` 與 `contentSha256` 為權威。
- `resolvedCommit` 必須是 40 個小寫十六進位字元的完整 commit SHA。Bootstrap 不得重新以 mutable ref 決定內容。
- `catalogSha256` 是 Catalog JSON 原始檔案 bytes 的 SHA-256。
- `archiveSha256` 是 GitHub codeload archive 原始 bytes 的 SHA-256。
- Skill `contentSha256` 是 deterministic inventory 的 SHA-256：以 repository-relative forward-slash path 做 ordinal 排序，每行使用 `<path>\t<raw-file-sha256>\n` 的 UTF-8（無 BOM）資料串接後計算。
- Manifest `sha256` 是實際套用到 target path 的檔案 bytes SHA-256。
- `resolvedVersion`／`sourceVersion` 只供顯示與稽核；重現性仍以完整 commit SHA 與 hash 為準。

所有來源必須先下載、驗證並完成 staging，之後才可寫入目標 Repository；任一 pin 或 hash 無法驗證時不得留下部分 desired entries。

## Managed manifest v2 provenance

每個 `files[]` entry 都要能獨立回答：artifact type／ID、source Repository、requested ref、resolved commit、version、source path、target path 與套用內容 hash。Skill entry 的 source 與 target 必須維持 `.agents/skills/<artifactId>/...`。Manifest v2 不使用 Git submodule metadata。

## 個人設定 schema v3、安裝與升級

Installer 將 schema v1／v2 idempotent 升級為 v3：

- 原樣保留合法的 `autoCommitRepositoryUrls`、`excludedRepositoryUrls` 與 `excludedRepositoryPaths`。
- `catalog.repository` 是目前安裝 AI-Instructions runtime/Catalog/Lock bundle 的 canonical GitHub `.git` URL，不是任意外部 Catalog Repository；external Skill repositories 由 checked-in Catalog `sources[]` 管理。
- `catalog.ref` 是該 bundle 的完整小寫 commit SHA。
- schema v3 重新安裝時只保留使用者 `profiles`、`includeSkills`、`excludeSkills`，bundle repository/ref 必須與本次 installer checkout 一起前進；若 config 指向其他 Repository，installer fail closed。
- Installer 只允許其 launcher、runtime modules、Catalog 與 Lock bytes 完全等於 `HEAD` 的 clean tracked files；因此 installed bytes 可由 `catalog.ref` 重現。
- 新 runtime 先在 staging directory 完整複製、parse、驗證 Catalog/Lock 與 `runtime-bundle.json`，再 swap 到 active runtime；config 最後更新。正常例外會 rollback；rollback 本身失敗時保留 backup path；程序中斷造成的暫時不一致則由 identity-checking launcher fail closed。
- 缺少必要欄位、未知 schema、mutable ref、bundle identity mismatch 或同一 Skill 同時 include/exclude 時停止並回報。

Production wrapper 已完成 config validation、compatibility/dependency selection、routing、immutable acquisition、manifest v2 wiring 與 v1 safe migration。Mutation engine 只接受 wrapper 產生的已組合 archive 與 immutable provenance；舊單一來源直接呼叫模式已移除，既有 manifest v1 仍可在所有受管檔案未變更且未 staged 時安全升級。
