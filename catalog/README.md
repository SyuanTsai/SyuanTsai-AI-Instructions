# Agent Skills Catalog contract

本目錄定義 AI Instructions Repository、外部 Agent Skills repositories 與目標 Repository 之間的 production 契約。Installer 與 multi-source bootstrap 已直接使用這些 checked-in schemas、source pins、Catalog 與 immutable lock。

## 文件責任

| 文件 | Schema | 責任 |
| --- | ---: | --- |
| Skills Catalog | 1 | 宣告可用來源、穩定 Skill ID、群組、profiles、compatibility、dependencies 與 lifecycle。不得包含已解析 commit 或目標 Repository 的安裝狀態。 |
| Catalog source pins | 1 | 記錄維護者選定的 requested ref、完整 resolved commit 與顯示版本，供 lock generator 重現與 stale-check。 |
| Catalog lock | 1 | 將 catalog 及每個來源的 branch／tag／commit ref 解析成完整 commit SHA，並記錄 archive 與 Skill 內容 hash。不得包含個人 profile 選擇。 |
| Managed manifest | 2 | 記錄目標 Repository 實際套用的每個檔案及完整 provenance，用於 customized／unmanaged 保護與安全更新。 |
| Personal sync configuration | 3 | 記錄個人 allowlist／exclusions、Catalog HTTPS 位置與完整 commit SHA、啟用 profiles，以及個別 Skill include／exclude。不得記錄受管理檔案。 |

正式 schema 位於 [`schemas/`](schemas/)，去識別化、可通過 parser 的完整文件位於 [`examples/`](examples/)。`scripts/skills-catalog-contract.psm1` 負責 PowerShell 5.1 相容的跨文件驗證；JSON Schema 負責標準工具可讀的結構契約，parser 另外驗證 stable ID、交叉引用、重複值與安全路徑。

## Stable ID、rename 與 removal

- Skill `id` 使用 lowercase kebab-case，最長 64 個字元；建立後不得改作其他 Skill，也不得因目錄搬移、profile 或版本更新而改變。
- Group 與 profile 只是 metadata，不是 Skill identity；實體來源永遠維持 `.agents/skills/<skill-id>/**` 平面結構。
- Rename 必須新增新的 stable ID，並保留舊 ID tombstone：舊 entry 設為 `lifecycle.status = removed`、`replacementId = <new-id>`；新 entry 可在 `aliases` 記錄舊 ID 以支援一次性設定遷移。alias 不得成為安裝後的實體目錄名稱。
- 無替代品的 removal 保留 `status = removed` tombstone，但不設定 `replacementId`。Removed Skill 不得被 profile include，也不需要出現在新 lock 的 Skill entries。
- Stable ID、source ID、profile ID、target path 或 alias 衝突都必須停止；不得使用 first-wins 或 last-wins。

## Profile 與 dependency resolution

Resolver 依固定順序處理：

1. 合併所有選定 profile 的 `includes`。
2. 套用個人 `includeSkills`。
3. 套用個人 `excludeSkills`；明確 exclude 優先於 profile 與 include。
4. 過濾 platform、shell 與 capability compatibility；profile 帶入但不相容的 Skill 會被移除，明確 `includeSkills` 指定但不相容則 fail closed。
5. 驗證 dependencies：
   - `hard`：必須存在且相容；若被 exclude 或無法滿足，整次 resolution 失敗。
   - `conditional`：只有 `condition` 成立且 `fallback.capability` 不可用時才要求 dependency；否則不強制安裝。
   - `recommended`：只產生建議，不自動改變 resolved set。

`work-with-jira` 對 `configure-jira-api-access` 使用 conditional dependency。Jira Cloud API 缺少或無效時可使用設定流程；若已有核准且已設定的 Jira connector，則以 `jira-cloud-connector` fallback 滿足，不強制要求該 dependency。

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

## Pin 與 hash contract

- `requestedRef` 保存使用者選擇的 branch、tag 或 commit；`requestedRefType` 明確區分類型。
- `resolvedCommit` 必須是 40 個小寫十六進位字元的完整 commit SHA。Bootstrap 只使用 lock 的 `resolvedCommit` 下載，不得重新以 mutable ref 取得內容。
- `catalogSha256` 是 Catalog JSON 原始檔案 bytes 的 SHA-256。
- `archiveSha256` 是下載 archive 原始 bytes 的 SHA-256。
- Skill `contentSha256` 是 deterministic inventory 的 SHA-256：以 repository-relative forward-slash path 做 ordinal 排序，每行使用 `<path>\t<raw-file-sha256>\n` 的 UTF-8（無 BOM）資料串接後計算。空目錄不列入 inventory。
- Manifest `sha256` 是實際套用到 target path 的檔案 bytes SHA-256。
- `resolvedVersion`／`sourceVersion` 是顯示與稽核用的 release label；重現性仍以完整 commit SHA 與 hash 為準。

所有來源必須先下載、驗證並完成 staging，之後才可寫入目標 Repository；任一 pin 或 hash 無法驗證時不得留下部分 desired entries。

## Managed manifest v2 provenance

每個 `files[]` entry 都要能獨立回答：

- 這是 instruction 還是 Skill 檔案（`artifactType`）。
- 屬於哪個穩定 artifact／Skill（`artifactId`）。
- 來自哪個 source、Repository、requested ref、resolved commit 與版本。
- source path、target path 與實際套用內容 hash。

Skill entry 的 source 與 target 必須維持 `.agents/skills/<artifactId>/...`。Manifest v2 不以 root-level 單一來源代表所有檔案，也不使用 Git submodule metadata。

## 個人設定 schema v3 與升級

Installer 會將 schema v1／v2 idempotent 升級為 v3：

- 原樣保留合法的 `autoCommitRepositoryUrls`、`excludedRepositoryUrls` 與 `excludedRepositoryPaths`。
- 新增 `catalog` object；安全預設為目前安裝 commit、`profiles = ["core"]`、空的 `includeSkills` 與 `excludeSkills`。`catalog.ref` 必須是完整小寫 commit SHA。
- 已是 schema v3 時保留使用者的 `profiles`、`includeSkills` 與 `excludeSkills`。若設定指向同一個 AI-Instructions GitHub Repository，重新安裝／升級時 `catalog.repository` 與 `catalog.ref` 必須與本次安裝 runtime、Catalog、Lock 一起更新到目前 checkout，避免舊 pin 搭配新 runtime；明確使用其他 Catalog Repository 的設定則保留原 pin。
- 缺少必要欄位、未知 schema、mutable ref 或同一 Skill 同時 include/exclude 時停止並回報。
- 真實私人 Repository URL 只存在個人設定；本 Repository 的 schema、examples、tests 一律使用 `example.com`、`example.org` 或 `example.test`。

Production wrapper 已完成 config validation、compatibility/dependency selection、routing、immutable acquisition、manifest v2 wiring 與 v1 safe migration。Legacy mutation entry point 只為直接呼叫 regression compatibility 保留；安裝後入口不再走單一來源路徑。
