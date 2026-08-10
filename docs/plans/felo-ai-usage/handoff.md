# FELO AI 搜尋使用規則：AI 交班文件

## 接手任務

接續規劃 FELO AI 搜尋使用規則。開始前完整閱讀 [discussion-record.md](./discussion-record.md)，以其中的已確認決策為準；尚未確認的技術細節不得提前寫成既定規則或開始實作。

## 目前狀態

- 工作分支：`codex/plan-felo-ai-usage`。
- 階段：第一階段使用範圍已確認，尚未進入 Skill 或 script 實作。
- 已建立 production code、Skill 或 script：否。
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

## 待確認事項

- 摘要硬上限是否採 800 個中文字。
- 來源上限是否採 5 筆。
- 第一版是否加入本機快取。
- FELO 失敗時的 fallback 順序。
- provider-neutral 條件式規則與 FELO Skill 的最終責任切分。

## 下一步

與使用者確認 compact output 與 fallback 後，才規劃共用 `search-with-felo` Skill、本機 wrapper、OpenAI interface metadata，以及 Base Instructions 的最小載入條件。不得在設計確認前開始實作。
