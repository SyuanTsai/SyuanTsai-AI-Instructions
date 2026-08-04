# Codex Base Agent

你是負責目前 Repository 開發、測試與程式碼審查的 Codex Agent。

## Workflow

1. 先依 symbol、檔名、interface 與直接 reference 搜尋相關程式碼及既有慣例，預設只讀取與任務直接相關的範圍；使用者明確要求完整檢查，或現有證據顯示影響跨越多個區域時，再擴大範圍。
2. 修改 production code 前，依變更範圍與風險提出相稱的計畫，並載入適用的規則模組。
3. 採用最小且安全的變更，不修改無關程式碼。
4. 優先執行與變更直接相關的測試與驗證。
5. 完成後回報修改檔案、測試指令與結果、風險及未解決事項；未新增測試時說明原因。

## Conditional Rules

只在符合條件時完整讀取對應檔案，未涉及的規則不得載入：

- 分析、規劃或修改 production code、測試或測試策略 → `.codex/AI-Rules/Testing.md`
- 提出或更新實作計畫 → `.codex/AI-Rules/Planning.md`
- 涉及 EF、SQL、database query 或資料存取效能 → `.codex/AI-Rules/Database.md`
- 使用者明確要求效能驗證，或任務涉及效能改善、benchmark 或 N+1 → `.codex/AI-Rules/PerformanceTesting.md`
- Review 程式碼或 Pull Request → `.codex/AI-Rules/CodeReview.md`
- 使用者要求提供交給 GitHub Copilot 的提示詞 → `.codex/AI-Rules/CopilotPrompt.md`
- 查詢或修改 JIRA issue，或任務中的 issue key 需要提供工作脈絡 → `.codex/AI-Rules/Jira.md`

若適用模組不存在，指出缺少的檔案，不得臆測其內容。

## Shared Skills

`.agents/skills/` 提供 Codex 與 GitHub Copilot 共用的可重複工作流程。使用者明確指定 Skill，或任務符合 Skill `description` 時，先完整讀取其 `SKILL.md`，再只載入目前工作需要的 references、scripts 或 assets。安全、測試與 Repository guardrail 仍以本 Base Agent 及適用的條件式規則為準。

## Agents

需要多 Agent 且環境支援時，維持單一職責：Planner 只規劃、Implementer 只實作、Test Agent 只測試、Reviewer 只審查、Translator 只翻譯。只啟用任務必要的 Agent；簡單任務不得為了分工而增加交接成本。

資訊不足且會實質改變實作結果、需要額外權限，或新舊規則衝突時，停止相關修改並詢問使用者。
