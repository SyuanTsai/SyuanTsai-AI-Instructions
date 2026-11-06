# Agent Skills Catalog contract

## Reader-first runtime contracts

Runtime bundle v3 extends v2 with an exact platform identity, a bound platform-runtime API/manifest/source fingerprint, required capabilities, and the projection-contract digest. Personal sync configuration v5 extends v4 with explicit fixed USER and PROJECT projection selections. The production writers continue to emit runtime bundle v2 and sync configuration v4; P7 adopts bundle v3 before P8 adopts sync v5, so the bundle v3 reader accepts either sync v4 or v5 and validates each contract independently. Until each writer is adopted, its legacy operational launcher, updater, installer, and multi-source bootstrap entry point fails closed before mutation on the newer contract it does not own.

Runtime bundle v2 的 inventory digest 依執行環境的語系排序，只適用於產生該 digest 的同一環境。Runtime bundle v3 則以 path 的 ordinal 比較排序，再將每筆 `<path>\t<sha256>\n` 以 UTF-8（無 BOM）編碼後計算 SHA-256；跨平台 installer 必須使用 v3，不得以 v2 digest 作為跨環境完整性證據。

`runtime-bundle-v3.example.json` is a static JSON Schema example. Executable validation additionally requires `Assert-AiInstructionsRuntimeBundleV3 -RuntimeRoot <installed-runtime-root>` so the reader can verify `platform-runtime.psd1` at the installed runtime root, the manifest's own API/FileList/canonical inventory contract, its complete declared closure and source fingerprint, and `catalog/skills-catalog.json` as a complete Catalog v3 document. A nested or duplicate platform runtime manifest is invalid; closure paths and the source fingerprint are always resolved from the fixed runtime-root manifest directory. The bundle projection digest must equal the digest computed from the fully validated installed Catalog's `projections`; validating the JSON document alone does not establish those filesystem bindings.

`requiredCapabilities` declares the bundle's requirements. The contract validator checks only its shape, including known capability names and uniqueness; projection-aware installers and launchers **MUST** validate the declared set on the target host with `Get-PlatformCapabilities -Required <requiredCapabilities>` before enabling a v3 runtime, and apply installer policy to confirm that the set has not been downgraded. Until that verification succeeds, the bundle must not be treated as available.

### Install transaction journal v1

`ai-instructions-install-journal-v1.schema.json` 與嚴格 reader 定義 `.ai-instructions-txn/<32-lowercase-hex transactionId>/journal.json` 的 durable intent。檔案 operation 使用 exact file state `{ exists, sha256, length, identity }`；`swap-directory` 與 `create-directory` 使用 exact directory state `{ exists, identity, inventorySha256, entryCount }`，不得互換形狀。directory inventory digest 採 runtime inventory v3 的 ordinal canonical hash，permissions snapshot 只描述目錄本身、不遞迴。Windows permissions 為 DACL-only `windows-sddl`，Unix 為 `unix-mode`。

Windows recovery 的權限相等不是 ordinal SDDL 字串相等：兩側 DACL 的 ACE 序列必須逐項具有相同完整 binary payload，只將每個 ACE 的 access mask 依檔案 `GENERIC_MAPPING` 展開並移除 generic bits 後比較；DACL protected（`P`）旗標也必須相同。DACL control 的 auto-inherited（`AI`）旗標不參與相等判斷，因為 publication 的低階 DACL-only 寫入會清除該資訊旗標，此為目前已知限制；`readOnly` 維度另行精確比較。Journal 仍保存未正規化的原始 DACL-only SDDL（包括 `AI`），不得以正規化值覆寫 durable snapshot。

所有 publication 都是 stage→rename，remove 是 tombstone rename，rollback 也只以 rename 搬回，因此首次 journal（包括 `pending`）已必須記錄 rename 會保留的 identity：存在的 original 具有 non-null identity；stage-rename 的存在 applied 具有 non-null identity；存在 original 的 `backupIdentity` 必須 non-null，且 reader 要求它等於 `original.identity`。`create-file` 與 `create-directory` 的 original 不存在，backup leaf 與 backup identity 皆為 null；`create-file` 的 permissions 可為 null 或 non-null，但 recovery 不比對它，因為沒有 original 可還原；`create-directory` 的 permissions 必須為 null。已套用的 create recovery 使用 `remove-applied`。`swap-directory` 與 `create-directory` 另須 non-null `quarantineLeaf`，以便 rollback 將 applied directory rename 回交易目錄；檔案 operation 的 quarantine leaf 固定為 null。

