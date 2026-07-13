# 基礎 Instructions 維護規範

本 Repository 用來集中維護 AI 開發工具使用的基礎 Instructions。修改本 Repository 時，應以規則一致、內容清楚及各平台版本同步為優先。

## 檔案定位

- `.codex/AGENTS.md`：Codex 使用的繁體中文 Instructions。
- `.codex/AGENTS.en.md`：Codex 使用的英文 Instructions。
- `.github/copilot-instructions.md`：GitHub Copilot 使用的繁體中文 Instructions。
- `.github/copilot-instructions.en.md`：GitHub Copilot 使用的英文 Instructions。
- 本檔案只規範如何維護上述 Instructions，不作為任一平台版本的替代品。

## 維護原則

- 繁體中文版本為主要維護來源；英文版本必須忠實保留相同要求、例外與限制，不得自行增減規則。
- 新增或修改共通開發規則時，必須同步檢查 Codex 與 GitHub Copilot 的版本。
- 平台專屬規則只放在對應平台的檔案中，不應為了文字一致而移除必要的平台差異。
- 規則應使用明確且可執行的描述，並在必要時列出允許情境、禁止事項及例外。
- 不得加入依賴其他 Repository、未提供的對話內容或使用者本機環境才能理解的規則。
- 調整既有規則時，應保留原始意圖；若新舊要求衝突，必須先向使用者確認，不得自行選擇其中一個版本。

## 內容同步

修改 Instructions 時，依序確認：

1. 中文內容已完整表達規則與例外。
2. 對應英文檔已同步相同語意。
3. Codex 與 GitHub Copilot 的共通規則一致。
4. Codex 或 GitHub Copilot 的平台專屬內容仍保留在正確檔案。
5. 標題、清單層級、程式碼標記與專有名詞前後一致。

## 驗證與回報

- 此 Repository 以 Markdown 文件為主；純文件修改不需要新增或執行單元測試。
- 完成修改後，至少檢查 `git diff`，確認沒有遺漏同步檔案或非預期變更。
- 回報時列出修改檔案、同步內容及驗證方式；若刻意不同步某個平台或語言版本，必須說明原因。
