# AI 額度觀測與獨立 PowerShell 指令規劃交班

## 接手任務

請接續規劃「AI 額度觀測與獨立 PowerShell 指令」。本規劃已從 `codex/plan-ai-quota-routing` 拆出，目的是先收斂如何安全取得額度狀態及提供給使用者或 Codex，不得展開自主派工流程或直接開始產品實作。

開始前先完整閱讀 [discussion-record.md](./discussion-record.md)，並區分「已確認的上游約束」、「已查證的外部能力」與「尚待使用者確認的候選方向」。

## 目前狀態

- 工作分支：`codex/plan-ai-quota-observability-mcp`。
- 階段：高階需求與行為邊界收斂。
- 已建立 production code：否。
- 已確認目標形式：獨立本機 PowerShell（`pwsh`）指令；目前不建立 MCP、npm 服務或常駐服務。
- 已確認 Codex 多額度桶行為：未指定 `limitId` 回傳全部；指定時只回傳精確相符的桶；找不到時回報可用清單且不得自動 fallback。
- 已確認 Copilot 舊制個人來源：PowerShell 沿用 GitHub CLI 憑證查詢個人 `premium_request/usage` 專用端點；使用者目前確認為舊制 Copilot Pro，每月 300 Premium Requests，方案額度只記錄於本機並標示為使用者確認值。
- 已確認 Copilot 公司來源：本機 Copilot CLI `1.0.78` 可用 headless JSON-RPC 的 `account.getCurrentAuth` 與 `account.getQuota` 驗證目前 Business 登入並取得結構化 `premium_interactions` quota；實測的總量、用量與百分比均和互動式 `/usage` 一致，查詢沒有消耗 AI Units。`resetDate` 語意仍未確認，持久雙 profile 尚待正式驗收。
- 已確認 Copilot 登入隔離：可用不同 `COPILOT_HOME` 讓 Codex 選擇來源而不操作 `/user switch`。實測預設 Business、暫存隔離 Individual，隔離查詢後預設登入未改變。Copilot CLI-backed 的可重複來源必須使用專用隔離內容；僅走 GitHub Billing REST 的個人額度觀測不需要因此建立 `COPILOT_HOME`。
- 已確認 Junie 個人來源：第一版由 PowerShell 透過 `junie --acp true` 的 stdio JSON-RPC 執行 ACP Available Command `usage`，取得 license、剩餘 JetBrains AI Credits 與單位；月總額、重置時間及 Top-up 在沒有其他可靠來源前回報未知。
- 現成工具結論：沒有找到同時安全、成熟且完整覆蓋 Codex、Copilot 公司／私人及 Antigravity 的 MCP。
- caut 結論：目前不採用；先前依 README 的正面判斷已由原始碼、CI、安全與授權稽核推翻。
- 上游依賴：`docs/plans/ai-quota-routing/` 等待本規劃提供額度狀態與可信度邊界，之後才決定未知或不可靠額度下的路由行為。

## 必須保留的責任邊界

1. 額度觀測只提供資料；Codex 保留 task profile、能力、預留額度、排序與派工決策。
2. PowerShell 指令只負責本機唯讀查詢與輸出，不執行 AI 任務、不切換全域帳號、不修改預留、不做代理或遠端服務；它可以依安全資源名稱為 child process 選擇已建立的隔離登入內容。
3. 不得保存、輸出或複製供應商 Token；優先沿用供應商官方登入與 OS credential store。
4. 不得在一般輸出或版本控制文件保存真實帳號、email、organization 或其他非必要識別資訊。
5. 多個模型若共用相同額度來源，觀測結果也必須表達為同一共享來源，不能複製成多份完整額度。
6. 無法可靠取得的資訊必須呈現為未知、過期或估算，不得假裝精確。
7. PowerShell 指令不能補出供應商未提供的官方資料；是否容許非官方介面或本機估算必須由使用者明確確認。
8. 同一登入狀態下的多個計量額度桶可以分開觀測，但不等於不同帳號或不同訂閱；不得因此複製或誤算共享額度。

## 已查證的資料來源概況