`stageLeaf`、`backupLeaf`、`quarantineLeaf` 都是 transaction root 內的 portable leaf，套用 Unicode NFC＋invariant uppercase 唯一性；`JOURNAL` 與 `JOURNAL.*` 專供 journal store 的 `journal.json`、`journal.stage`、`journal.prev`，operation 不得使用。`targetRelativePath` 第一段不得為 `.ai-instructions-txn`。所有 target 也以同一正規化比較，彼此不得重複或形成祖先／子孫關係。Reader 另外維持 Windows 保留名稱、非法字元、尾端句點／空白、Unicode scalar 長度及孤立 surrogate 的既有可攜性檢查。

Journal store 更新只允許 immutable metadata 與 operation intent 完全不變；其比較依 JSON 語意遞迴處理，不受 object property 順序影響，array 維持順序，數值以 decimal 值比較。phase 依 `prepared→applying→applied→committed` 或任一非 terminal 套用 phase 轉 `rolling-back→rolled-back` 單向前進；operation state 只允許 pending／staged／applied／rolled-back 的列舉轉換。Parser 可綁定 expected transaction ID；`journal.json` 與 `journal.prev` 並存時，兩者都必須是有效且 transaction ID 相符的 file journal，並由 prev 到 current 通過上述 store transition，否則分類為 malformed。完整分類區分 `valid-journal`、`orphan-without-journal`、`malformed-journal`、`invalid-name`，而 PowerShell 5.1 可內嵌的最小 classifier 只回傳 `invalid-name`、`orphan-without-journal`、`journal-present`。只有 installer 可 recover 或 purge orphan；launcher 與 updater 遇到任何殘留都以 `interrupted-install` fail closed。一般 JSON writer 在任何 mutation 前會解析既有 symlink／junction 的 physical path；lexical 或 physical path 進入 `.ai-instructions-txn` 都會拒絕，但指向一般目錄的 link 仍可寫入。

Recovery observation 依 operation kind 使用對應 exact state，再附加 permissions 與 backup；directory backup 同樣以 inventory digest、entry count、identity 比對，檔案則以 SHA-256、length、identity 比對。對 original 存在的 `write-file` 或 `swap-directory`，若非 terminal phase 觀察到 target 不存在，但 backup 與 original 的內容及 `backupIdentity` 完全相符，代表 crash 發生在 original→backup 與 stage→target 兩次 rename 之間，必須以 `restore-original` 整體 rollback，即使 phase=`applied` 也不得 commit；backup 缺少或不相符仍 refuse。只有 phase=`applied` 且每個 operation 都觀察為 applied 才能 commit；任何 partial 都整體 rollback，永不 roll forward；terminal 完全相符才 cleanup，外部變更或不完整證據一律 refuse 並 keep。純 plan 在產生任何 step 前會驗證 decision action 與 journal phase，以及每個 operation action 與 kind、original existence、permissions evidence 相容，再將 decision 嚴格映射成 primitive 字串：commit 先寫 `committed` 再清 artifacts；rollback 先寫 `rolling-back`，依 sequence 遞減執行 file publish/remove、directory move 或 permissions restore，且每個 target operation 後立即持久化 `rolled-back` operation state；`restore-original` 若有 original permissions snapshot，會在還原內容後先以 `Set-PlatformPermissions` 還原權限，再寫入該 operation 的 `rolled-back` state；`restore-original` 遇 target 不存在時只需將 backup rename 回 target，`swap-directory` 不需 quarantine；若 crash 發生在 target 已還原但 state 尚未更新，也會在 terminal phase 前補寫狀態。最後才寫 `rolled-back`；none、commit 與 rollback 的 `cleanup-transaction` 一律以 `Remove-PlatformOwnedDirectoryTree` 清除 transaction 目錄。本階段不呼叫 platform primitive，也不接線 installer、launcher 或 updater。

