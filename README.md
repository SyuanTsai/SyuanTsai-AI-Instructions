# SyuanTsai AI Instructions

這個 Repository 是個人 Codex／GitHub Copilot Instructions、Skills Catalog 與安裝 runtime 的 canonical source。共用 Agent Skills 只由 Catalog 指向的 external repositories 提供，本 Repository 不保存 Skill source 副本。

目前 runtime 採用 branch-independent 的個人本機 artifacts 模型：fan-out 到產品 Repository 的 `AGENTS.md`、`.codex/AI-Rules/**`、GitHub Copilot Instructions、`.agents/skills/**` 與 manifest 會存在 working tree、套用於所有 branch，但由 `.git/info/exclude` 排除。一般同步不會替產品 Repository stage 或 commit；只有偵測到歷史上已 tracked 的 reserved Agent artifacts 時，會建立一次性的隔離本機 remediation commit。Bootstrap 永遠不會 push 產品 Repository。

## Production 契約

- Skills Catalog schema 1：stable Skill ID、profiles、compatibility、dependencies 與 lifecycle。
- Catalog lock schema 1：把外部來源鎖定到完整 commit SHA、archive hash 與 Skill content hash。
- Managed manifest schema 2：記錄每個 target file 的完整 provenance 與 content hash。
- Personal sync configuration schema 4：記錄 exclusions、immutable runtime pin、Skill selection 與更新 policy；不含 auto-commit 欄位。
- Runtime bundle schema 2：記錄 canonical Repository、commit、acquisition、archive hash 與 exact runtime inventory。
- Update receipt schema 1：記錄上次檢查、candidate、結果與診斷。

Schemas、去識別化 examples 與完整約束見 [catalog/README.md](catalog/README.md)。可執行契約驗證：

```powershell
Import-Module .\scripts\skills-catalog-contract.psm1 -Force
Test-SkillsCatalogContract `
  -CatalogPath .\catalog\examples\skills-catalog.example.json `
  -LockPath .\catalog\examples\skills-catalog-lock.example.json `
  -ManifestPath .\catalog\examples\managed-manifest-v2.example.json `
  -ConfigurationPath .\catalog\examples\ai-instructions-sync-v4.example.json
```

## 同步模型

只有 Codex 準備建立或更新 production code 的實作計畫時，個人 `AGENTS.md` 才會要求執行 installed bootstrap；一般問答、釐清與解釋不執行。

每次執行依序完成：

1. 驗證 installed config v4、runtime bundle v2、所有 runtime bytes、Catalog 與 Lock。
2. 依更新 policy 檢查 canonical protected `main` 或 latest GitHub release；預設只通知，不自動安裝。
3. 依 Catalog selection 解析 external Skills，只取得 lock 中的 immutable commits，驗證 archive 與每個 Skill content inventory。
4. 將 Codex、GitHub Copilot 與選中的 Skills 組成已驗證 archive，再交給 mutation engine。
5. 在 common Git directory 的 repository operation lock 內先辨識 reserved tracked Agent artifacts。若存在，於 Repository 外保存 HEAD、branch、完整 active index、status、diff、檔案 bytes 與 SHA-256 inventory；加入精確 `info/exclude` 規則，以 task-scoped identity 建立只含 reserved path deletions 的 `chore: stop tracking local AI instructions` 本機 commit，再依最新來源替換精確 runtime files。無 remote、缺少永久 Git identity 或 detached HEAD 都可安全完成；detached HEAD 會建立 `codex/ai-instructions-remediation-*` 本機 branch。任何後續同步失敗會以 applied-state CAS 還原 HEAD、index、檔案與 exclude snapshot；若外部程序已變更其中狀態則保留外部內容並回報 backup，且 consumer commit 永不自動 push。
6. Mutation engine 依 manifest hash 更新未被自訂的檔案、建立新檔、移除來源已刪除且未被修改的檔案。既有 target／manifest 會以 target-root directory handle 的 final path 加上安全 relative path 核對實際 mutation handle，並拒絕 reparse file 與多重 hard-link alias；寫入在同一 deny-write/delete handle 驗證 snapshot original bytes、寫入並保存 applied bytes。新檔建立會從 target root 起逐層持有可阻擋 rename 的 parent handles，建立後再核對 file handle identity，因此 parent-junction swap 不能把 create 導向 root 外。受管檔案移除同樣在 handle-bound root confinement 內驗證 bytes，再由該 handle 設定 delete disposition，關閉後才完成刪除，不留下 verify-to-delete 或 stale-precheck path-swap 窗口。Exact-hash read-only 檔案會在 handle-bound transaction 內暫時清除 attribute；guard handle 保持開啟，且重開的 write handle 必須具有相同 volume/file ID，寫入後恢復 attribute，delete disposition 失敗時也先恢復。Rollback 只處理本交易確實變更且 current state 仍等於 applied state 的路徑；父目錄只在能以 volume/file ID 證明由本交易建立時才會刪除。
7. Bootstrap 另取得 active worktree 原生 `index.lock`，從 tracked/staged preflight 持有到 target、exclude 與 recovery evidence finalization 完成，使外部 staging 無法在成功交易中途插入。它先驗證 `info/exclude` 的完整 parent chain 都是 common Git metadata 內的 non-reparse directory，再以單一 exclusive read-modify-write handle 將所有 live worktree manifest 的精確受管路徑聯集寫入 managed marker block；manifest/config 固定以 UTF-8 讀取，Git C-quoted path 也以 strict UTF-8 bytes 解碼，因此 Unicode Skill resource 不受 Windows code page 影響。最後以不修改 active working tree/index 的 Git plumbing 建立 branch-neutral `PersonalAgent` recovery stash，並再次驗證 bytes 與 stash tree。

