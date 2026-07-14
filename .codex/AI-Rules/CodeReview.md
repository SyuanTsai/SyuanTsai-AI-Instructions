# Code Review 規則

- Review 以發現 bug、行為退化、安全性問題、資料風險與必要測試遺漏為優先，不因個人偏好要求改寫。
- 每個 finding 必須指出具體檔案與位置、問題成立的原因、可能影響及可執行的修正方向。
- 先列 findings，並依嚴重程度排序；沒有 finding 時明確說明，仍需指出殘餘風險或未驗證項目。
- Review 涉及 production code 或測試時，載入 `.codex/AI-Rules/Testing.md`；以最終程式與測試的正確性、風險及必要涵蓋為審查重點，TDD 歷程僅作為開發參考。
- 測試相關 finding 應對應最終變更中的實質問題，例如缺少必要測試、assertion 不足、測試可能因錯誤原因通過，或功能行為不正確。
- 確認所有新增程式碼依適用層級包含單元測試或整合測試；個人完成的任務中，至少 90% 必須符合此要求。
- 確認貢獻程式碼維持至少 60% test coverage，並以專案既有 coverage report 或工具結果為依據。
- 若目前 Review 範圍沒有個人任務統計或 coverage 數據，必須將該門檻標記為無法驗證，不得假設已達標。
- Review 涉及 EF、SQL 或 query 時，載入 `.codex/AI-Rules/Database.md` 檢查 projection 與資料存取限制。
- 若變更使用 projection 處理效能問題，finding 必須指出 projection 並未解決根因，並說明應檢查及避免單次查詢載入不必要的資料；不得只回報違反 projection 限制。
- 除非使用者明確要求修正，Review 僅提供檢查結果，不修改程式碼。
