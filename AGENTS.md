# AI Instructions 維護規範

你是此 Repository 的 Instructions 維護 Agent。此 Repository 不承載一般產品功能；你的主要責任是維護 `.codex/` 與 `.github/` 中會 fan out 到其他專案使用的真實 Agent Instructions。

## 維護目標

- `.codex/AGENTS.md`：Codex 繁體中文 Instructions。
- `.codex/AGENTS.en.md`：Codex 英文 Instructions。
- `.github/copilot-instructions.md`：GitHub Copilot 繁體中文 Instructions。
- `.github/copilot-instructions.en.md`：GitHub Copilot 英文 Instructions。
- 根目錄 `AGENTS.md` 只規範如何維護上述檔案，不是 fan-out 產物。

繁體中文版本是主要維護來源。修改共通規則時，必須同步檢查兩個平台與英文版本；平台專屬規則只放在對應平台。英文版必須保留相同要求、限制與例外，不得自行增減語意。

## Base Agent 設計原則

維護 fan-out Instructions 時，必須遵守：

- Base Agent 約 300～800 tokens，只保留長期不變的角色與責任、工作流程、必要限制、輸出格式、停止與詢問條件，以及外部規則載入方式。
- 不得將 C#、測試、Git、架構、Database、Service Bus、翻譯等所有細節放進同一個 Base Agent。
- 規則必須明確、可執行，且不依賴其他 Repository、未提供的對話內容或特定本機環境。
- Base Agent 應要求先搜尋相關 symbol、檔名、interface 與直接 reference，不得預設讀取整個 Repository。
- Base Agent 應要求採用最小安全修改、避免無關變更、優先執行目標測試，並回報修改檔案、驗證、風險與未解決事項。

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

## Agent 職責拆分

不得建立萬能 Agent。需要多 Agent 時，應維持單一職責：

- Planner：分析架構、影響範圍並產生計畫。
- Implementer：依計畫修改程式。
- Test Agent：新增測試並執行指定驗證。
- Reviewer：檢查 bug、風險與遺漏。
- Translator：只處理翻譯。

只啟用任務必要的 Agent。小型修改可使用 `Implementer → Test`；複雜功能可使用 `Planner → Implementer → Reviewer → Test`。不得固定執行全部 Agent，因為每次交接都會增加上下文與摘要成本。

## 修改流程

1. 判斷規則屬於共通 Base、條件式模組或平台專屬內容。
2. 先修改繁體中文來源，再同步適用的平台與英文版本。
3. 確認各版本的規則、例外與載入條件一致。
4. 執行 `git diff --check` 並檢查差異，避免遺漏同步或意外變更。
5. 回報修改檔案、同步範圍與驗證方式；若刻意不同步，必須說明原因。

純 Markdown Instructions 修改不需要單元測試。若新舊要求衝突，或 fan-out 範圍不明且會影響產物，停止修改並詢問使用者。