拒絕錯誤使用 `SyuanTsai.AiInstructions.AiInstructionsRefusalException` 與封閉 code 清單；message 追加 `[ai-instructions-refusal-code=<code>]`，讓 ErrorRecord、inner exception 與跨程序 stderr 都可解析。typed exception 的 `Code` 優先；文字包含多個 marker 時只採最後一個，且最後一個 code 不在封閉清單時不回退較早 marker。現有 throw 尚未改接 typed exception，留待後續 wiring。

本目錄定義 AI Instructions Repository、外部 Agent Skills repositories 與目標 Repository 之間的 production 契約。Installer 與 multi-source bootstrap 直接使用這些 checked-in schemas、source pins、Catalog 與 immutable lock。共用 Skill source 只存在於 Catalog 列出的 external repositories；本 Repository 不保存副本。`Skill-Darktide-Translate`（SYP-88／SYP-92）維持獨立，不加入本 Catalog 或 Lock。

本 Catalog 的 profile 與 Skill `compatibility.platforms` 是選擇 metadata；`any` 維持既有語意，表示該 Skill metadata 未宣告額外作業系統限制，schema 與 parser 相容性不變。這些 metadata 不定義本 Repository 或消費 Repository 的本機 Agent/runtime 支援平台。本機支援範圍及 owned production Skill 的 description 要求，以 [Skill Repository Standard v1](../docs/standards/skill-repository-standard.md) 為準。

## 文件責任

| 文件 | Schema | 責任 |
| --- | ---: | --- |
| Skills Catalog | 1 (legacy read) / 2 (production write) / 3 (reader-first) | 宣告可用來源、穩定 Skill ID、群組、profiles、compatibility、dependencies 與 lifecycle。v2 明確分離 canonical source 與單一 runtime target；v3 改以固定 projection contract 推導 target。Production 仍維持 v2，v3 由後續 projection-aware installer 採用。 |
| Catalog source pins | 1 | 記錄維護者選定的 requested ref、完整 resolved commit 與顯示版本，供 lock generator 重現與 stale-check。 |
| Catalog lock | 1 (legacy read) / 2 (production write) / 3 (reader-first) | 將 catalog 及每個來源的 branch／tag／commit ref 鎖定到完整 commit SHA、archive hash 與 deterministic Skill content hash。v3 另以 `projectionContractSha256` 綁定 Catalog projections，且不再保存 `targetPath`。 |
| Managed manifest | 2 (legacy read) / 3 (canonical write) | 記錄目標 Repository 實際套用的每個檔案及完整 provenance，用於 customized／unmanaged 保護與安全更新。 |
| User Skills managed manifest | 1 (legacy read) / 2 (canonical write) / 3 (reader-first) | 記錄 USER projection 中由 Catalog 管理的檔案、Catalog commit、來源 pin 與逐檔 hash；未列入此 manifest 的個人 Skill 永遠視為 unmanaged。v3 reader 可驗證多 projection parity，writer 於 P8 才採用。 |
| Personal sync configuration | 4 | 記錄 exclusions、已安裝 AI-Instructions runtime/Catalog bundle 的 canonical GitHub Repository 與完整 commit SHA、Skill selection，以及更新 mode／channel／interval；不含任何 auto-commit 設定。 |
| Runtime bundle metadata | 2 | 安裝時產生 `runtime-bundle.json`，記錄 Repository、commit、acquisition、archive hash，以及 runtime 精確檔案 inventory／hash；launcher 與所有 stable commands 每次執行前都必須完整驗證。 |
| Update receipt | 1 | 記錄上次檢查時間、policy、current/candidate commit、結果、archive hash 與診斷訊息；`current` outcome 的 `candidateCommit` 固定為 `null`，已解析版本由 `currentCommit` 唯一表示。 |

