# AI 額度觀測與本機 MCP 規劃交班

## 接手任務

請接續規劃「AI 額度觀測與本機 MCP」。本規劃已從 `codex/plan-ai-quota-routing` 拆出，目的是先收斂如何安全取得額度狀態及提供給 Codex，不得展開自主派工流程或直接開始 MCP 實作。

開始前先完整閱讀 [discussion-record.md](./discussion-record.md)，並區分「已確認的上游約束」、「已查證的外部能力」與「尚待使用者確認的候選方向」。

## 目前狀態

- 工作分支：`codex/plan-ai-quota-observability-mcp`。
- 階段：高階需求與行為邊界收斂。
- 已建立 production code：否。
- 已確認要自建 MCP：否；目前只是建議採「PowerShell 查詢核心＋按需 local stdio MCP」。
- 現成工具結論：沒有找到同時安全、成熟且完整覆蓋 Codex、Copilot 公司／私人及 Antigravity 的 MCP。
- caut 結論：目前不採用；先前依 README 的正面判斷已由原始碼、CI、安全與授權稽核推翻。
- 上游依賴：`docs/plans/ai-quota-routing/` 等待本規劃提供額度狀態與可信度邊界，之後才決定未知或不可靠額度下的路由行為。

## 必須保留的責任邊界

1. 額度觀測只提供資料；Codex 保留 task profile、能力、預留額度、排序與派工決策。
2. MCP 若採用，只應是本機、唯讀、最小工具集合，不執行 AI 任務、不切換帳號、不修改預留、不做代理或遠端服務。
3. 不得保存、輸出或複製供應商 Token；優先沿用供應商官方登入與 OS credential store。
4. 不得在一般輸出或版本控制文件保存真實帳號、email、organization 或其他非必要識別資訊。
5. 多個模型若共用相同額度來源，觀測結果也必須表達為同一共享來源，不能複製成多份完整額度。
6. 無法可靠取得的資訊必須呈現為未知、過期或估算，不得假裝精確。
7. MCP 不能補出供應商未提供的官方資料；是否容許非官方介面或本機估算必須由使用者明確確認。

## 已查證的資料來源概況

- GitHub Copilot：官方 REST Billing API 可查個人及 organization／enterprise usage；公司來源通常需要較高管理或 billing 權限。
- Codex：官方 usage dashboard 可查看目前限制，活動中的 CLI 可用 `/status`；尚未確認公開、跨帳號且適合自動化的 quota API。
- Antigravity：官方設定與 Models & Quota 介面可見使用狀態；尚未確認公開、穩定的跨帳號 quota API 或 MCP。
- GitHub 官方 MCP：目前公開工具未提供所需 billing quota 查詢。
- Google Cloud Quotas MCP：處理 GCP 專案／服務 quota，不是 Antigravity 個人 agent quota。

## 接手時不要做的事

- 不要把目前建議寫成使用者已確認要自建 MCP。
- 不要直接安裝 caut、Antigravity Storage Manager 或其他社群 MCP。
- 不要讓 MCP 自行計算最終派工分數或選擇 AI 資源。
- 不要加入 chat completion、AI proxy、Google Drive、Telegram、遠端 dashboard 或帳號自動輪替。
- 不要把 Token 寫入 JSON、PowerShell profile、Repository、log 或 MCP tool output。
- 不要先決定 tool schema、資料結構、Adapter、快取檔案或排程。
- 不要為了取得精確數字而使用未經確認的 private API、解析 JWT 身分內容或讀取不必要的帳號個資。
- 不要同時回到上游 routing 分支修改派工行為；需要銜接時先在本規劃形成明確結論。

## 下一步

依序和使用者確認：

1. 是否接受「PowerShell 查詢核心＋按需 local stdio MCP」。
2. 第一版優先驗證哪個額度來源；依現有官方能力，Copilot 是最成熟候選。
3. Codex 需要看到的最小狀態，以及成功、過期、未知與來源衝突的行為。
4. 無法證明不侵入預留額度時的安全處理。
5. 本機紀錄、識別資訊與清除方式的安全邊界。

上述行為未確認前，不得進入實作規劃或建立 MCP server。
