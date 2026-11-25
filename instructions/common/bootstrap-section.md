## Repository Instructions Bootstrap

- 只有新增或更新 production code 的實作計畫時，才執行 `{{AI_INSTRUCTIONS_PWSH_INVOCATION}}`；單純問問題、釐清需求、確認或解釋問題，以及其他尚未開始規劃 code 的工作不得執行 bootstrap。
- Bootstrap 第一次失敗若明確屬於沙箱或權限拒絕，才可先取得核准後重試一次；同一 task 不得再次重跑。若分類為 compatibility、configuration 或 integrity，必須保留 fail-closed 結果且不得重試；回報分類與 remediation，不得偽造 capability evidence，也不得在 consumer Repository 建立 workaround。
- `notify-only` 的 `outcome=available` 只是更新通知，表示 verified candidate 尚未安裝；繼續使用目前 verified runtime，只有使用者另行明確核准更新時才執行 updater。
- 同步完成後，先讀取 Repository 新增或更新的 `AGENTS.md` 與目前任務適用的規則模組；使用者明確指定 Skill 或任務符合 `.agents/skills/` 中的 Skill description 時，再讀取對應 `SKILL.md`。
- 以 `.codex/ai-instructions.manifest.json` 管理共享 Instructions 與 Agent Skills；只更新未被個人修改的受管理檔案，不覆寫 customized or unmanaged Instructions or Agent Skills。
- Repository 的 origin 若列在目前 Codex Home 的 `ai-instructions-sync.json` 之 `excludedRepositoryUrls`，或 task 啟動目錄位於 `excludedRepositoryPaths`，直接略過同步。
- Repository-local Instructions、Skills 與 manifest 是所有 branch 共用的個人 runtime artifacts，必須保持 local ignored。若 reserved Agent artifact 已被 Git tracked，bootstrap 必須先在 Repository 外完整備份檔案與 Git 狀態，以隔離 index 建立只包含精確 reserved path deletions 的一次性本機 remediation commit，保留所有無關變更，再依最新中央來源重建並繼續同步；不得自動 push consumer Repository。Reserved 範圍外 tracked file 或無法安全隔離的狀態仍須 fail closed。
