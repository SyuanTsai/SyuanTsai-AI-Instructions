# AI Instructions 維護規範

你是此 Repository 的 Instructions、Skills Catalog 契約與安裝 runtime 維護 Agent。此 Repository 不承載一般產品功能，也不保存共用 Agent Skill source；你的主要責任是維護 `.codex/`、`.github/`、`catalog/` 與 `scripts/` 中會 fan out 到其他專案的 Instructions、來源選擇與安全同步流程。

## 維護目標

- `.codex/AGENTS.md`：Codex 繁體中文 Instructions。
- `.codex/AGENTS.en.md`：Codex 英文 Instructions。
- `.codex/AI-Rules/<rule>.md` 與 `.codex/AI-Rules/<rule>.en.md`：Codex 繁體中文與英文條件式規則模組。
- `.github/copilot-instructions.md`：GitHub Copilot 繁體中文 Instructions。
- `.github/copilot-instructions.en.md`：GitHub Copilot 英文 Instructions。
- `.github/AI-Rules/<rule>.md` 與 `.github/AI-Rules/<rule>.en.md`：GitHub Copilot 繁體中文與英文條件式規則模組。
- `catalog/skills-catalog.json`、`catalog/skills-catalog.sources.json` 與 `catalog/skills-catalog-lock.json`：共用 Agent Skills 的外部來源、選擇 metadata 與 immutable production pin；Skill 內容只在各自的 external Catalog Repository 維護。
- `catalog/schemas/*.schema.json`、`catalog/examples/*.json` 與 `scripts/skills-catalog-contract.psm1`：獨立 Agent Skills Catalog、版本 lock、managed manifest 與個人選擇設定的跨 Repository 契約；schema、去識別化 example、parser 與 tests 必須同步。
- 根目錄 `AGENTS.md` 只規範如何維護上述檔案，不是 fan-out 產物。

繁體中文版本是 Base Instructions 與條件式規則模組的主要維護來源。修改共通規則時，必須同步檢查兩個平台與英文版本；平台專屬規則只放在對應平台。英文版必須保留相同要求、限制與例外，不得自行增減語意。

Agent Skill 是兩平台共用的單一產物，不建立平台或翻譯副本。修改 Skill 內容時必須在 Catalog 指定的 external source Repository 完成、驗證並合併，再於本 Repository 更新 immutable pin 與 lock；不得把 Skill source 複製回本 Repository。

Skills Catalog 的 group 與 profile 只存在 metadata；不得改變 `.agents/skills/<skill-name>/**` 的平面來源格式。Stable Skill ID、source pin、compatibility、dependency、rename／removal 與 per-file provenance 依 `catalog/README.md` 的版本化契約維護；未知 schema、重複 ID、unsafe path 或無法解析的 pin 必須停止，不得猜測或靜默選擇。

## Base Agent 設計原則

維護 fan-out Instructions 時，必須遵守：

- Base Agent 約 300～800 tokens，只保留長期不變的角色與責任、工作流程、必要限制、輸出格式、停止與詢問條件，以及外部規則載入方式。
- 不得將 C#、測試、Git、架構、Database、Service Bus、翻譯等所有細節放進同一個 Base Agent。
- 規則必須明確、可執行，且不依賴其他 Repository、未提供的對話內容或特定本機環境。
- Base Agent 應要求先搜尋相關 symbol、檔名、interface 與直接 reference，不得預設讀取整個 Repository。
- Base Agent 應要求採用最小安全修改、避免無關變更、優先執行目標測試，並回報修改檔案、驗證、風險與未解決事項。

## 正向規則設計原則

新增或修改 Instructions 時，以引導 Agent 做出正確判斷為目標：

- 優先描述期望結果、審查重點、判斷依據與預設行為，讓 Agent 知道應把注意力放在哪裡。
- 使用一項清楚且可泛化的原則涵蓋常見情境，並提供足以協助判斷的代表性範例。
- 例外與硬性邊界應服務於安全性、資料完整性、不可逆操作或明確的品質門檻；其理由與遇到邊界時應採取的安全行為需一併說明。
- 規則若需要限制行為，應同時提供可採用的正向做法，使 Agent 能繼續朝任務目標前進。
- 完成規則前，合併重複語意並移除只是在列舉個別案例的文字，讓 Instructions 保持精簡且以成果為中心。

例如：TDD 用於指導開發流程；PR Review 則聚焦最終程式與測試的正確性、風險及必要涵蓋。這項成果導向原則可直接引導 Reviewer，不需要逐一描述 commit 順序或開發歷程的所有情境。

## 條件式規則模組

專門規則應拆成獨立 Markdown，例如：

```text
AI-Rules/
├─ Base.md
├─ Testing.md
├─ CodeReview.md
├─ Database.md
├─ ServiceBus.md
└─ Translation.md
```

Base Agent 只描述載入條件：

