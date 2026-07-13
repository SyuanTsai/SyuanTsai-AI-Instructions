# Code Review 規則

- Review 以發現 bug、行為退化、安全性問題、資料風險與必要測試遺漏為優先，不因個人偏好要求改寫。
- 每個 finding 必須指出具體檔案與位置、問題成立的原因、可能影響及可執行的修正方向。
- 先列 findings 並依嚴重程度排序；沒有 finding 時明確說明，仍需指出殘餘風險或未驗證項目。
- Review 涉及 production code 或測試時，載入 `.github/AI-Rules/Testing.md`。
- 確認所有新增程式碼依適用層級包含單元測試或整合測試；個人完成的任務中，至少 90% 必須符合此要求。
- 確認貢獻程式碼維持至少 60% test coverage，並以專案既有 coverage report 或工具結果為依據。
- 若目前 Review 範圍沒有個人任務統計或 coverage 數據，必須將該門檻標記為無法驗證，不得假設已達標。
- production code 變更不屬於測試先行例外時，確認對應測試已先建立或更新；缺少時提出明確且可執行的意見。
- 依變更確認成功、邊界、失敗、排序與 database side effect 等必要測試涵蓋。
- 涉及效能測試時，確認其與功能測試分離，且未以不穩定的執行時間作為 CI 硬性門檻。
- 涉及 EF、SQL 或 query 時，載入 `.github/AI-Rules/Database.md`，並指出違反 projection 限制的位置與原因。
- 若變更使用 projection 處理效能問題，finding 必須指出 projection 並未解決根因，並說明應檢查及避免單次查詢載入不必要的資料；不得只回報違反 projection 限制。
