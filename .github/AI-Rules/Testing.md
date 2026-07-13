# 測試規則

## 測試先行

- 預設使用 TDD 的 Red-Green-Refactor 循環：先建立會因缺少目標行為而失敗的測試，再以最小 production code 使測試通過，最後在測試保護下重構。
- 分析或規劃功能時，計畫必須先定義預期行為、測試層級、第一個失敗測試，以及需要的 Smoke Test 與 Regression Test，再安排 production code 修改。
- 修改 production code 前，原則上必須先新增或更新測試，不得先改 production code 再補測試。
- 優先新增或更新單元測試。
- 不適合單元測試時，先向使用者說明原因，再採用既有測試架構中最接近的測試方式。

下列修改可排除測試先行：

- YAML、pipeline、CI/CD、appsettings 等純設定檔。
- Controller 僅調整 route、attribute、binding、權限標記，或呼叫既有 service 的薄層修改。
- 純格式化、註解、log message 或命名調整。

Controller 若包含 business logic、條件判斷、錯誤處理或資料轉換，仍必須測試先行。

## 測試方針

1. 優先使用單元測試，以取得較快且穩定的回饋。
2. 單元測試不足以驗證元件整合、資料庫或外部邊界時，再使用整合測試；避免為可由單元測試涵蓋的行為增加較慢的整合測試。
3. 使用 Smoke Test 驗證主要功能與關鍵路徑沒有完全失效。
4. 使用 Regression Test 驗證本次修改沒有破壞相關既有功能。

## 框架與寫法

- 沿用專案既有測試框架：xUnit 專案使用 xUnit；NUnit 專案使用 NUnit；全新且無慣例時優先使用 NUnit。
- 測試使用 Given-When-Then 結構。
- NUnit 驗證多個條件時，優先使用 `Assert.Multiple`。
- xUnit 沿用專案既有 assertion 風格，不得使用 NUnit-only API。

## 測試涵蓋

依功能需要涵蓋：

- 正常成功情境。
- 無資料、未訂閱或 `null` 等邊界情境。
- 無權限、無效狀態或取消狀態等失敗情境。
- 排序、最早或最近資料等條件。
- 寫入功能對資料庫產生的 side effect。

## 效能測試

- 效能測試與一般功能測試必須分開。
- 效能測試必須進行多次量測，並記錄樣本數、平均執行時間、最小執行時間、最大執行時間及 DB query count；不涉及資料庫時，DB query count 標記為不適用。
- seed 完成後才可重設 SQL command counter，避免計入 Arrange 階段的 SQL。
- N+1 測試必須使用足夠資料量，並驗證 SQL 數量不隨結果筆數線性增加。
- CI 不得以執行毫秒數作為硬性門檻；應驗證 query count、查詢形狀與結果正確性。
- 手動 benchmark 預設標記為 `Skip`，不得在一般測試流程執行。
