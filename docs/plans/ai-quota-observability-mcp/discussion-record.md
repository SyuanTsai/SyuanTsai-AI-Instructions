# AI 額度觀測與本機 MCP 討論紀錄

## 文件定位

- 狀態：已從「Codex 自主派工與 AI 額度路由」拆出，進入高階需求與行為邊界收斂；尚未確認最終技術形式，也未進入實作規劃。
- 工作分支：`codex/plan-ai-quota-observability-mcp`。
- 用途：規劃如何安全取得各 AI 額度來源的剩餘量、重置時間與可信度，並評估是否以本機 MCP 提供給 Codex 使用。
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
- 評估本機 PowerShell 指令、local stdio MCP 或其他最小介面的適用性。
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

OpenAI 官方提供 Codex usage dashboard；活動中的 Codex CLI 對話可使用 `/status` 查看剩餘限制。目前尚未確認有可供本機工具跨帳號穩定呼叫的公開額度 API，因此不能把 dashboard 或互動式 slash command 直接視為已完成的機器介面。

官方 dashboard：<https://chatgpt.com/codex/settings/usage>

### Antigravity

Google 官方文件說明 baseline quota、五小時或每週重置行為，並表示可在設定頁查看跨模型使用狀態。Antigravity CLI 也具有 Models & Quota 使用者介面；目前尚未確認公開且穩定的跨帳號 quota API 或 MCP。

官方參考：<https://antigravity.google/docs/plans?app=antigravity>

## 6. 候選方向：最小本機額度 MCP

目前建議，但尚待使用者確認：

- 先以 PowerShell 建立唯讀的額度查詢核心，驗證每個官方資料來源能穩定輸出所需資訊。
- 只有當 Codex 需要在派工前自主呼叫時，再以 local stdio MCP 提供同一份觀測能力。
- MCP 只提供一至兩個唯讀額度查詢工具，不提供聊天、AI 執行、proxy、帳號切換、預留設定或路由功能。
- MCP 不保存、輸出或複製供應商 Token；登入與憑證由官方 CLI、Windows Credential Manager 或其他供應商原生機制管理。
- 回傳內容使用使用者設定的安全資源名稱，不包含不必要的 email、organization 或真實帳號識別。
- MCP 只在 Task Execution 準備派工、使用者明確查詢額度或需要重新整理過期資訊時啟用，避免常駐大量工具描述增加 Codex 額度消耗。
- 無法從官方或已核准來源取得的狀態，不得偽裝成精確剩餘額度。

這個方向的價值是讓 Codex 自主取得必要資訊，同時維持最小權限與單一決策主體；代價是需要持續追蹤各供應商介面變更，且 MCP 本身無法解決供應商未提供機器介面的問題。

## 7. 尚未確認，不得提前實作

- 最終是否採用 MCP，或第一版只保留 PowerShell 查詢。
- 第一版先支援 Copilot、Codex 或 Antigravity 的哪一個來源。
- 額度狀態需要哪些最小可見資訊，以及是否顯示百分比、剩餘量、重置時間或原始值。
- 如何區分可靠、估算、過期、未知與來源衝突。
- 來源未知或過期時，是停用自主使用、詢問使用者、接受本機估算，或採其他保守行為。
- 本機紀錄允許保存哪些歷史與校正資訊、保存多久，以及使用者如何清除。
- 多個官方登入狀態如何安全對應到使用者加入的資源名稱。
- MCP 是否預設停用、按需啟用，以及失敗時是否影響 Codex 啟動。
- 具體 tool schema、程序架構、資料結構、快取格式、檔案位置、排程與安裝方式。

## 8. 下一個顆粒度

下一階段先定義「額度觀測的使用者可見行為與完成條件」，仍不進入程式架構：

1. 確認是否接受「PowerShell 查詢核心＋按需 local MCP」作為目標形式。
2. 決定第一個要驗證的額度來源。
3. 定義一次額度查詢成功、部分成功、過期與未知時，Codex 應看到什麼結果。
4. 確認額度資訊不足以證明不侵入預留時的安全行為。
5. 確認不保存 Token、最小化帳號識別與本機紀錄的邊界。