正式 schema 位於 [`schemas/`](schemas/)，去識別化、可通過 parser 的完整文件位於 [`examples/`](examples/)。`scripts/skills-catalog-contract.psm1` 負責 PowerShell 5.1 相容的跨文件驗證；JSON Schema 負責標準工具可讀的結構契約。

## Stable ID、rename 與 removal

- Skill `id` 使用 lowercase kebab-case，最長 64 個字元；建立後不得改作其他 Skill，也不得因目錄搬移、profile 或版本更新而改變。
- Group 與 profile 只是 metadata，不是 Skill identity。Versioned canonical source 是 `skills/<skill-id>/**` 平面結構；schema v1 只作為 legacy read 保留 `.agents/skills/<skill-id>/**` source，schema v2 以 `sourcePath`／`targetPath` 明確宣告 source 與單一 consumer projection。Schema v3 移除任意 `targetPath`，只允許契約列出的 USER／project projections，target 固定由 `<projection.root>/<skill-id>` 推導；`user-agents` 為必備 projection。Production Catalog/Lock 目前仍為 v2，尚未支援 projection 的 consumer 遇到 v3 必須 fail closed。不得把 target path 當成 source layout authority。
- Rename 必須新增新的 stable ID，並保留舊 ID tombstone：舊 entry 設為 `lifecycle.status = removed`、`replacementId = <new-id>`；新 entry 在 `aliases` 記錄舊 ID。
- Resolver 會把個人 `includeSkills`／`excludeSkills` 中的 removed ID 或 alias 遷移到 replacement stable ID；實體安裝目錄只使用 replacement ID。
- 無替代品的 removal 保留 `status = removed` tombstone，但不設定 `replacementId`；明確選取此類 removed Skill 必須 fail closed。
- Tombstone 與 alias 是遷移期設計，不是永久義務。來源 Repository 已刪除舊 Skill，且維護者決定結束遷移時，可在同一個變更中移除舊 entry 與 replacement 的 alias。移除後，個人設定若仍在 `includeSkills`／`excludeSkills` 指定舊 ID，會以 unknown Skill fail closed，使用者需改選 replacement ID。
- Stable ID、source ID、profile ID、target path 或 alias 衝突都必須停止；不得使用 first-wins 或 last-wins。

## Profile 與 dependency resolution

Resolver 依固定順序處理：

1. 合併所有選定 profile 的 `includes`。
2. 套用個人 `includeSkills`，並遷移 alias／replacement ID；若同一 Skill 已由選定 profile 帶入，該重複項會正規化移除，且 resolver 防禦性地維持 profile 的 soft compatibility 語意。只有 profile 未選入的真正明確 include 才是 hard requirement。
3. 套用個人 `excludeSkills`，並遷移 alias／replacement ID；明確 exclude 最終優先。
4. 過濾 platform、shell 與 capability compatibility；profile 帶入但不相容的 Skill 會被移除，明確 `includeSkills` 指定但不相容則 fail closed。唯一例外是缺少的 `anyOfCapabilities` alternative set 同時包含某個 conditional dependency 的 condition 與 fallback capability，而且該 dependency 目前 required 且本身相容；此時保留 workflow Skill 供下一步加入 setup fallback。Platform、shell、`requiredCapabilities` 或無關 capability set 的失敗不可以這個例外放寬。
5. 驗證 dependencies：
   - `hard`：必須存在且相容；若被 exclude 或無法滿足，整次 resolution 失敗。
   - `conditional`：依 `condition.operator` 判斷條件，且 `fallback.capability` 不可用時才要求 dependency。
   - `recommended`：只產生建議，不自動改變 resolved set。

Conditional operator 的 production semantics：

- `available`：condition capability 有符合其 compatibility 宣告的 evidence 時成立。
- `missing`：condition capability 沒有 evidence 時成立。
- `unavailable`：目前 evidence model 中等同沒有可用 evidence。
- `missing-or-invalid`：無有效 evidence 時成立；格式不合法的 evidence 會在載入時直接拒絕。

每個 conditional dependency 的 condition 與 fallback capability 都必須在同一個 `anyOfCapabilities` alternative set 各唯一宣告一次；availability 必須以該宣告的完整 `kind`／`id`／`state` tuple 判定，不能只比對 ID。