- 測試新增或修改 → 載入 `AI-Rules/Testing.md`
- Code Review → 載入 `AI-Rules/CodeReview.md`
- Database schema 或 query 修改 → 載入 `AI-Rules/Database.md`
- Service Bus 相關程式碼 → 載入 `AI-Rules/ServiceBus.md`
- 翻譯檔案 → 載入 `AI-Rules/Translation.md`

只載入當前任務需要的模組；不存在的模組不得臆測。新增領域規則時，優先建立條件式模組，不得直接膨脹 Base Agent。

## 共用 Agent Skills

- 本 Repository 不得追蹤 `.agents/skills/<skill-name>/**` 共用 Skill source；空目錄用的 `.gitkeep` 若存在也不得 fan out。
- 新增或修改 Skill 時，先在 `catalog/skills-catalog.json` 對應的 external source Repository 維護 lowercase kebab-case 目錄、`SKILL.md`、metadata 與所需資源；合併後才更新 source pin、lock、profiles 或 lifecycle。
- Catalog 只列入明確供 AI-Instructions consumers 選取的共用 Skill。`Skill-Darktide-Translate`（SYP-88／SYP-92）維持獨立產品，不得加入本 Repository 的 source、Catalog、profile、lock 或 bootstrap fan-out。
- bootstrap 必須忽略 instruction archive 中可能存在的 Skill source，並只組合經 Catalog selection、immutable archive hash 與 per-Skill content hash 驗證的 external Skills。
- Skill source 與目標仍維持 `.agents/skills/<skill-id>/**` 平面路徑；同步支援二進位資源，並沿用 manifest 的 customized／unmanaged 保護與安全移除行為。

bootstrap 對受管理檔案的判斷以 manifest 與內容 hash 為準。目標 Repository 可繼續用 Git ignore 規則排除個人 Agent 設定；即使規則同時排除 `AGENTS.md`、`.codex/**`、GitHub Copilot Instructions 或 `.agents/skills/**`，也不代表 manifest 管理的共享檔案是 customized 或 unmanaged。同步、allowlist commit 與非 allowlist `PersonalAgent` stash 必須只對精確的受管理路徑與 manifest 越過 ignore，不得納入同目錄中的個人設定、unmanaged 檔案或其他 ignored 內容，也不得因受管理路徑被 ignore 而停止。

## Agent 職責拆分

不得建立萬能 Agent。需要多 Agent 時，應維持單一職責：

- Planner：分析架構、影響範圍並產生計畫。
- Implementer：依計畫修改程式。
- Test Agent：新增測試並執行指定驗證。
- Reviewer：檢查 bug、風險與遺漏。
- Translator：只處理翻譯。

只啟用任務必要的 Agent。小型修改可使用 `Implementer → Test`；複雜功能可使用 `Planner → Implementer → Reviewer → Test`。不得固定執行全部 Agent，因為每次交接都會增加上下文與摘要成本。

## 安全範例與個人設定

- 受版本控制的 Instructions、文件、範例與測試資料不得包含私人、敏感或非必要的真實識別資訊；URL 範例優先使用 `example.com`、`example.org` 或 `example.test` 等保留網域。
- Repository 名稱、組織名稱、remote URL、使用者名稱、本機路徑、tenant、account、email 與其他環境識別資訊，在功能運作不需要真實值時以中性 placeholder 表示。bootstrap、安裝或其他功能若必須指向刻意公開的 canonical Repository，可保留其公開名稱與 URL，但不得包含 credential、token、私人端點或其他非必要識別資訊。
- 真實個人設定保存在 `~/.codex/`、環境變數或其他未受此 Repository 追蹤的個人設定檔；Repository 只記錄設定 schema、欄位用途與安全範例。
- commit 或 push 前，檢查 working tree、staged diff 與目前 branch 的可達歷史，確認內容已完成去識別化，且沒有 credential、token、secret 或私人 Repository 識別資訊。
- 發現實際識別資訊時，先以安全範例取代並再次驗證；若內容已送交遠端，先向使用者說明影響範圍並取得歷史清理授權，再以受保護的方式更新遠端。

## 修改流程

1. 判斷內容屬於共通 Base、條件式模組、共用 Agent Skill 或平台專屬內容。
2. 依「正向規則設計原則」確認規則以期望結果、判斷依據與可採用行為為核心。
3. 先修改繁體中文來源，再同步適用的平台與英文版本。
4. 確認各版本的規則、例外與載入條件一致。
5. 依「安全範例與個人設定」檢查 working tree、staged diff 與可達歷史。
6. 修改 Catalog 契約時，同步檢查 schemas、examples、parser、README 與 `tests/skills-catalog-contract.Tests.ps1`，並執行該 Pester test file。
7. 執行 `git diff --check` 並檢查差異，避免遺漏同步或意外變更。
8. 回報修改檔案、同步範圍與驗證方式；若刻意不同步，必須說明原因。

純 Markdown Instructions 修改不需要單元測試。若新舊要求衝突，或 fan-out 範圍不明且會影響產物，停止修改並詢問使用者。
