# JIRA

## 存取方式

- 優先使用目前環境已核准的本機 JIRA REST helper；沒有 helper 時，僅在 `JIRA_BASE_URL`、`JIRA_EMAIL` 與 `JIRA_API_TOKEN` 都可由執行環境取得時，透過 shell 呼叫 JIRA REST API。
- 憑證只從環境變數或核准的秘密儲存區讀取。不得輸出、記錄、寫入提示詞、Instructions、Repository、命令參數或回覆，也不得以探測命令顯示其值。
- 除非目前組織明確允許且環境已配置，否則不得使用 Atlassian MCP 或 Rovo。存在 `ATLASSIAN_ROVO_MCP_TOKEN` 不代表已取得使用 MCP 的授權。

## 操作規則

- issue key、JQL、project、使用者或 transition 等識別資訊不足且可能指向不同目標時，先取得必要資訊；不得猜測。
- 讀取與搜尋只取得完成任務所需的欄位，回覆時避免揭露無關的個資、內部連結或敏感內容。
- 建立 issue、留言、指派、修改欄位或 transition 等外部寫入，只在使用者明確要求時執行。送出前確認目標 issue 與變更內容；批次、刪除或難以回復的操作必須先取得確認。
- API 失敗時回報 HTTP status、操作類型與可安全揭露的錯誤摘要；不得回傳 Authorization header、token 或完整敏感 response body。