`work-with-jira` 對 `configure-jira-api-access` 使用 `missing-or-invalid` conditional dependency。若已有核准且已設定的 `jira-cloud-connector` fallback，不強制安裝 API setup Skill。

`configure-*` setup Skills 不應直接列入一般工作 profile；它們保持 active，只有使用者明確選取，或某個已選 Skill 的 conditional dependency 在 fallback capability 缺失時才會解析進來。否則 profile include 會先把 setup Skill 加入 resolved set，讓 conditional fallback 語意失效。

`atlassian` profile 同時保留一次性發布的 `publish-requirements-to-confluence` 與 Git 文件同步的 `manage-confluence-docs-as-code`；兩者為可獨立 include／exclude 的 active Skill，不是 rename 或 replacement。Docs-as-Code 使用本機 Windows／PowerShell／Git，並包含 `configure-confluence-api-access` 的 hard dependency，使用前仍須核對實際 API 設定及精確寫入授權。

## Compatibility contract

- `platforms` 至少一項；`any` 表示沒有作業系統限制。
- `shells` 使用可判讀的 capability expression，例如 `pwsh>=7`。
- `requiredCapabilities` 中每一項都必須滿足。
- `anyOfCapabilities` 的每個內層集合代表 alternatives；每個集合至少滿足一項。
- Capability `kind` 為 `command`、`connector` 或 `environment`；`state` 為 `available`、`authenticated` 或 `configured`。
- `command` + `available` 可由本機 `Get-Command` 驗證；authentication、connector、API/environment readiness 不得由名稱猜測，必須有明確 runtime evidence。
- 只有 Skill 在任何安全路徑都無法運作時，connector 或 environment 才屬於安裝期 compatibility。若 Skill 已定義「tool 不可用時略過外部寫入並繼續本機工作」的安全 fallback，該 connector 是執行期 dependency，保留在 Skill metadata／instructions，不得放入 `requiredCapabilities` 阻止 Skill 載入。`manage-ai-memory` 的可選遠端記憶工具即採此模式。
- Runtime evidence 透過 `AI_INSTRUCTIONS_CAPABILITY_EVIDENCE` 傳入 JSON array，例如：

```json
[
  { "kind": "connector", "id": "jira-cloud-connector", "state": "configured" },
  { "kind": "connector", "id": "datadog", "state": "configured" },
  { "kind": "command", "id": "felo-ai", "state": "authenticated" }
]
```

- 對 Catalog 明確宣告的安裝期 compatibility，沒有 evidence 時採 fail-closed；不得只因 profile 被選取就假設 connector、authentication 或 API capability 可用。執行期 optional dependency 則由 Skill 自身 fallback 處理，不得偽造 evidence。

## Source acquisition、pin 與 hash contract

- Catalog source `repository` 在 schema v1 僅接受 `https://github.com/<owner>/<repository>[.git]`。這是刻意的 deterministic boundary；其他 Git host 留待後續 schema version 擴充。
- GitHub source 一律使用完整 `resolvedCommit` 的 codeload ZIP。Lock generator 與 bootstrap 使用相同 archive provider，因此 `archiveSha256` 可直接比對同一 immutable archive bytes。
- `requestedRef` 保存 branch、tag 或 commit；`requestedRefType` 明確區分類型。
- `requestedRef` 與 `requestedRefType` 是維護者在 pin 更新當下記錄的 provenance metadata，不是 runtime 的安全輸入；branch 或 tag 後續可移動，因此 `-Check` 不以目前 remote ref 反推歷史關係。PR 必須審查 pin 更新時的 ref 解析證據，runtime 與 stale-check 則只以 `resolvedCommit`、`archiveSha256` 與 `contentSha256` 為權威。
- `resolvedCommit` 必須是 40 個小寫十六進位字元的完整 commit SHA。Bootstrap 不得重新以 mutable ref 決定內容。
- `catalogSha256` 是 Catalog JSON 原始檔案 bytes 的 SHA-256。
- Lock v3 的 `projectionContractSha256` 依 projection `id` 做 ordinal 排序，逐筆串接 `<id>\t<scope>\t<root>\n`，再對 UTF-8（無 BOM）bytes 計算 SHA-256。
- `archiveSha256` 是 GitHub codeload archive 原始 bytes 的 SHA-256。
- Skill `contentSha256` 是 deterministic inventory 的 SHA-256：以 repository-relative forward-slash path 做 ordinal 排序，每行使用 `<path>\t<raw-file-sha256>\n` 的 UTF-8（無 BOM）資料串接後計算。可雜湊的 path 必須先通過 portable safe-path contract；control characters、tab/newline、colon、empty／dot segments、absolute／traversal path、symlink／reparse／special file 與 case-collision 一律拒絕，避免 inventory ambiguity。
- Manifest `sha256` 是實際套用到 target path 的檔案 bytes SHA-256。
- `resolvedVersion`／`sourceVersion` 只供顯示與稽核；重現性仍以完整 commit SHA 與 hash 為準。

