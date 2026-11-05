# Agent Skills Catalog contract

## Reader-first runtime contracts

Runtime bundle v3 extends v2 with an exact platform identity, a bound platform-runtime API/manifest/source fingerprint, required capabilities, and the projection-contract digest. Personal sync configuration v5 extends v4 with explicit fixed USER and PROJECT projection selections. The production writers continue to emit runtime bundle v2 and sync configuration v4; P7 adopts bundle v3 before P8 adopts sync v5, so the bundle v3 reader accepts either sync v4 or v5 and validates each contract independently. Until each writer is adopted, its legacy operational launcher, updater, installer, and multi-source bootstrap entry point fails closed before mutation on the newer contract it does not own.

Runtime bundle v2 的 inventory digest 依執行環境的語系排序，只適用於產生該 digest 的同一環境。Runtime bundle v3 則以 path 的 ordinal 比較排序，再將每筆 `<path>\t<sha256>\n` 以 UTF-8（無 BOM）編碼後計算 SHA-256；跨平台 installer 必須使用 v3，不得以 v2 digest 作為跨環境完整性證據。

`runtime-bundle-v3.example.json` is a static JSON Schema example. Executable validation additionally requires `Assert-AiInstructionsRuntimeBundleV3 -RuntimeRoot <installed-runtime-root>` so the reader can verify `platform-runtime.psd1` at the installed runtime root, the manifest's own API/FileList/canonical inventory contract, its complete declared closure and source fingerprint, and `catalog/skills-catalog.json` as a complete Catalog v3 document. A nested or duplicate platform runtime manifest is invalid; closure paths and the source fingerprint are always resolved from the fixed runtime-root manifest directory. The bundle projection digest must equal the digest computed from the fully validated installed Catalog's `projections`; validating the JSON document alone does not establish those filesystem bindings.

`requiredCapabilities` declares the bundle's requirements. The contract validator checks only its shape, including known capability names and uniqueness; projection-aware installers and launchers **MUST** validate the declared set on the target host with `Get-PlatformCapabilities -Required <requiredCapabilities>` before enabling a v3 runtime, and apply installer policy to confirm that the set has not been downgraded. Until that verification succeeds, the bundle must not be treated as available.

### Install transaction journal v1

Commit cleanup writes the journal phase as `committed` first, then deletes tombstones and stage objects, and finally deletes the journal. Therefore a committed `remove-file` whose target is absent remains an applied terminal state only when its tombstone has already been cleaned up or the still-present tombstone continues to match the original SHA-256, length, and recorded `backupIdentity`.

Schema 的空白判斷與 reader 的 `[string]::IsNullOrWhiteSpace` 對齊，明確涵蓋 U+0009–U+000D、U+0020、U+0085、U+00A0、U+1680、U+2000–U+200A、U+2028、U+2029、U+202F、U+205F、U+3000。

`ai-instructions-install-journal-v1.schema.json` 定義 installer、updater 或 launcher recovery 一次 transaction 的 durable intent 與步驟狀態。`generation` 綁定前一個與候選 bundle，`operations` 以連續的 `sequence` 記錄 publication `method`、original/applied state（各自包含當時的 file identity）、stage/backup leaf 與 permissions；journal 不序列化開啟中的 handle。`swap-directory` 的 `sha256` 是 inventory digest，`length` 是檔案數。存在的 original 一定要有 identity 與 non-null permissions snapshot，讓 rollback 能證明內容及原存取政策皆可還原；`create-file` 沒有 original，`backupLeaf`、`backupIdentity` 必須為 null，permissions 可為 null。存在的 applied 只有在 operation 仍為 `pending` 時可暫時沒有 identity，進入 `staged` 後即必須記錄。identity kind 必須符合 journal platform。Windows journal 的 lock primitive 固定為 platform-runtime 回報的 `windows-fileshare`，非 Windows 固定為 `flock`；non-null permissions 在 Windows 固定為 `windows-sddl`，在 Linux／macOS 固定為 `unix-mode`，確保 recovery adapter 可還原。

每個 operation 都以必填 `method` 明確記錄實際 publication／removal 方式。`create-file`、`write-file` 與 `swap-directory` 在所有平台都只使用 `stage-rename`，且任何 state 都必須先記錄 non-null `stageLeaf`，讓 crash recovery 能重新開啟、驗證或清理完整的 stage 物件；create recovery 對已套用目標執行 `remove-applied`，write 與 swap recovery 則以 backup 執行 `restore-original`。`remove-file` 只使用 `tombstone-rename`：以 rename 將原物件移到 `backupLeaf`，`stageLeaf` 必須為 null、state 不得為 `staged`，且所有 state（包含 `pending`）的 `backupIdentity` 都必須 non-null 並等於 `original.identity`；commit 才真正刪除 tombstone。Journal v1 不支援 `in-place` 寫入或直接 unlink remove，因為 crash 可能留下無法和外部修改可靠區分的狀態。

