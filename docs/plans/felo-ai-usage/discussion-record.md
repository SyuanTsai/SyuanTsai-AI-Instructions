# FELO AI 搜尋使用規則：討論與決策紀錄

## 文件定位

- 狀態：第一版 Skill、script 與條件式規則已實作並完成驗證，待差異審查與交付。
- 工作分支：`codex/implement-felo-ai-usage`。
- 用途：定義何時可自動使用 FELO 搜尋，以及如何避免 FELO 的原始結果增加 Codex 上下文負擔。
- 更新原則：只有使用者已確認的內容列入「已確認決策」；技術細節未確認前保留在「待確認設計」。

## 1. 目標

使用 FELO 每日可能過期且通常未用完的贈送點數，承接符合資格的公開外部資料搜尋，降低 Codex 為搜尋、閱讀及初步整理多個外部來源所消耗的額度。Codex 仍負責需求理解、判斷、規劃、程式碼、驗證與整合。

這個目標優先保留 Codex 額度，不以所有供應商合計成本或 Token 最少為第一優先；但 FELO 結果必須先在本機壓縮，避免把節省的搜尋消耗轉成 Codex 的工具輸入消耗。

## 2. 已確認決策

### 2.1 FELO 只定義為搜尋工具

- FELO 是外部公開資料的搜尋工具，不是 Planner、Worker、Execution Resource 或最終判斷者。
- 使用 FELO 搜尋不代表建立正式 Task、啟動 AI 派工或交出架構決策。
- FELO 只負責找到、初步整理並附上外部來源；Codex 保留是否採信、是否進一步驗證及如何使用結果的決定權。

### 2.2 符合範圍時允許自動使用

- Codex 不需要逐次等待使用者確認即可呼叫 FELO，但每次查詢仍須通過資料範圍與安全條件。
- 自動使用只適用於公開外部資料的搜尋或查證，不因 FELO 尚有額度就擴張到其他工作。
- Conversation、Task Planning 或 Task Execution 中若出現符合條件的外部查證需求，均可把 FELO 當成搜尋工具；這不改變既有階段責任，也不視為其他 AI 資源派工。

### 2.3 公司任務也只允許查詢資料

- 個人或公司任務都只能把不含內部內容的公開查詢送給 FELO。
- 公司任務不得把 Repository 內容、原始碼、diff、測試、log、內部文件、客戶資料、未公開名稱或其他受限制資訊傳給 FELO。
- 若無法用中性且公開的問題表達查詢，就不得使用 FELO；改由 Codex、本機工具或已核准的內部資料來源處理。

### 2.4 程式碼相關工作一律不交給 FELO

- FELO 不得讀取、搜尋、分析、產生、修改、Review 或除錯任何程式碼。
- FELO 不得分析 Repository 結構、symbol、Git 歷史、diff、測試結果、執行 log、錯誤堆疊、架構或實作方案。
- 軟體開發任務只有其中可獨立表達的公開外部事實可交給 FELO，例如公開版本狀態、官方 release note 位置、公開授權資訊或已公開安全公告。FELO 回傳後，程式碼影響仍由 Codex 依 Repository 證據判斷。

### 2.5 FELO 原始結果不得直接進入 Codex 上下文

- 不得直接回傳 `felo search --json` 的完整 stdout。
- 原始回應中的 `id`、`message_id`、`request_id`、`query_analysis`、來源 `snippet`、重複來源、超額候選來源及過程說明不得進入一般工具輸出。
- FELO 呼叫必須經本機 wrapper 擷取、驗證、投影及裁切後，才把最小結果交給 Codex。
- 第一版只輸出 FELO API 真正提供且能可靠投影的欄位；不得假裝本機 script 能從自由文字穩定產生獨立的 `facts` 或 `conflicts`。

## 3. 第一版範圍

### 3.1 納入範圍

- 透過已安裝並完成認證的 FELO CLI 執行公開外部資料搜尋。
- 依查詢內容自動判斷是否符合 FELO 搜尋範圍。
- 以本機 script 捕捉 FELO 原始輸出，不讓原始 JSON 出現在 Codex 工具歷史。
- 驗證 FELO 成功狀態並只回傳簡短摘要與有限來源。
- 對 timeout、認證失敗、額度不足、回應格式改變及無來源提供安全失敗結果。
- 保持 FELO API Key 與真實額度狀態在個人設定範圍之外，不寫入 Repository。

### 3.2 不納入範圍

- 任何程式碼、Repository、測試、Review、除錯、架構或實作工作。
- FELO LLM model provider、以 FELO 取代 Codex 主模型或讓 FELO 承接 AI 派工。
- FELO MCP Server、常駐服務或背景代理。
- 私有 LiveDoc、內部知識庫或檔案上傳。
- 自動抓取或解析 FELO 帳務頁面、每日贈送點數及訂閱點數。
- 以目前觀察到的每日 200 點或訂閱 15,000 點作為受版本控制的固定規則。
- 在第一版由 script 判斷來源衝突、事實正確性或高風險結論。

## 4. 搜尋資格

只有同時符合下列條件時才可自動使用 FELO：

1. 查詢目標是公開外部資料。
2. 問題不包含程式碼、Repository 內容或其他非公開資訊。
3. 查詢需要即時性、多來源探索、多語言搜尋，或目前不知道權威來源位置。
4. 結果可壓縮成短摘要與少量來源。
5. FELO 目前可用，且查詢不需突破既有權限或資料政策。

以下情況優先使用本機工具或直接權威來源，不使用 FELO：

