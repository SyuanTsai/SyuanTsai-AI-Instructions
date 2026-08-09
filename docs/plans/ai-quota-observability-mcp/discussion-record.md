# AI 額度觀測與獨立 PowerShell 指令討論紀錄

## 文件定位

- 狀態：已從「Codex 自主派工與 AI 額度路由」拆出，並確認目前以獨立 PowerShell（`pwsh`）指令為目標產物；仍在收斂使用者可見行為，尚未進入實作規劃。
- 工作分支：`codex/plan-ai-quota-observability-mcp`。
- 用途：規劃如何以獨立本機 PowerShell 指令，安全取得各 AI 額度來源的剩餘量、重置時間與可信度，供使用者或 Codex 按需呼叫。
- 上游規劃：`docs/plans/ai-quota-routing/` 只使用額度觀測結果進行資格判斷與派工，不在該規劃實作資料取得。
- 更新原則：只有經使用者確認的內容列為「已確認決策」；評估結論與建議在確認前保留為候選方向。

## 1. 問題與目標

Codex 在 Task Execution 準備派工時，需要知道使用者已加入的 AI 額度來源目前是否可用、剩餘多少、何時重置，以及資訊是否足以支持「不侵入預留額度」的判斷。

本規劃的目標不是替 Codex 選擇 AI，而是提供範圍清楚、可追溯且安全的額度觀測。Codex 仍負責 task profile、必要能力、預留額度、重置急迫性、成功率、切換成本與最終派工決策。

預期涵蓋的第一批來源包括：

- 當前 Codex 與未來由使用者加入的其他 Codex 額度來源。
- GitHub Copilot 公司與私人額度來源。
- Google Antigravity 私人額度來源。
- 後續由使用者加入且能以合法、可信方式取得狀態的其他 AI 額度來源。

## 2. 與自主派工規劃的責任邊界

```text
AI 供應商官方狀態、API、CLI 或使用者輸入
                    ↓
       額度觀測與可信度判定
                    ↓
          提供標準化額度狀態
                    ↓
 Codex 套用 task profile、能力、預留與派工規則
```

本規劃負責：

- 確認各額度來源能取得哪些資料，以及資料的合法性、即時性與可信度。
- 定義來源不可用、資訊過期、互相衝突或只能估算時的可見狀態。
- 定義獨立 PowerShell 指令的使用者可見行為與完成條件。
- 限制憑證、帳號識別、紀錄與輸出的安全範圍。

本規劃不負責：

- 判斷任務屬於公司或私人 task profile。
- 設定或修改使用者的預留額度。
- 選擇 AI、模型、模式或實際額度來源。
- 自動切換帳號、執行 AI 任務、重試派工或驗收結果。
- 展開自主派工流程、Worker 或完整 AI Router 的實作。

## 3. 已確認的上游約束

- Codex App 是主控；額度觀測只提供資訊，不取代 Codex 的派工判斷。
- AI 資源由使用者加入後才納入可派工範圍；同一 AI／模型可因帳號或共享額度來源不同而有多個選項。
- 多個模型或執行模式若共用同一額度來源，不能被誤判為各自擁有完整額度。
- 任何自主派工不得侵入使用者為該共享額度來源保留的預留額度。
- 真實帳號、Token、email、organization 或其他非必要識別資訊不得寫入受版本控制文件或一般派工輸出。
- 額度觀測結果是派工輸入；task profile、能力、偏好與路由規則仍保存在 Codex 的規劃範圍，不屬於外部工具。

## 4. 現有工具評估

### 4.1 caut

目前不建議採用 `coding_agent_usage_tracker` 作為額度來源。原始碼與最新 CI 稽核發現：

- 公開說明列出多個供應商，但實際抓取流程主要只有 Claude 與 Codex；Copilot、Antigravity 等選項沒有完整 fetch plan。
- Codex provider 沒有可靠的官方額度查詢，部分路徑只回傳帳號身分而沒有 quota。
- 多帳號參數沒有完整接入實際抓取流程。
- Token account 可序列化至本機明文檔案，且使用紀錄會保存 email／organization 等資訊。
- 稽核時目前 commit 的安全 CI 因 RustSec high-severity 相依套件弱點失敗，Windows CI 也因 SQLite linker 問題失敗。
- Repository 使用帶有限制性 rider 的非標準 MIT 條款，對 Codex 整合存在需法律確認的授權風險。

因此先前僅依 README 得出的「高度符合需求」判斷已撤回。未來若重新評估，必須以固定 commit、通過的安全與 Windows CI、實際 provider 覆蓋及可接受授權為前提。

