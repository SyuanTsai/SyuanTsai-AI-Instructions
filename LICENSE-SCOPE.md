# 授權範圍

本 Repository 自行撰寫、且列於 [licensing-scope.json](licensing-scope.json) 的通用核心，以 [Apache License 2.0](LICENSE) 授權。這不是涵蓋所有檔案與歷史版本的統一授權宣告。

## 逐檔對照

`licensing-scope.json` 是本版本的逐檔範圍表，不是 runtime 設定：

- `Apache-2.0`：列出的 Repository 自行撰寫內容適用 Apache-2.0。
- `NOASSERTION`：本次不授予額外授權；不是公有領域，也不是「禁止任何使用」的另訂授權。
- 未列出的新檔案，不因所在目錄自動加入本次授權範圍，須經來源審查後更新清單。
- 檔案內若存在其他權利人的適用聲明，仍須保留；本清單不授予本維護者無權授予的權利。

通用核心包含 Instructions、Catalog metadata、標準、安裝工具、測試及維護文件。Catalog 指向的 Skill 內容不在本 Repository 的檔案授權範圍內。

## 暫不授予額外授權

以下八個既有檔案維持來源待確認／歷史脈絡狀態；本次不刪除它們，也不藉排除聲明消除其既有公開歷史：

- `.gitignore`
- `docs/plans/ai-quota-observability-mcp/discussion-record.md`
- `docs/plans/ai-quota-observability-mcp/handoff.md`
- `docs/plans/ai-quota-routing/discussion-record.md`
- `docs/plans/ai-quota-routing/handoff.md`
- `docs/plans/felo-ai-usage/discussion-record.md`
- `docs/plans/felo-ai-usage/handoff.md`
- `docs/plans/guide-agent-cli-installation/installation-reference.md`

其中模板與來源文字待補充出處；歷史規劃須區分通用需求與個別環境觀察。排除不等於判定其屬於第三方。

## 外部來源與歷史

四個 Skill source repositories 是從本維護者的 Instructions 集合拆分並獨立維護的來源；「external source」是 Catalog 的架構名稱，不表示第三方作者。各來源的實際版本與後續新增內容，仍由各自的授權文件說明。

本版本新增的授權聲明不自動適用於所有舊 commits、其他 Repository 的所有內容、下載工具、供應商文件、使用者資料或執行輸出。詳見 [PROVENANCE.md](PROVENANCE.md) 及 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 安裝與再散布狀態

本次文件變更尚未修正 runtime／Instructions／外部 Skill 的授權文件遞送。根目錄有 LICENSE 不代表安裝產物已完整攜帶授權文件。

再散布本次涵蓋的內容時，應一併提供 LICENSE、適用 NOTICE 與範圍對照，並保留適用的第三方聲明。安裝產物尚待專項驗證，不能以本文件當成安裝／再散布合規已通過的證明。

## 貢獻

提交貢獻前須說明外部來源並保留其授權。對已標示 Apache-2.0 的內容，貢獻授權依該授權第 5 條及適用的個別約定處理；來源待確認或未列入範圍的內容不應被默認重新授權。
