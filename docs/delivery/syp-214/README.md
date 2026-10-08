# SYP-214 USER-only delivery and recovery

共用 Catalog Skills 只安裝／更新 USER。Consumer bootstrap 同步 Instructions，不安裝、更新或重建共用 REPO Skills；USER 不可用也不回退。專案自有 Skills、客製、未受管、tracked/staged、額外資源及來源不明的舊副本保留。此交付承接 SYP-215 的驗收缺口；正式 runtime／真實 USER 整批部署及 Codex/Copilot UI discovery 由 SYP-259 承接，保留 `notify-only`。

## Review and reproducibility

從來源 PR 取得精確 candidate commit；不要用本機已安裝的舊 runtime 證明 candidate。此目錄的驗證報告記錄實際 Red/Green、回歸、exit/skip 與 installed smoke 的版本。未執行項目明列 `not-run`。

```powershell
git remote get-url origin
git fetch origin main
git status --short
git rev-parse HEAD origin/main
Import-Module Pester -RequiredVersion 4.10.1 -Force
Invoke-Pester -Script ./tests -PassThru
./scripts/update-skills-catalog-lock.ps1 -Check
git diff --check
./scripts/test-syp101-production-smoke.ps1 -EvidencePath ./smoke-result.json
```

CI 的 bounded Windows Core Pester 與既有 authority gate 仍使用中央入口。不要改數量或略過失敗讓 gate 通過。Smoke 在系統 temp 建立 Codex Home、USER 與 disposable consumer，先經 verified installed USER updater 套用真實 immutable archives，再執行兩次 installed bootstrap，檢查 USER bytes、consumer Instructions、零共用 Skill entries、同名 project Skill、HEAD/index/status 與 recovery evidence。它不等於真實 client UI 驗收。

## Operator sequence for SYP-259

1. 核對 PR／candidate 的 review、正常 CI 與精確 commit；依既有部署分工選定 runtime。保存原 runtime commit/config、USER manifest 及完整 raw-byte inventory。保持 `notify-only`；candidate notification 不代表已安裝。
2. 依既有 installer/updater 的獨立核准部署步驟安裝 verified runtime；先執行 USER updater `-Apply -WhatIf`／`-VerifyOnly`，再依 SYP-259 明確授權執行 `-Apply`。若 USER 有 recovery journal，先 `-Recover`；客製檔案不可直接 force，須依原 USER 流程確認備份與 ownership。
3. 只對明確指定 consumer 執行盤點及 bootstrap。以下 `$deploymentCodexHome`、`$consumerRoot`、`$userRoot` 必須由該主機真實路徑提供，不使用此開發主機的絕對路徑。

```powershell
$consumerHook = Join-Path $deploymentCodexHome 'hooks/bootstrap-ai-instructions.ps1'
& $consumerHook -TargetRoot $consumerRoot -UserHome $userRoot -WhatIf
# After reviewing the inventory and USER verification:
& $consumerHook -TargetRoot $consumerRoot -UserHome $userRoot -SkipUpdateCheck
& $consumerHook -TargetRoot $consumerRoot -UserHome $userRoot -SkipUpdateCheck
```

4. 保存 migration dry-run 原因、舊／新 consumer manifest、REPO/USER 全部檔案 inventory、journal/backup、兩次 bootstrap 及 branch 切換後的 bytes、HEAD/index/status。只允許預期 Instructions 更新與已證明可退休的舊副本變更。
5. 在真實 Codex 與 Copilot client 驗證共用 Skill 的 USER discovery、無 REPO 重複項、專案自有 Skill 仍可發現，以及 Instructions 仍生效。記錄 client/version、所用 commit 與具體觀察；無法操作 client 就維持未驗收。殘留 UI cache 推測不得寫成根因已證實或通過。

## Whole-Skill migration rules

刪除資格以整個 stable ID 為單位，從 supported 舊 REPO manifest 取得來源與逐檔 raw SHA-256，並核對全部實體檔案、ignored/untracked/HEAD/index 狀態。USER manifest 的 Catalog identity、來源 identity/version/immutable pin、完整選定來源 inventory、payload 和 license delivery bytes 必須各自可信；較新 USER bytes 不拿來當舊 REPO hash。任一必要證據缺失就保留整個 Skill 及原 entries，回報 USER 修復或人工處理。沒有 manifest，即使同名或同 hash 也不接管。

新 consumer desired set 永遠不含共用 Skills；direct/legacy archive 亦受最終寫入邊界限制。既有 schema v1 未具來源 ownership 的 Skills 保留；v2/v3 可只移除已驗證副本 entries。原 Instructions remediation 保留，Skills 明確排除於 reserved remediation 與舊 pollution cleanup；retired 名稱本身不是刪除證據。

`-WhatIf` 不建立 operation/index lock，不做 remediation，也不改 payload、manifest、Git exclude、index 或 USER；來源 acquisition 的暫存目錄會清除。Apply 在每個精確刪除前重驗完整 inventory、USER bytes、Git state 與 ignore state；mutation handle 再核對實際 bytes 及 root confinement。

## Recovery

成功遷移及故障均保留 Repository 外的 `target-backup/skill-migration.json` 與 raw-byte backups；輸出會提供實際位置。將這些證據安全保存，不把 consumer 的私人 bytes 提交到公共來源 PR。一般例外自動 rollback；需要人工恢復时使用同一 verified candidate 的 runtime script：

```powershell
$runtimeBootstrap = Join-Path $deploymentCodexHome 'hooks/ai-instructions-runtime/bootstrap-ai-instructions.ps1'
& $runtimeBootstrap -TargetRoot $consumerRoot -RecoverSkillMigration $retainedJournalPath
```

Recovery 核對 journal root/schema、backup hashes、HEAD/index、安全路徑及當前 applied/original bytes。它只恢復本交易列出的路徑，後續編輯原樣保留並回報失敗；其他未 drift 路徑仍可各自恢復。不要以 `reset --hard`、整目錄刪除或 journal 刪除代替恢復。若 process 強制中止留下 Git `index.lock`，先由 operator 確認沒有持有該 lock 的 Git/bootstrap 程序，再依 Git lock recovery 處理；本入口不推定 stale lock 可刪。

日誌在刪除、Instructions/manifest 寫入及 exclude 寫入前保存 intent。測試涵蓋注入例外、durable recovery、尚未完成 final write 的 intent、備份損壞與後續編輯；未執行真實斷電／process kill，這項不宣稱通過。Recovery 不修改 USER 安裝，也不復原 Git stash history；保留的 Instructions recovery stash 仍可作為歷史證據。

如需 runtime rollback，依既有 transactional updater/installer 恢復已驗證舊 pin。舊 runtime 可能再次 fan out REPO Skills，必須記錄這個限制並停止宣稱 USER-only 已生效；consumer 檔案恢復只限本交易清單。

## English scope

Shared Catalog Skills are installed and updated only by the USER reconciler. Consumer bootstrap synchronizes Instructions and never falls back to REPO installation. Complete historical ownership, unchanged raw bytes, ignored/untracked Git state and a independently verified full USER installation are required before retiring an entire old shared Skill. Project-owned, customized, unmanaged, tracked/staged, extra-file and ambiguous copies are preserved. Dry-run is read-only; apply revalidates before precise deletion and retains a durable backup/journal outside the consumer. Recovery preserves later edits. SYP-259 owns real runtime/USER deployment and client discovery; source tests and isolated smoke do not pass those acceptance items.