### 4.2 現有 MCP 與社群工具

- GitHub 官方 MCP Server 可操作 GitHub 與 Copilot coding agent，但目前公開工具清單未提供個人／組織 AI credit 額度查詢。
- Google Cloud Quotas MCP 查詢的是 Google Cloud 專案與服務 quota，不是 Antigravity 個人訂閱的 agent quota。
- `opencode-quotas` 可顯示 Antigravity 與 Codex quota，但它是 OpenCode plugin／CLI，不是可直接採用的通用 MCP，且 Copilot 支援仍標為 experimental。
- Antigravity Storage Manager 雖提供 `get_quota` MCP tool，但同時包含 AI proxy、chat completion、Google Drive、Telegram、帳號切換與同步等超出需求的能力；其額度工具也未完整涵蓋 Copilot，不適合直接授予目前規劃所需的最小權限。
- Agent delegation 類 MCP 可以呼叫 Codex、Copilot 或 Antigravity 執行任務，但它們解決的是派工執行，不是可信額度觀測，且通常具有檔案、命令與網路權限。

目前沒有找到一個安全、成熟且同時覆蓋 Codex、Copilot 公司／私人與 Antigravity 多額度來源的現成 MCP。

## 5. 已確認的官方資料能力

### GitHub Copilot

GitHub 官方 REST Billing API 已提供個人與 organization／enterprise 的 AI credit 或 premium request usage 報告：

- 個人來源需要對應使用者及 `Plan: read` 權限。
- 公司來源需要 organization／enterprise 管理或 billing 權限。
- 個人自行購買的 Copilot 與由公司管理、計費的 Copilot 必須查詢不同層級，不能合併成同一份個人額度。

官方參考：<https://docs.github.com/en/rest/billing/usage>

### Codex

OpenAI 官方提供 Codex usage dashboard；活動中的 Codex CLI 對話可使用 `/status` 查看目前執行環境與剩餘限制，`/usage` 可查看使用量歷史。這兩個互動式畫面只作為使用者檢視與人工比對，不作為自動化解析來源。

已在本機 Codex CLI `0.147.0` 驗證其 app-server 提供結構化唯讀方法：

- `account/rateLimits/read`：取得目前有效登入狀態的限制窗口、已使用百分比與重置時間，並可表達同一帳號下的多個計量限制。
- `account/usage/read`：取得每日 Token 使用量及 lifetime、peak、streak 等摘要。
- `account/rateLimits/updated`：接收限制狀態更新通知。

上述方法也存在於未開啟 `--experimental` 的本機產生協定 schema；實測可在不啟動模型任務的情況下，透過本機 stdio 取得目前有效登入狀態的額度中繼資料。因此 Codex 第一版不需要解析終端畫面，也不需要先依賴第三方 quota tracker。

但 `codex app-server` 命令本身仍標示為 experimental，且目前只證明「單一目前登入內容」可查詢，尚未證明跨版本相容性或多個 Codex 登入內容的安全隔離方式。後續應以版本相容檢查與方法偵測保守使用，不能把目前協定視為永久穩定的公開 API。

app-server 另有會消耗 usage limit reset credit 的寫入方法；這類操作不屬於額度觀測，第一版必須排除。查詢結果也不得保存或回傳 email、session、Token 或其他不必要的帳號識別資訊。

官方 dashboard：<https://chatgpt.com/codex/settings/usage>

官方 CLI 指令參考：<https://learn.chatgpt.com/docs/developer-commands?surface=cli>

### Antigravity

Google 官方文件說明 baseline quota、五小時或每週重置行為，並表示可在設定頁查看跨模型使用狀態。Antigravity CLI 也具有 Models & Quota 使用者介面；目前尚未確認公開且穩定的跨帳號 quota API 或 MCP。

官方參考：<https://antigravity.google/docs/plans?app=antigravity>

## 6. 已確認方向：獨立 PowerShell 指令

目前已確認：

