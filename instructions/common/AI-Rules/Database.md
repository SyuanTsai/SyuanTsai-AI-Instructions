# Database 規則

- 資料存取效能改善應先找出單次 query 載入的不必要 entity、relationship 或 row，以及多餘 round trip、N+1 等根因，再調整查詢範圍與載入方式。 <!-- ai-invariant:database.root-cause-evidence -->
- projection 是縮小資料範圍的可用手段；只擷取完成目標行為所需的欄位，並以 query plan、row／column volume、tracking 與 round trip 等證據驗證效果，不得用任意欄位數上限取代實際判斷。 <!-- ai-invariant:database.projection-evidence -->
- 優先沿用既有 business response、DTO 或 read model；需要新的內部 projection type 時，採用符合既有架構的最小 shape。只有新增或變更 public contract、跨層責任，或超出已核准修改範圍時，才向使用者確認。 <!-- ai-invariant:database.contract-boundary -->
- projection 只負責資料 shaping；business rule 與核心邏輯應保留在既有 application 或 domain 邊界。 <!-- ai-invariant:database.logic-boundary -->
- 修改前先檢查既有 query、entity 關係、索引與資料存取慣例；只檢查與任務直接相關的部分。
- 涉及 query 效能或 N+1 時，同時使用 `.agents/skills/verify-data-access-performance/SKILL.md` 進行診斷與驗證。 <!-- ai-invariant:database.performance-validation -->