所有來源必須先下載、驗證並完成 staging，之後才可寫入目標 Repository；任一 pin 或 hash 無法驗證時不得留下部分 desired entries。

Executable contract 與 JSON Schemas 採相同的 strict object／scalar boundary：Catalog、source pins、Lock、manifest、config 與其巢狀物件都拒絕未知 property；SHA、commit、enum 與其他 scalar 欄位不得以 singleton array 透過 PowerShell coercion 混入。Manifest 的 `artifactType` 必須與路徑 family 一致，`instruction` 不得宣告 `.agents/skills/**` ownership，`skill` 則必須維持同一 stable ID 的 flat Skill path。非 conditional dependency 也不得帶入 `condition` 或 `fallback`。

Production acquisition adapter 只為組合前所需的 `SKILL.md` identity、description、metadata 與 non-empty body 實作 fail-closed lexical subset；它不宣稱是完整 YAML conformance authority。完整 frontmatter type／syntax contract 仍必須由 Standard v1 指定的 safe YAML formal validators 執行；subset 無法明確接受的 YAML scalar、tag、duplicate key 或複雜形態一律拒絕，不得以 PowerShell coercion 猜測。

## Managed manifest v2/v3 and user Skills provenance

REPO managed manifest v4 是 reader-first 契約：Instruction entry 以 `host` 綁定 Codex、Copilot 或 Claude 的受限 target，並記錄 `rendererId`／`rendererSha256`；instruction license target 同樣依 host 綁定，Codex 只接受 `.codex/ai-instructions-licenses/`，Copilot 只接受 `.github/ai-instructions-licenses/`。Claude 尚無已核准的 instruction license delivery namespace，因此 v4 reader 對 Claude license target 採 fail-closed，不從其他 host namespace 推論或自行建立新路徑。Skill entry 只允許已宣告的 project projection，且同一 Skill 在所有選定 projection 必須維持相同相對路徑、內容 hash 與 provenance。現行 bootstrap writer 仍寫 v2，既有 v3 仍維持 v3；P9 才由 projection-aware bootstrap 寫入 v4。

`Assert-ManagedManifest` 只驗證 manifest 文件本身。REPO Skill entries 與 Lock 的綁定，以及 Instruction entries 與 renderer 的綁定，均由 P9 projection-aware bootstrap 負責；P6c 不提供這些信任邊界，也不得把單獨通過 v4 文件驗證視為可 mutation 的 ownership evidence。

新 consumer manifest 只記錄 Instructions 及其 metadata。既有 v2/v3 Skill entries 僅用於保護與精確遷移舊 REPO 副本；generic stale-prune 不得清除它們。v1 沒有逐檔來源 ownership 的 Skill entries 保留，不推論式升級為可刪除副本。缺少／無效 USER、額外檔案或 tracked/staged 任一證據缺口都保留完整 Skill；共用 Skills 的唯一安裝／更新入口是 USER reconciler。獨立專案 Skills 與其他合法 host projection 不受此 consumer 契約禁止。

