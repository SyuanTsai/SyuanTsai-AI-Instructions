# Database 規則

- projection 不能真正解決資料存取效能問題；應優先處理單次查詢載入不必要資料的根因。對於 EF 或 SQL，不得使用 projection 承接主要邏輯或回傳資料。
- projection 僅可用於簡單取得 key 或 ID、count、boolean flag，或最多 3 個純 scalar 欄位。
- 除非使用者明確同意，不得為了承接回傳資料而新增 model、DTO 或 class。
- 修改前先檢查既有 query、entity 關係、索引與資料存取慣例；只檢查與任務直接相關的部分。
- 涉及 query 效能或 N+1 時，同時載入 `.github/AI-Rules/Testing.md` 並依其效能測試規則驗證。