- GitHub Copilot：官方 REST Billing API 可查個人及 organization／enterprise usage；公司來源通常需要較高管理或 billing 權限。個人舊制來源已用專用與通用端點交叉驗證使用量一致；API 不直接回傳方案額度，因此本機保存使用者確認的方案額度，再與官方使用量分開標示並推導剩餘量。
- GitHub Copilot 公司登入：目前 Copilot CLI headless JSON-RPC 已驗證可對當下有效登入呼叫 `account.getQuota`，結構化取得 Business `premium_interactions` 的 entitlement、used 與 remaining percentage，並用 `account.getCurrentAuth` 在 process 內確認資源對應。互動式 `/usage` 只作人工比對；ACP `/usage` 未穩定回傳 Plan quota。相關 account 方法仍須版本與 schema 檢查，真實登入與 auth payload 不得保存或輸出。
- GitHub Copilot 多來源：`COPILOT_HOME` 隔離測試已確認不同 child process 可解析成不同方案，且不改變預設登入。新增 Copilot CLI-backed 來源時由 Codex 自動判斷需要隔離並引導一次官方登入；只走 GitHub Billing REST 或一次性檢視時不建立不必要的 Copilot profile。正式實作仍要驗證兩個各自完成官方登入的持久隔離內容。
- JetBrains AI／Junie：第一版已確認採用本機 Junie CLI ACP。PowerShell 透過 `--acp true` 的 stdio JSON-RPC 呼叫 Available Command `usage`，取得個人 license 與剩餘 AI Credits；實測結果與 IDE Widget／人工 `/usage` 一致，且查詢 Session 未消耗模型 Token。ACP 回傳仍是 Markdown 訊息，因此必須做版本、command advertisement 與欄位格式檢查，失敗時回報未知且不得 fallback 至 ANSI TUI 解析。總額度、重置時間與 Top-up 在沒有其他可靠來源前維持未知。Junie 與 AI Assistant 共用 JetBrains AI Credits，BYOK 則歸屬底層供應商。
- Codex：本機 CLI `0.147.0` 已驗證 app-server 的 `account/rateLimits/read`、`account/usage/read` 與限制更新通知，可透過 stdio 結構化查詢目前有效登入狀態。`rateLimitsByLimitId` 已實測能分別表達一般 Codex 與 Spark 額度桶。這些方法存在於未開啟 `--experimental` 的產生協定 schema；app-server 命令本身仍標示為 experimental，跨版本相容與多登入狀態隔離尚待確認。
- Antigravity：官方設定與 Models & Quota 介面可見使用狀態；尚未確認公開、穩定的跨帳號 quota API 或 MCP。
- GitHub 官方 MCP：目前公開工具未提供所需 billing quota 查詢。
- Google Cloud Quotas MCP：處理 GCP 專案／服務 quota，不是 Antigravity 個人 agent quota。

## 接手時不要做的事

- 不要建立 MCP、npm 服務或常駐背景服務；目前已確認的目標是獨立 PowerShell 指令。
- 不要直接安裝 caut、Antigravity Storage Manager 或其他社群 MCP。
- 不要讓 PowerShell 指令自行計算最終派工分數或選擇 AI 資源。
- 不要加入 chat completion、AI proxy、Google Drive、Telegram、遠端 dashboard 或帳號自動輪替。
- 不要把 Token 寫入 JSON、PowerShell profile、Repository、log 或指令輸出。
- 不要先決定 tool schema、資料結構、Adapter、快取檔案或排程。
- 不要解析 `/status`、`/usage` 的終端視覺輸出；Codex 應優先使用 app-server 的結構化唯讀方法。
- 不要呼叫任何會消耗 usage limit reset credit 的方法。
- 不要將目前實測的 `limitId` 清單永久寫死；必須從每次查詢結果探索可用額度桶。
- 指定的 `limitId` 不存在時，不要自動退回一般 Codex 或其他額度桶。
- 不要為了取得精確數字而使用未經確認的 private API、解析 JWT 身分內容或讀取不必要的帳號個資。
- 不要同時回到上游 routing 分支修改派工行為；需要銜接時先在本規劃形成明確結論。

## 下一步

依序和使用者確認：

1. `Provider`／`LimitId` 的多額度桶選擇行為已確認；下一步定義完整輸出欄位、格式與 exit code。
2. Codex 已是第一個驗證來源；確認第一版只支援目前有效登入狀態，或一開始就處理多個隔離的 Codex 登入狀態。
3. Copilot 多登入已決定採隔離登入內容，不允許主動切換全域帳號；下一步確認隔離內容的個人設定根目錄、命名、清除方式，以及兩個持久 profile 的官方登入驗收。
4. Codex 需要看到的最小狀態，以及成功、過期、未知與來源衝突的行為。
5. 無法證明不侵入預留額度時的安全處理。
6. 本機紀錄、識別資訊與清除方式的安全邊界。

上述行為未確認前，不得進入實作規劃或建立正式指令。