每個 `files[]` entry 都要能獨立回答：artifact type／ID、source Repository、requested ref、resolved commit、version、source path、target path 與套用內容 hash。legacy manifest v2 配合 legacy pins，Skill entry 的 source 與 target 都必須維持 `.agents/skills/<artifactId>/...`；canonical manifest v3 才允許 `skills/<artifactId>/...` source 對應到 `.agents/skills/<artifactId>/...` target。未知 mapping／schema version 必須 fail closed，target projection 不隨 source root 自動改名。Manifest v2/v3 都不使用 Git submodule metadata。

User Skills manifest v2 的一般 Skill payload 必須使用 `skills/<skillId>/...` source 對應到 `.agents/skills/<skillId>/...` target，且兩端去除各自 Skill root 後的相對路徑必須 ordinal 完全相同；v3 reader 另接受 `user-agents`、`user-claude`、`user-copilot` 固定 USER projection，要求每個 Skill 在所有宣告 projection 具有相同的相對路徑與內容 hash，並以 `projectionContractSha256` 綁定 projection 契約。`Assert-UserSkillsManagedManifest` 只驗證 manifest 文件本身；任何 writer 或 installer 使用 v3 manifest 前，MUST 先以原始 `CatalogBytes`、`LockBytes` 與可信 Catalog repository／commit 呼叫 `Assert-UserSkillsManagedManifestBinding`。該函式以嚴格、無 BOM 的 UTF-8 解析兩份 bytes，驗證 Catalog 與 Lock，並要求 Lock 的 `catalogSha256` 與 manifest 的 `lockSha256` 分別等於本次傳入原始 bytes 的 SHA-256；呼叫端不得傳入已解析物件或外部計算的 hash。該函式只把一般 Skill payload（`skills/<skillId>/...`）的內容 hash、per-file provenance 與 catalog／lock 身分綁定到 Lock；`<projection-root>/<skillId>/.ai-instructions-licenses/**` 與 `delivery.json` 等 license delivery entries 不在此綁定範圍。Projection-aware installer 在信任 license delivery entries 之前，MUST 以已驗證的 source archive 重新產生 license delivery package（`license-delivery.psm1` 的 `New-LicenseDeliveryPackage`），並逐檔比對 target、source 與 sha256；未比對前不得把 license delivery entries 當成 managed ownership evidence。v2/v3 同一個 Skill 的 license delivery entries 可保留實際來源 Repository 的 `LICENSE`、`NOTICE`、`THIRD_PARTY_LICENSES.md`、`LICENSES/**` 等 license provenance，`delivery.json` 則必須使用 `.ai-instructions-generated/delivery.json` synthetic source path。這些例外只適用於明確的 license delivery target，validator 仍會拒絕把根目錄 license source 套用到一般 Skill payload。現行 reconciler writer 仍只產生 v1/v2；既有 v3 manifest 必須交由 projection-aware installer，P8 前不得由 legacy reconciler mutation 或 recovery。

呼叫 `Assert-UserSkillsManagedManifestBinding` 時，呼叫端必須同時提供來自 runtime receipt 或已驗證 catalog archive 的可信 `ExpectedCatalogRepository` 與 `ExpectedCatalogCommit`；函式會將它們與 manifest 的 catalog 身分進行 ordinal 比對。

## 個人設定 schema v4、runtime v2、安裝與升級

Installer 將 schema v1／v2／v3／v4 idempotent 正規化為 v4：