- 目前目標產物是可由使用者或 Codex 直接執行的獨立本機 PowerShell（`pwsh`）指令，不建立 npm 服務、常駐服務或 MCP Server。
- Codex 第一版直接以本機 app-server 的結構化唯讀方法作為主要資料來源；`/status` 與 `/usage` 只用於人工比對，不解析其視覺輸出。
- PowerShell 指令負責啟動本機 app-server、完成唯讀查詢並輸出額度觀測結果；不自行判斷 task profile、預留額度、派工資格或資源排序。
- 指令執行完成後即結束，不維持背景服務；Codex 需要更新額度時再按需呼叫。
- 指令不保存、輸出或複製供應商 Token；登入與憑證沿用官方 CLI 或其他供應商原生機制。
- 回傳內容使用使用者設定的安全資源名稱，不包含不必要的 email、organization 或真實帳號識別。
- 指令只在 Task Execution 準備派工、使用者明確查詢額度或需要重新整理過期資訊時執行。
- 無法從官方或已核准來源取得的狀態，不得偽裝成精確剩餘額度。

### 6.1 Codex 多額度桶選擇

已確認目前可行方向：

- 同一個 Codex 登入狀態可以透過 `rateLimitsByLimitId` 回傳多個獨立計量額度桶；它們可以分開觀測，但不等於不同帳號或不同訂閱。
- 本機實測目前包含一般 Codex 額度桶 `codex`，以及 `limitName` 為 `GPT-5.3-Codex-Spark` 的額度桶 `codex_bengalfox`；兩者目前的 `planType` 都是 `pro`。
- 指令只呼叫一次 `account/rateLimits/read` 取得完整額度桶集合，再於本機依 `limitId` 精確篩選，不為每個桶重複呼叫供應商介面。
- 未指定 `limitId` 時，回傳目前發現的全部額度桶。
- 指定 `limitId` 時，只回傳相符額度桶。行為可表達為 `Get-AiQuota -Provider Codex -LimitId <id>`；最終安裝方式不影響此選擇契約。
- `limitId` 是精確選擇條件；`limitName` 用於顯示。當 `limitName` 為空時，輸出仍保留原始 `limitId`，不得捏造供應商名稱。
- 找不到指定 `limitId` 時，回傳 `status: not_found`、原始查詢值及當下可用的 `limitId`／`limitName` 清單，並以非成功 exit code 結束。
- 找不到時不得自動退回 `codex`、第一個額度桶或任何其他桶，避免 Codex 使用錯誤的共享額度來源。
- `codex_bengalfox` 類供應商內部識別不得被假設永久不變；指令每次從當下回應探索可用桶，不能將目前實測清單寫死為唯一合法值。

目前確認的單桶回應至少保留 `limitId`、`limitName`、`planType`、`usedPercent`、衍生的 `remainingPercent`、`windowDurationMins` 與 `resetsAt`。其他狀態欄位與輸出格式仍待後續收斂。

MCP 不屬於目前目標；未來只有在獨立指令已穩定，且 Codex 的直接指令呼叫不足以滿足需求時，才另外評估是否包裝成 MCP。

這個方向的價值是讓使用者與 Codex 共用同一個可檢查、可手動執行的本機入口，同時避免常駐服務與額外工具層；代價是仍需持續追蹤各供應商介面變更，且指令本身無法補出供應商未提供的資料。

## 7. 尚未確認，不得提前實作

- 指令最終安裝位置，以及是否提供人類可讀與結構化兩種輸出；`Provider` 與 `LimitId` 的選擇行為已確認。
- Codex app-server 的最低相容版本、執行時方法偵測與版本不相容時的安全 fallback。
- 額度狀態需要哪些最小可見資訊，以及是否顯示百分比、剩餘量、重置時間或原始值。
- 如何區分可靠、估算、過期、未知與來源衝突。
- 來源未知或過期時，是停用自主使用、詢問使用者、接受本機估算，或採其他保守行為。
- 本機紀錄允許保存哪些歷史與校正資訊、保存多久，以及使用者如何清除。
- 多個官方登入狀態如何安全對應到使用者加入的資源名稱。
- 指令失敗是否只回報未知，或需要影響後續 Task Execution。
- 具體參數、程序架構、輸出 schema、快取格式、檔案位置與安裝方式。

## 8. 下一個顆粒度

下一階段先定義「額度觀測的使用者可見行為與完成條件」，仍不進入程式架構：

1. 多額度桶的 `Provider`／`LimitId` 選擇行為已確認；下一步收斂完整輸出欄位、格式與 exit code。
2. Codex 已成為第一個驗證來源；下一步確認第一版只讀取目前有效登入狀態，或一開始就涵蓋多個隔離的 Codex 登入狀態。
3. 定義一次額度查詢成功、部分成功、過期與未知時，Codex 應看到什麼結果。
4. 確認額度資訊不足以證明不侵入預留時的安全行為。
5. 確認不保存 Token、最小化帳號識別與本機紀錄的邊界。