`stageLeaf` 與 `backupLeaf` 只記錄 leaf；其固定解析位置是 transaction root 下的專用私有目錄 `.ai-instructions-txn/<transactionId>/`。該目錄與 target 位於同一 filesystem，publication 與還原才能使用 rename；所有 operation 的 stage／backup leaf 仍在這個共用私有目錄內保持唯一。因為私有目錄與正式 target namespace 結構隔離，leaf 可以等於 target 的最後一段檔名。`targetRelativePath` 的第一段不得以 Unicode NFC 正規化後的 invariant uppercase key 等於 `.AI-INSTRUCTIONS-TXN`；JSON Schema 先拒絕 ASCII 大小寫變體，其餘正規化判斷由 reader 執行。`lock.leaf` 由 lock 協定解析且不受此私有目錄規則，但 lock 檔不得放在 `.ai-instructions-txn/<transactionId>/` 內。

Journal 是可攜式 recovery 證據，因此所有平台都拒絕 Windows 非法字元、尾端句點／空白、只含 Unicode 空白的 leaf 或 target segment，以及保留裝置名稱；lock leaf 與 stage／backup leaf 套用相同可攜檔名規則，但 lock leaf 不加入 stage／backup 唯一性集合。保留名稱判斷與 platform-runtime 完全一致：取 leaf 或 target segment 第一個 `.` 前的部分轉 invariant uppercase，拒絕 `CON`、`PRN`、`AUX`、`NUL`、`CONIN$`、`CONOUT$`，以及 `COM`／`LPT` 加上單一 `0`–`9`、U+00B9、U+00B2 或 U+00B3。Target path 逐段驗證；所有 target path，以及合併後的 stage/backup leaf 集合，分別以 Unicode NFC 正規化後的 invariant uppercase key 保持唯一。JSON Schema 可表達非法字元、空白與尾端規則；保留裝置名稱及跨 operation 的大小寫／NFC 衝突由嚴格 reader 驗證。Schema 的 integer 欄位依 draft 2020-12 語意接受 `4242.0` 等無小數部分的有限數值；reader 同樣只接受落在 Int64 範圍內的整數值，不接受 Boolean、字串或 fractional number。

Recovery observation 必須同時提供 target 的 exists、SHA-256、length、identity 與 permissions，以及 `backup`。Target 不存在時 SHA-256、length、identity、permissions 皆為 null；`backup` 為 null 表示 tombstone／backup 物件不存在，否則形狀固定為 `{ exists: true, sha256, length, identity }`，identity kind 與 journal platform 綁定。存在但無法觀察 identity 或 permissions 時直接拒絕判斷。backup 只有在非 null、SHA-256 與 length 等於 `original`，且 identity 等於 non-null journal `backupIdentity` 時才可用；所有 `restore-original` 都要求 backup 可用。尤其 pending `remove-file` 的 target 不存在時，只有 backup 可用才證明 tombstone rename 已套用，否則視為 external change 並拒絕 recovery；committed `remove-file` 的 target 不存在時，backup 為 null 代表 tombstone 已清理，仍存在則必須繼續符合相同可用性條件，避免清理外部替換物。permissions 形狀與 kind 綁定 journal platform；Windows 以 SDDL ordinal 值及 read-only flag 比對，Linux／macOS 將 mode 去除前導零後以整數比對，並要求 uid、gid 相同。

Recovery 預設 rollback，且只在 exists、SHA-256、length 與 identity 都完全等於 applied state 時還原；`restore-original` 會一併還原 original permissions。只有觀察值的 exists、SHA-256、length 與 identity 已完全等於 original state 時才比對 permissions：相符則 action 為 `none`，不符且 journal operation 有 original permissions snapshot 則為 `restore-permissions`；目標不存在或 journal permissions 為 null（例如 `create-file`）時不比對權限。兩個 content/identity state 皆非（包含刪除後以相同 bytes 重建但 file identity 不同）則視為 external change，以 `keep` 拒絕並保留；applied create 則使用 `remove-applied`。operation action 的封閉集合為 `none`、`restore-original`、`remove-applied`、`restore-permissions`、`keep`。backup 已清理（觀察為 null）視為有效；若仍存在，則 bytes、length 與 identity 必須符合 original，否則拒絕；`create-file` 不得觀察到 backup。`applied`→`commit`、`committed`→`none` 與 `rolled-back`→`none` 都必須通過相同的 backup 證據檢查；`committed` 不比對 permissions，仍依 applied content/identity 判定，且 remove-file 的 target 不存在時另依前述 tombstone cleanup／match 規則判定；`rolled-back` 另須所有目標等於 original 且所有需比對的 permissions 相符，否則 refuse。Recovery 永不 roll forward 尚未套用的 operation。P7a 只提供 schema、嚴格 reader／constructor 與純 recovery decision；writer 與 installer、updater、launcher 的接線留待 P7b–P7d。

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