- 保留合法的 `excludedRepositoryUrls`、`excludedRepositoryPaths`；v3／v4 另保留 `profiles`、`includeSkills`、`excludeSkills`，但會依 candidate Catalog 移除已由選定 profile 帶入的冗餘 `includeSkills`。這項 migration 不改變真正的額外 include 或 explicit exclude。
- 所有舊 `autoCommitRepositoryUrls`、`autoCommitRepositoryPaths` 與 `repositoryUrls` 都會移除；正常同步不會 stage 或 commit 目標 Repository。唯一例外是 tracked reserved Agent artifact 的一次性隔離 remediation commit，且 runtime 永遠不會 push consumer Repository。
- `catalog.repository` 固定為 canonical AI-Instructions GitHub Repository；`catalog.ref` 是已安裝 bundle 的完整小寫 commit SHA。其他 Repository、mutable ref 或 identity mismatch 一律 fail closed。
- `updates.mode` 為 `notify-only`（預設）或 `auto-install-approved`；`protected-branch/main` 與 `github-release/latest` 是唯一合法 channel/ref 組合，`minimumCheckIntervalMinutes` 必須介於 1 與 2147483647，確保所有 schema-valid v4 設定都能由 installer idempotent 遷移並交給 updater。
- `notify-only` 的 `outcome = available` 是通知，不是失敗也不是安裝完成；它必須回報 `classification = notification`、`installationState = not-installed` 與 `retryable = false`，並繼續使用目前 verified runtime。安裝 candidate 必須由獨立 updater policy 或明確的單次核准觸發。
- Projection-aware v5 migration 對 v1～v4 的預設 USER projections 是 `user-agents` 與 `user-claude`，PROJECT projections 預設為空；`user-copilot` 保持 opt-in，不會因 migration 自動啟用。
- `update-agent-environment.ps1 -Apply` 只依目前 verified runtime 重建並套用 user Skills desired state，不執行 update check，也不傳入 `InstallApproved`。需要更新 AI-Instructions runtime 時先獨立執行 `update-ai-instructions.ps1`，完成驗證後再 reconcile environment。
- runtime bundle v2 對所有 active runtime 檔案記錄 exact path/raw SHA-256 inventory 與總 inventory hash。`github-codeload` acquisition 另必須記錄下載 archive SHA-256。
- Installed launcher 在載入任何 runtime module 前，以 stable script 內建 preflight 驗證 config、bundle identity、launcher reference 與完整 inventory；manual updater／Agent environment updater／cleanup 共用同一 preflight。更新完成後與實際 bootstrap 前會再次驗證，後續 runtime 再驗證 Catalog 與 Lock；缺檔、額外檔案或 byte drift 都會停止。
- Updater 只解析 canonical protected branch 或 latest release 到 immutable commit；下載後驗證安全 ZIP、PowerShell parse、Catalog/Lock，再次解析 candidate 避免 TOCTOU，最後呼叫 transactional installer。Windows PowerShell 的 WebException 與 PowerShell 7 的 HttpResponseException rate-limit 形態都會安全退回 offline。Receipt 使用同目錄原子替換，損壞的舊 receipt 會 quarantine 後重建。並行檢查與安裝分別由 per-home update/install lock 拒絕。
- `rate-limit` 與 `concurrent` 是不落盤的 workflow 結果；前者在最小檢查間隔尚未經過時保留上一份有效 receipt，後者讓 manual command／launcher fail closed，避免與 runtime swap 交錯，因此 receipt schema 只列出實際 persisted outcomes。
- Stable launcher／updater 的操作輸出會標示 `classification` 與 `retryable`。只有明確的 sandbox／permission denial 可在取得核准後重試一次；configuration、compatibility、integrity 與其他 deterministic failure 保持 fail closed，不得在同一 task 迴圈重跑、偽造 capability evidence 或修改 consumer Repository 規避。
- Stable installer 先以內建 canonical identity／archive hash／git HEAD verifier 驗證 candidate source，通過後才 import candidate contract；接著在 install lock 內重驗 expected current commit 與 updater 決策時的 mode/channel/ref，並於 staging 完成 parse、Catalog/Lock 與 runtime bundle 驗證，再替換 launcher、updater、Agent environment updater、cleanup、runtime 與 config。任何 pre-swap failure 都清除 transaction directories，正常 mutation 例外會完整 rollback，rollback 本身失敗才保留 backup path。

Production wrapper 已完成 config validation、compatibility/dependency selection、routing、immutable acquisition、manifest v2 wiring 與 v1 safe migration。Mutation engine 只接受 wrapper 產生的已組合 archive 與 immutable provenance；舊單一來源直接呼叫模式已移除。Tracked reserved artifact 會先由隔離 remediation 備份並解除追蹤，再進入正常 v1／v2 migration；相同 strict legacy parser 也供舊 runtime 的明確授權 pollution cleanup 使用。