來源與目標 mapping：

- `.codex/AGENTS.en.md` → `AGENTS.md`
- `.codex/AI-Rules/*.en.md` → `.codex/AI-Rules/*.en.md`
- `.github/copilot-instructions.en.md` → `.github/copilot-instructions.md`
- `.github/AI-Rules/*.en.md` → `.github/AI-Rules/*.en.md`
- external `.agents/skills/<skill-id>/**` → `.agents/skills/<skill-id>/**`

`ai-instructions-contract.json` 只用於維護來源的 inventory、locale／platform parity、route、trigger 與 safety invariant regression，不會 fan out。GitHub Copilot 的 `.github/AI-Rules/**` 是由 Base Instructions 依任務明確要求讀取的條件式模組，不是 `.github/instructions/**/*.instructions.md` 的 path-specific 自動載入檔；不得以 `applyTo: "**"` 將所有模組無條件注入。不同 Copilot surface 對 Base 指示讀取其他 Repository 檔案的能力可能不同，導入新 surface 時應依 [GitHub Copilot custom instructions](https://docs.github.com/copilot/customizing-copilot/adding-custom-instructions-for-github-copilot) 驗證 References／instructions inventory，且跨 surface 必須生效的最小安全邊界應保留在 Base。

未被 Git 追蹤、且沒有 manifest ownership 的 project-owned 或 customized 檔案不覆寫。若 manifest 缺失，但本機未追蹤檔案的 bytes 精確等於 immutable source，bootstrap 可安全重建 manifest。Reserved Agent path 一旦已 tracked，則依上一節流程先完整備份並遷移，不再要求逐 Repository 人工清理。

## 官方 Felo replacement

自建 `search-with-felo` 只保留 lifecycle `removed` 的 stable-ID tombstone，不屬於任何 profile，也不出現在 production lock。官方 system Skills 維持在 Repository 外，不複製到本 Repository 或 Skill-General：

- `~/.agents/skills/felo-search/SKILL.md`
- `~/.agents/skills/felo-slides/SKILL.md`
- `~/.agents/skills/felo-x-search/SKILL.md`
- `~/.agents/skills/felo-landingpage/SKILL.md`

官方 CLI 維持 npm `felo-ai`。`felo-landingpage` 的允許來源為 `https://github.com/Felo-Inc/felo-skills.git`，本次核准 pin 為 `b42c3c0183cef64275ddda7ed7c5518ef54f2b05`。Runtime 不建立 wrapper、自建 fallback 或新的 FELO API key。

## Branch、worktree 與自癒

個人 artifacts 不屬於任何 branch，因此正常 `git switch` 不需要手動 `stash apply`。切換 branch 後，原檔案會留在 working tree；再次執行 bootstrap 只會驗證或更新同一組 artifacts。

Linked worktree 有自己的 working directory，因此第一次使用時仍需執行 bootstrap；它會建立相同的 local ignored artifacts 模型，不修改任一 branch 的 commit。所有 worktree 共用的 stash 與 `.git/info/exclude` 由同一把 repository operation lock 序列化；exclude marker 會合併所有 live worktree 的有效 manifest，避免其中一個 worktree 使另一個 worktree 的 artifacts 重新出現在 `git status`。

Bootstrap 會自動修復：

- 已 tracked 的 reserved Agent artifacts（repo 外 backup、隔離本機 untracking commit、最新 runtime 重建）；
- manifest 管理但遺失的檔案；
- 遺失的 manifest（僅安全接管未追蹤且 bytes 精確匹配的檔案）；
- 遺失或過期的 `.git/info/exclude` managed marker；
- immutable source 更新後仍未被自訂的受管檔案；
- 缺失或過期的 `PersonalAgent` recovery evidence。

`git clean -fdx` 會刻意刪除 ignored personal artifacts；下一次合法 bootstrap 會依 immutable source 重新建立完整檔案、manifest、exclude marker 與 recovery evidence，且不改變產品 Repository 的 HEAD 或 index。

若 reserved Agent path 已 staged，bootstrap 會把它納入相同的精確 remediation；既有 staged deletion 會成為隔離 commit 的 deletion，index-only addition 則移出 index 而不建立空 commit。所有無關 staged、unstaged 與 untracked product work完整保留。若其他 Git 行程已持有 index lock 或在 bootstrap finalization 期間嘗試 staging，仍會 fail closed。

未被追蹤的受管檔案若有使用者修改，會保留其內容與歷史 manifest entry，並在輸出列出；不會 force overwrite。已 tracked 且位於 reserved scope 的 customized／unmanaged artifact 則先完整備份，再依最新中央來源遷移。

## 新電腦安裝

需求：Windows PowerShell 5.1 或 PowerShell 7、Git、可存取 canonical GitHub Repository 與 Catalog 選中的 external repositories。

```powershell
git clone https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git
Set-Location .\SyuanTsai-AI-Instructions
git switch main
git pull --ff-only
git status --short
```

Installer 的 git-checkout 模式只接受 canonical origin 與完整 `HEAD` commit，並從該 immutable commit 的 Git objects 匯出精確 runtime paths 到 installer-owned snapshot；local edits 不會被執行或寫入 installed bundle。Snapshot 若缺少必要來源、無法解析或未通過 contract 驗證，會在執行 candidate module 或修改 Codex Home 前 fail closed。

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1
```

安裝會以 transaction 更新：

- `~/.codex/hooks/bootstrap-ai-instructions.ps1`
- `~/.codex/hooks/update-ai-instructions.ps1`
- `~/.codex/hooks/update-agent-environment.ps1`
- `~/.codex/hooks/cleanup-ai-instructions-pollution.ps1`
- `~/.codex/hooks/ai-instructions-runtime/**`
- `~/.codex/ai-instructions-sync.json`
- 個人 `AGENTS.md` 的 `Repository Instructions Bootstrap` 區塊

安裝完成後可由 immutable runtime 執行本機全 Repository rollout：

```powershell
$codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
& (Join-Path $codexHome 'hooks\ai-instructions-runtime\invoke-ai-instructions-rollout.ps1') `
  -ReportPath (Join-Path ([System.IO.Path]::GetTempPath()) 'ai-instructions-rollout-report.json')
```

預設只掃描 ready 的本機 fixed drives，跳過系統目錄、AppData、package caches、Codex／Agent system roots、temp／test fixtures、`node_modules`、`bin`、`obj`、reparse points 與兩個 authority repositories。Repository 以 Git common directory、worktree root 與 branch identity 去重；單一 Repository 失敗不會中止後續處理。每次 bootstrap 後會驗證 custom FELO、舊 route／manifest、tracked reserved path、非 Agent Git drift 與 official Felo inventory，並輸出可供 Jira 記錄的 JSON 統計；rollout 不執行任何 push。

舊 bootstrap `SessionStart` hook 只有在 command 指向目前 Codex Home 的 installed bootstrap path 時才會從 entry 內精確移除；不同路徑下即使檔名相同也視為個人 hook 保留，同一 entry 的其他 hooks 與個人規則也不變。Installer 在 active transaction 全程持有 Codex Home、`hooks` 與本次 staging／backup roots 的 non-reparse directory handles；stable file 透過 handle-bound create/write/delete 更新，且任何多重 hard-link alias 都在 mutation 前 fail closed。所有 stable file/runtime/exclude mutation paths 在寫入前都必須是預期類型且不是 reparse point。安裝中任何正常例外都會 restore 原 launcher、updater、Agent environment updater、cleanup、runtime、config、`AGENTS.md` 與 `hooks.json`；失敗後的 transaction runtime 會先移入 recovery backup，只有 exact bundle/inventory 仍等於已驗證 candidate 時才刪除，否則保留並回報 drift。

安裝時可追加 exclusions：

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1 `
  -ExcludedRepositoryUrls @(
    'https://example.com/acme/planning-only-project.git'
  ) `
  -ExcludedRepositoryPaths @(
    'docs/architecture-planning'
  )
```

`excludedRepositoryPaths` 只接受 repo-relative path，不接受磁碟絕對路徑、`.` 或 `..`。

## Personal sync configuration v4

Installer 會把 v1／v2／v3／v4 idempotent 遷移為 v4。舊 `autoCommitRepositoryUrls`、`autoCommitRepositoryPaths` 與 `repositoryUrls` 會移除；exclusions 與 v3/v4 Skill selections 保留。

```json
{
  "schemaVersion": 4,
  "excludedRepositoryUrls": [
    "https://example.org/acme/planning-only-project.git"
  ],
  "excludedRepositoryPaths": [
    "docs/architecture-planning"
  ],
  "catalog": {
    "repository": "https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git",
    "ref": "89abcdef0123456789abcdef0123456789abcdef",
    "profiles": ["core"],
    "includeSkills": [],
    "excludeSkills": []
  },
  "updates": {
    "mode": "notify-only",
    "channel": "protected-branch",
    "ref": "main",
    "minimumCheckIntervalMinutes": 1440
  }
}
```

`catalog.repository/ref` 由 installer 管理；不得手動改成其他 Repository 或 mutable ref。使用者可維護 exclusions、Skill selections 與 `updates` policy；`minimumCheckIntervalMinutes` 的合法範圍是 1 到 2147483647。

## Runtime 更新

預設 `notify-only`：launcher 解析 canonical candidate，若有新版只寫 receipt 與通知，仍使用目前已驗證 runtime。

啟用／停用策略：

- 要啟用自動安裝已核准 candidate，將 `updates.mode` 設為 `auto-install-approved`。
- 要停用自動安裝，將 `updates.mode` 設回 `notify-only`；這仍會執行安全版本檢查並留下通知／receipt，不代表停用檢查本身。
- 單次 production bootstrap 若必須完全略過網路版本檢查，可直接執行 installed launcher 並加上 `-SkipUpdateCheck`；下一次未帶此參數的合法 bootstrap 會恢復正常檢查。契約刻意不提供永久 `disabled` mode，以免個人 runtime 無聲地停止接收已核准的安全修正。

排程採事件驅動：每次符合 Repository Instructions Bootstrap 條件的 production-code planning 由 launcher 嘗試檢查，`minimumCheckIntervalMinutes` 會抑制過密請求。Runtime 不建立 OS scheduled task、background polling 或 SessionStart hook；需要立即檢查時使用下方 `-ForceCheck`，不另設背景排程。

手動強制檢查：

```powershell
$codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
  $env:CODEX_HOME
} else {
  Join-Path $HOME '.codex'
}
& (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') -ForceCheck
```

手動核准並安裝 candidate：

```powershell
$codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
  $env:CODEX_HOME
} else {
  Join-Path $HOME '.codex'
}
& (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') -ForceCheck -InstallApproved
```

若安裝程序被強制中止，留下「config 與 runtime bundle 各自通過 strict validation、完整 inventory 與 stable launcher identity，但兩者 immutable pin 不一致」的狀態，可由同一 stable updater 修復後繼續正常檢查：

```powershell
& (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') -RecoverInterruptedInstall
```

Recovery 只會將個人 config 的 bundle pin 對齊目前完整驗證的 active runtime commit，保留 exclusions、selection 與 update policy，完成後立即返回。Runtime inventory、stable entry-point references、schema 或 canonical identity 有任何其他錯誤時仍 fail closed，必須重新執行可信 installer。

若要由 policy 自動安裝已核准 channel 的更新，將 `updates.mode` 設為 `auto-install-approved`。Updater 仍會：

- 只接受 canonical Repository 與合法 channel/ref；
- 解析 immutable candidate commit，並以 GitHub compare 驗證它是目前 installed commit 的 descendant；behind／diverged candidate 一律標為 stale 且不安裝；
- 下載 codeload ZIP，從同一個 exclusive file handle 計算 archive SHA-256 並安全解壓；git-checkout 安裝則從完整 commit SHA 的 Git objects 建立 installer-owned snapshot，不執行 mutable worktree bytes；之後 parse 全部 PowerShell 並驗證 Catalog/Lock；
- 安裝前再次解析 candidate，遇到 TOCTOU drift 即停止；
- 透過 installer transaction swap；stable launcher、updater、Agent environment updater、cleanup、config、個人 `AGENTS.md` 與 `hooks.json` 都在 handle 內以 backup original bytes 做 CAS，失敗時只 rollback 仍等於 transaction-applied bytes 的檔案並保留並行外部修改；
- 使用 per-Codex-Home update lock 阻止並行檢查，並以獨立 install lock 序列化 manual/updater transaction；updater 從 active runtime preflight、remote resolution、archive acquisition 到 non-install receipt 落盤都持有 install-state lock，只在交給 candidate installer 前釋放。Verified launcher／updater snapshot／Agent environment updater／cleanup 在使用 runtime 時持有 shared read lock，installer 只有取得 exclusive lock 才能 swap；Agent environment `-Apply` 僅在交棒給 runtime updater 時釋放 read lock，更新後必須重新取得鎖才能 import 與 reconcile。Installer 取得鎖後會重驗 updater 選擇 candidate 時的 current commit 與 mode/channel/ref，核准已撤銷或 policy 已變更時在任何 mutation 前停止；
- 以原子替換的 `ai-instructions-update-receipt.json` 記錄 current、available、installed、offline、stale、drift 或 failed；`current` 以 `currentCommit` 表示已解析版本且 `candidateCommit` 為 `null`，避免重複身分無法由 JSON Schema 驗證。若舊 receipt 損壞，先 quarantine 再從已驗證 runtime 繼續檢查。

最小檢查間隔尚未經過時，updater 回傳不落盤的 `rate-limit` workflow 結果並保留上一份有效 receipt；鎖已被其他 updater／installer 持有時則回傳不落盤的 `concurrent` 並讓 manual command／launcher fail closed。兩者都不屬於 update receipt schema 的 persisted outcomes。

網路不可用或 GitHub API 暫時 rate-limited 時，updater 不會破壞或降級現有 runtime；已驗證 runtime 仍可繼續使用已安裝 Catalog/Lock。Stable launcher 以自身內建、未載入 runtime code 的 preflight 先驗證 strict config/bundle、launcher reference 與完整 inventory，manual updater／Agent environment updater／cleanup 也先呼叫同一 preflight，通過後才載入任何 runtime module。若 stable launcher 與 reference copy 不同，或 local runtime inventory 有缺檔、額外檔案、reparse point 或 hash drift，所有 stable entry point 都會 fail closed，應重新執行可信 installer。

## 使用者層級 Agent 環境升級

完成 runtime 安裝後，可從任何目錄以單一命令更新 runtime 並同步 `$HOME/.agents/skills`：

```powershell
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -Apply -OutputFormat Json
```

先預覽或只驗證目前狀態：

```powershell
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -Apply -WhatIf -OutputFormat Json
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -VerifyOnly -OutputFormat Json
```

第一次納管舊 Catalog 目錄時需明確加上 `-MigrateLegacyCatalogSkills`；已受管理但內容被本機修改時，只有 `-ForceReinstallManagedSkills` 會在留下 recovery backup 後重裝。Manifest 未列出的個人 Skill 永遠視為 unmanaged，不會因 prune、rename、removal 或 tombstone 被推論式刪除。更新會先完成 selection／dependency closure、所有來源下載、immutable pin、archive hash、Skill content hash 與安全 ZIP 驗證，再取得 user-scope global lock 並進入 transaction；中斷留下 journal 時必須先執行：

```powershell
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -Recover -OutputFormat Json
```

JSON 結果固定包含 `outcome` 與 `exitCode`：`0` 表示成功或目前已一致、`1` 表示失敗、`2` 表示 VerifyOnly 偵測到 drift、`3` 表示同一使用者已有更新程序持有 global lock。

## Tracked Agent artifact 自癒

Personal artifacts 必須保持 untracked。Bootstrap 以 `git rev-parse --show-toplevel`、Git common directory、worktree 與 branch identity 序列化每個 Repository；Windows 或 `core.ignorecase=true` 會使用 Git index 的實際 spelling 處理大小寫變體。允許的範圍只包含 root `AGENTS*.md`、`.agents/**`、明確 Codex/GitHub Agent runtime paths，以及舊 manifest 安全列出的 Agent／Skill targets。Manifest 若把 tracked production file 指到 scope 外，會在任何 mutation 前 fail closed。

自癒先把精確目標 bytes、HEAD／branch、active index、porcelain-v2 status、staged／unstaged diff 與 SHA-256 inventory 保存到系統 temp 下的 `codex-agent-artifact-backups`，再更新獨立的 remediated exclude block。取得 Git 原生 `index.lock` 後會先比對 backup index SHA-256；備份後插入的外部 staging 會原樣保留並讓本次 remediation 停止。Commit tree 從原 HEAD 的 private index 建立，只允許 `D` 狀態的 reserved paths；active index 則獨立移除相同 paths，因此無關 staged changes 不會進入 commit。刪除檔案前也會重驗 backup hash。Retired `search-with-felo` 只移除已知舊 implementation 檔名，包含僅存在於 working tree 的舊 implementation；未知鄰近檔案不會被推論式刪除。成功後立即執行正常同步；重跑在沒有 tracked reserved artifact 或已知 retired artifact 時不建立 commit。

`cleanup-ai-instructions-pollution.ps1` 保留作為舊版 runtime 的明確授權診斷工具，但不是新版 bootstrap 的前置步驟。Consumer remediation commit 只留在本機，任何 runtime 都不得自動 push。

## Rollback 與復原

- Installer/updater 的一般失敗會自動恢復上一個完整 runtime/config 組合；stable-file rollback 會逐檔比較 transaction-applied bytes，保留並回報並行外部修改，同時繼續恢復其他未 drift 檔案。Transaction runtime 會先隔離到 recovery backup，重新驗證 exact bundle/inventory 後才清除；無法證明仍是 candidate 的內容會保留。Staging 驗證尚未進入 active swap 就失敗時，也會清除 staging/backup transaction directories。
- 若 rollback 本身失敗，錯誤會保留並回報 backup path；先保存該目錄再人工處理。
- Process 被強制中止導致 runtime/config pin mismatch 時，launcher 會 fail closed；若 config 與 runtime 各自有效且 active inventory／stable entry-point identity 完整，可由同一 updater 的 `-RecoverInterruptedInstall` 只對齊 verified runtime pin 並立即返回，不會接續 update check 或 install。其他 drift 仍須重新執行可信 installer。
- Target fan-out 或 evidence store/verification 失敗時，mutation engine 以包含 manifest 在內的 canonical path raw SHA-256 驗證 live bytes；target／manifest 與 `.git/info/exclude` 都只在 current state 仍等於本交易 applied state 時還原。外部 drift 會原樣保留、其他未 drift 路徑仍各自安全復原，整體回報需要人工處理並保留 recovery backup。Evidence 建立本身不修改產品 index。新 `PersonalAgent` evidence 綁定 hashed worktree identity 與 exact managed Git-blob fingerprint，並以 private temporary index、`commit-tree` 與 `stash store` 建立三親 stash commit；stash tree 驗證通過後才清理同一 worktree、已證明由 runtime 建立的 prior evidence。Legacy／同名 user stash 與其他 linked worktree evidence 都會保留；若執行 drop 時仍發生外部 index drift，會依 Git 回報的實際 commit hash 還原非預期刪除的 stash 並保留舊 evidence。
- 不要用 `git reset --hard` 清理 personal artifacts；這些檔案本來就不應在 index。

設計、安全狀態機與操作 runbook 見 [docs/syp-101-autonomous-update-self-healing.md](docs/syp-101-autonomous-update-self-healing.md)。SYP-86 舊 cutover 文件只保留歷史背景，若與本文件衝突以 SYP-101 為準。

## 驗證

契約與完整回歸：

```powershell
Invoke-Pester -Script .\tests -PassThru
.\scripts\update-skills-catalog-lock.ps1 -Check
git diff --check
```

Production smoke 會用目前 clean pinned commit 安裝 temporary Codex Home，透過 real immutable archives 對 disposable target 執行兩次 bootstrap，驗證 manifest v2、external Skills、exact bytes、clean status、unchanged HEAD 與 stable `PersonalAgent` evidence：

```powershell
.\scripts\test-syp101-production-smoke.ps1
```

既有 runbook 的 `.\scripts\test-production-cutover.ps1` 仍保留為相容入口，並轉交同一份 SYP-101 smoke。

CI 在 Windows PowerShell 5.1 與 PowerShell 7 執行 regression、production lock 與 production smoke。

## 授權

本 Repository 自行撰寫且明列於 [逐檔範圍表](licensing-scope.json) 的通用核心採 [Apache-2.0](LICENSE)。這不是涵蓋全部檔案、歷史版本或外部 Skill source 的統一授權；八個待確認模板／歷史規劃檔不在本次授權範圍。

請一併閱讀 [授權範圍](LICENSE-SCOPE.md)、[NOTICE](NOTICE)、[來源說明](PROVENANCE.md) 與 [外部來源聲明](THIRD_PARTY_NOTICES.md)。四個 Skill Repository 為同源拆分、分別維護的來源，其版本授權由各自文件說明。

Runtime／Instructions／選取的 Skill 會遞送來源版本的授權文件、來源路徑與 hash 收據，並納入既有受管 inventory。詳見 [授權文件遞送](docs/license-delivery.md)。既有舊 pin 若沒有授權聲明，會明確提示缺失；不會套用中央來源的新授權。

## 主要檔案

- `scripts/install-ai-instructions-bootstrap.ps1`：transactional installer 與 v1–v4 migration。
- `scripts/installer-safe-mutation.psm1`：installer stable-file 的 handle-bound mutation 與目錄 guard。
- `scripts/bootstrap-ai-instructions-installed.ps1`：stable launcher、更新前後 runtime validation。
- `scripts/ai-instructions-runtime-contract.psm1`：config v4、bundle v2 與 exact inventory 契約。
- `scripts/ai-instructions-updater.psm1`、`scripts/update-ai-instructions.ps1`：更新 workflow 與 installed command。
- `scripts/agent-environment-reconciler.psm1`、`scripts/update-agent-environment.ps1`：使用者層級 Catalog Skills transaction、recovery 與單一升級入口。
- `scripts/bootstrap-ai-instructions-multisource.ps1`：Catalog selection、immutable acquisition 與 composition。
- `scripts/bootstrap-ai-instructions.ps1`、`scripts/agent-artifact-remediation.psm1`：manifest protection、tracked reserved artifact 自癒、local ignore、recovery evidence 與 rollback。
- `scripts/ai-instructions-rollout.psm1`、`scripts/invoke-ai-instructions-rollout.ps1`：fixed-drive Repository discovery、逐 Repo bootstrap、post-scan 與結構化 rollout report。
- `scripts/cleanup-ai-instructions-pollution.ps1`：舊 runtime 使用的明確授權 tracked pollution 診斷／cleanup。
- `catalog/`：schemas、examples、Catalog、source pins 與 Lock。
- `tests/`：PowerShell 5.1／7 Pester suites。
