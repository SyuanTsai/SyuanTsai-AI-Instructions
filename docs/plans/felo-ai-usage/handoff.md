# FELO AI 搜尋使用規則：AI 交班文件

## 接手任務

接續規劃 FELO AI 搜尋使用規則。開始前完整閱讀 [discussion-record.md](./discussion-record.md)，以其中的已確認決策為準；尚未確認的技術細節不得提前寫成既定規則或開始實作。

## 目前狀態

- 工作分支：`codex/implement-felo-ai-usage`。
- 階段：第一版 Skill、script 與條件式規則已實作並完成驗證，待差異審查與交付。
- 已建立 production code、Skill 或 script：是。
- 主要紀錄：[discussion-record.md](./discussion-record.md)。
- 此分支使用獨立 Git worktree，不包含 `ai-quota-observability-mcp` 的未提交變更；後續不得混入其他規劃產物。

## 必須保留的已確認決策

1. FELO 只定義為公開外部資料的搜尋工具，不是 Planner、Worker、Execution Resource 或主模型。
2. 符合資料與安全條件時可自動使用，不需要逐次等待使用者確認。
3. 個人與公司任務都只能送出不含內部內容的公開查詢；公司 Repository、程式碼、diff、log、內部文件及客戶資料不得傳給 FELO。
4. 程式碼相關工作一律不交給 FELO。軟體任務只有可獨立表達的公開外部事實可查證，程式碼影響仍由 Codex 判斷。
5. `felo search --json` 原始結果不得直接進入 Codex 上下文，必須先由本機 wrapper 捕捉並投影成短摘要與有限來源。
6. 第一版不得聲稱本機 script 能從 FELO 的自由文字可靠產生獨立 `facts` 或 `conflicts`；只保留 API 可可靠投影的 `summary` 與 `sources`。
7. 真實 API Key、帳號、點數與到期資訊只存在個人設定或供應商介面，不進入 Repository。
8. 目前不建立 MCP、不修改 Codex model provider、不處理私有 LiveDoc，也不自動解析 FELO 帳務頁面。

## 已確認實作設計

- `summary` 硬上限為 800 個 Unicode 字元，來源上限為 5 筆；摘要或來源超限時輸出 `truncated: true`。
- CLI query 先要求同語言短摘要，wrapper 再執行硬限制、URL 正規化與來源去重。
- 第一版不建立本機快取。
- FELO 失敗時優先使用適合且已核准的 connector；沒有適合的 connector 時使用 Codex 自身的網路搜尋能力。
- provider-neutral 安全邊界放入 `ExternalResearch` 條件式規則；`search-with-felo` Skill 負責 FELO CLI、compact output、錯誤分類與 fallback 指引。
- 第一版以 Windows 與 PowerShell 7 為主要執行環境。
- 已以 `felo-ai` 0.2.54 實際驗證 `felo search --json`；原始回應與過程輸出必須由本機 wrapper 捕捉，不得直接進入 Codex 上下文。

## 驗證結果

- FELO 目標 Pester 測試：7 passed、0 failed。
- Repository 完整 Pester 回歸：28 passed、0 failed。
- Skill validator：通過。
- PowerShell parser：0 errors；本機未安裝 PSScriptAnalyzer，因此未執行其規則檢查。
- 實際 FELO smoke query：成功，工具輸出只包含 compact allowlist 欄位。

## 下一步

審查 working tree 差異與去識別化結果；確認後再依使用者要求決定是否 commit、push 或建立 Pull Request。