- 資訊已存在目前對話、Repository 或本機檔案。
- 已知單一官方頁面即可回答。
- 問題的主要工作是理解或修改程式碼。
- 查詢必須攜帶私有上下文才有意義。
- 最終結論需要逐字核對法規、合約、安全公告或其他高風險原文。

## 5. 第一版本機壓縮契約

FELO Chat API 目前提供自由文字 `answer`、搜尋分析及來源陣列。第一版 wrapper 應只投影成：

```json
{
  "status": "ok",
  "asOf": "2026-08-09T15:00:00+08:00",
  "summary": "經長度限制的 FELO answer",
  "sources": [
    {
      "title": "來源標題",
      "url": "https://example.com"
    }
  ],
  "truncated": false,
  "retried": false
}
```

已確認的輸出限制：

- 要求 FELO 以使用者語言回答，並在 query 中要求摘要不超過 800 個 Unicode 字元；這是降低原始輸出的軟限制。
- wrapper 對 `summary` 再執行 800 個 Unicode 字元的硬上限。
- 來源最多 5 筆，只保留 `title` 與 `url`，依正規化 URL 去除重複項目。
- 摘要或來源超過上限時，以 `truncated` 表達已裁切。
- `request-failed` 時由 wrapper 隨機等待 1～2 秒並重試一次；`retried` 表達是否已使用這次重試，避免 Agent 產生第二次工具往返。
- 無法解析成功回應時只輸出安全錯誤分類，不輸出原始 response body 或 credential。
- 第一版不建立本機快取，每次符合條件的查詢都重新呼叫 FELO。

本機 wrapper 必須在 child process 內分別捕捉 stdout 與 stderr，再解析 JSON 並輸出 allowlist 欄位。即使 FELO CLI 先輸出 `Searching...` 等進度文字，也不得將整段輸出轉送給 Codex 後再解析。

2026-08-10 已以 `felo-ai` 0.2.54 實際驗證 Windows CLI。`felo search` 支援 `--json` 與 `--timeout`；成功回應頂層包含 `code`、`data`、`request_id`、`status`，`data` 包含 `answer`、`id`、`message_id`、`query_analysis`、`resources`，來源包含 `link`、`snippet`、`title`。測試查詢回傳 20 筆來源且 CLI 同時產生多項過程輸出，確認 wrapper 必須在本機捕捉並只投影 allowlist 欄位。

## 6. 概念流程

```text
Codex 判斷需要外部資料
          ↓
檢查公開性、非程式碼與搜尋資格
          ↓
本機 wrapper 呼叫 FELO CLI
          ↓
wrapper 捕捉原始結果並驗證 status
          ↓
request-failed 時等待 1～2 秒並重試一次
          ↓
本機裁切 answer、去重並限制來源
          ↓
只把 compact result 交給 Codex
          ↓
Codex 視風險直接使用或核對原始權威來源
```

## 7. 安全與額度邊界

- FELO API Key 只沿用 FELO CLI 的個人設定，不輸出、不複製、不提交至 Git。
- 真實帳號、點數餘額、到期時間及使用紀錄只存在本機私人設定或供應商介面。
- 目前圖片顯示每日贈送點數先下降而訂閱點數保持不變，只能記為當下觀察，不能視為永久扣點契約。
- 第一版依使用者已確認的平均使用情況自動進行符合資格的搜尋，不為每次搜尋解析帳務頁面。
- 若未來觀察到訂閱點數異常下降，再另行決定是否加入額度觀測、停用條件或訂閱點數預留；目前不提前實作。

## 8. 已確認實作設計

1. compact output 的 `summary` 硬上限為 800 個 Unicode 字元，來源上限為 5 筆。
2. 第一版不建立本機快取。
3. FELO 失敗時，有適合且已核准的 connector 就使用該 connector；沒有適合的 connector 時，使用 Codex 自身的網路搜尋能力；兩者皆不可用時才回報即時查證不可用。
4. provider-neutral 的公開性、私密資料、程式碼與高風險查證邊界放入共通 `ExternalResearch` 條件式規則；`search-with-felo` Skill 只負責 FELO CLI、compact output、錯誤分類與 fallback 指引。
5. 第一版以 Windows 與 PowerShell 7 為主要執行環境。
6. wrapper 只對 `request-failed` 隨機等待 1～2 秒並重試一次，最後以 `retried` 回報；Agent 不再自行重試 FELO，最終失敗才進入既有 fallback。

## 9. 第一版實作結果

已依第 8 節完成：

- `.agents/skills/search-with-felo/SKILL.md` 與 `agents/openai.yaml`。
- PowerShell 7 compact wrapper、projection module 與 Pester 測試。
- Codex 與 GitHub Copilot 的繁中／英文 `ExternalResearch` 條件式規則。
- Codex 與 GitHub Copilot Base Instructions 的最小載入條件與 Skill 入口。

實作採測試先行：目標測試先以 0/6 失敗確認缺少 module，再完成 production code；後續增加 schema drift 測試並確認安全失敗。最終完整 Pester 回歸為 28 passed、0 failed，Skill validator 通過，實際 FELO smoke query 只輸出 compact allowlist JSON。

2026-08-11 依實測的間歇性 `request-failed` 與 Agent token 成本重新採用 TDD：先以 4 個失敗測試確認缺少 retry contract，再加入 wrapper 內部單次重試與 `retried`。更新後 FELO 目標測試為 12 passed、0 failed，完整 Pester 回歸為 33 passed、0 failed；Skill validator 與 live smoke 均通過，live output 僅包含新版 compact allowlist 欄位。
