# JIRA

## 存取方式與 API 端點

- Jira Cloud 使用 scoped API Token；從環境變數讀取 `JIRA_BASE_URL`、`JIRA_EMAIL`、`JIRA_API_TOKEN`、`JIRA_CLOUD_ID` 與 `JIRA_API_BASE_URL`。
- 所有 `/rest/api/3/...` 與 `/rest/agile/1.0/...` 呼叫都必須以 `JIRA_API_BASE_URL` 為基底；不得以 `JIRA_BASE_URL` 直接呼叫 REST API。
- 若 `JIRA_CLOUD_ID` 或 `JIRA_API_BASE_URL` 缺失，可唯讀呼叫 `${JIRA_BASE_URL}/_edge/tenant_info` 取得 Cloud ID，並將 API base 組成 `https://api.atlassian.com/ex/jira/{cloudId}`。無法安全取得必要值時停止操作並回報缺少項目，不得猜測端點。
- 優先使用遵守上述端點與憑證規則、且目前環境已核准的本機 JIRA REST helper；沒有 helper 時，僅在 `JIRA_EMAIL`、`JIRA_API_TOKEN` 與可用的 `JIRA_API_BASE_URL` 都可取得時，透過 shell 呼叫 JIRA REST API。
- 憑證只從環境變數或核准的秘密儲存區讀取。不得輸出、記錄、寫入提示詞、Instructions、Repository、命令參數或回覆，也不得以探測命令顯示其值。
- 除非目前組織明確允許且環境已配置，否則不得使用 Atlassian MCP 或 Rovo。存在 `ATLASSIAN_ROVO_MCP_TOKEN` 不代表已取得使用 MCP 的授權。

## 操作規則

- issue key、JQL、project、使用者或 transition 等識別資訊不足且可能指向不同目標時，先取得必要資訊；不得猜測。
- 讀取與搜尋只取得完成任務所需的欄位，回覆時避免揭露無關的個資、內部連結或敏感內容。
- 建立 issue、留言、指派、修改欄位或 transition 等外部寫入，只在使用者明確要求時執行。送出前確認目標 issue 與變更內容；批次、刪除或難以回復的操作必須先取得確認。
- API 失敗時回報 HTTP status、操作類型與可安全揭露的錯誤摘要；不得回傳 Authorization header、token 或完整敏感 response body。
