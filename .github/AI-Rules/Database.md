# Database 規則

- 資料存取效能改善應先找出單次 query 載入的不必要 entity、relationship 或 row，以及多餘 round trip、N+1 等根因，再調整查詢範圍與載入方式。
- projection 不視為完整的效能解法，僅用於簡單取得 key 或 ID、count、boolean flag，或最多 3 個純 scalar 欄位。
- projection 不承接 business response shape、DTO、主要 application return model 或核心邏輯。
- 除非使用者明確同意，不得為了承接回傳資料而新增 model、DTO 或 class。
- 修改前先檢查既有 query、entity 關係、索引與資料存取慣例；只檢查與任務直接相關的部分。
- 涉及 query 效能或 N+1 時，同時載入 `.github/AI-Rules/Testing.md` 並依其效能測試規則驗證。
