# SyuanTsai AI Instructions

這個 Repository 是個人 Codex／GitHub Copilot Instructions、Skills Catalog 與安裝 runtime 的 canonical source。共用 Agent Skills 只由 Catalog 指向的 external repositories 提供，本 Repository 不保存 Skill source 副本。

目前 runtime 採用 branch-independent 的個人本機 artifacts 模型：fan-out 到產品 Repository 的 `AGENTS.md`、`.codex/AI-Rules/**`、GitHub Copilot Instructions、`.agents/skills/**` 與 manifest 會存在 working tree、套用於所有 branch，但由 `.git/info/exclude` 排除。Bootstrap 永遠不會替產品 Repository stage、commit 或 push。

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
5. Mutation engine 依 manifest hash 更新未被自訂的檔案、建立新檔、移除來源已刪除且未被修改的檔案。
6. 將精確受管路徑寫入 `.git/info/exclude` 的 managed marker block，建立並重新套用一份 branch-neutral `PersonalAgent` recovery stash，最後再次驗證 bytes。

來源與目標 mapping：

- `.codex/AGENTS.en.md` → `AGENTS.md`
- `.codex/AI-Rules/*.en.md` → `.codex/AI-Rules/*.en.md`
- `.github/copilot-instructions.en.md` → `.github/copilot-instructions.md`
- `.github/AI-Rules/*.en.md` → `.github/AI-Rules/*.en.md`
- external `.agents/skills/<skill-id>/**` → `.agents/skills/<skill-id>/**`

既有 project-owned 或 customized 檔案不覆寫。若 manifest 缺失，但本機未追蹤檔案的 bytes 精確等於 immutable source，bootstrap 可安全重建 manifest；Git tracked 的同名檔案不會因此被接管。

## Branch、worktree 與自癒

個人 artifacts 不屬於任何 branch，因此正常 `git switch` 不需要手動 `stash apply`。切換 branch 後，原檔案會留在 working tree；再次執行 bootstrap 只會驗證或更新同一組 artifacts。

Linked worktree 有自己的 working directory，因此第一次使用時仍需執行 bootstrap；它會建立相同的 local ignored artifacts 模型，不修改任一 branch 的 commit。

Bootstrap 會自動修復：

- manifest 管理但遺失的檔案；
- 遺失的 manifest（僅安全接管未追蹤且 bytes 精確匹配的檔案）；
- 遺失或過期的 `.git/info/exclude` managed marker；
- immutable source 更新後仍未被自訂的受管檔案；
- 缺失或過期的 `PersonalAgent` recovery evidence。

若受管檔案有使用者修改，會保留其內容與歷史 manifest entry，並在輸出列出；不會 force overwrite。

## 新電腦安裝

需求：Windows PowerShell 5.1 或 PowerShell 7、Git、可存取 canonical GitHub Repository 與 Catalog 選中的 external repositories。

```powershell
git clone https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git
Set-Location .\SyuanTsai-AI-Instructions
git switch main
git pull --ff-only
git status --short
```

Installer 的 git-checkout 模式只接受 canonical origin、完整 `HEAD` commit，以及與 `HEAD` 完全相同的 tracked runtime sources；local edits 會在修改 Codex Home 前 fail closed。

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1
```

安裝會以 transaction 更新：

- `~/.codex/hooks/bootstrap-ai-instructions.ps1`
- `~/.codex/hooks/update-ai-instructions.ps1`
- `~/.codex/hooks/cleanup-ai-instructions-pollution.ps1`
- `~/.codex/hooks/ai-instructions-runtime/**`
- `~/.codex/ai-instructions-sync.json`
- 個人 `AGENTS.md` 的 `Repository Instructions Bootstrap` 區塊

舊 bootstrap `SessionStart` entry 會移除，其他 hooks 與個人規則保留。安裝中任何正常例外都會 restore 原 launcher、updater、cleanup、runtime、config、`AGENTS.md` 與 `hooks.json`。

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

`catalog.repository/ref` 由 installer 管理；不得手動改成其他 Repository 或 mutable ref。使用者可維護 exclusions、Skill selections 與 `updates` policy。

## Runtime 更新

預設 `notify-only`：launcher 解析 canonical candidate，若有新版只寫 receipt 與通知，仍使用目前已驗證 runtime。

手動強制檢查：

```powershell
& "$env:CODEX_HOME\hooks\update-ai-instructions.ps1" -ForceCheck
```

手動核准並安裝 candidate：

```powershell
& "$env:CODEX_HOME\hooks\update-ai-instructions.ps1" -ForceCheck -InstallApproved
```

若要由 policy 自動安裝已核准 channel 的更新，將 `updates.mode` 設為 `auto-install-approved`。Updater 仍會：

- 只接受 canonical Repository 與合法 channel/ref；
- 解析 immutable candidate commit，並以 GitHub compare 驗證它是目前 installed commit 的 descendant；behind／diverged candidate 一律標為 stale 且不安裝；
- 下載 codeload ZIP、計算 archive SHA-256、安全解壓、parse 全部 PowerShell、驗證 Catalog/Lock；
- 安裝前再次解析 candidate，遇到 TOCTOU drift 即停止；
- 透過 installer transaction swap，失敗時 rollback；
- 使用 per-Codex-Home lock 阻止並行更新；
- 以 `ai-instructions-update-receipt.json` 記錄 current、available、installed、offline、stale、drift 或 failed。

網路不可用時，updater 不會破壞或降級現有 runtime；已驗證 runtime 仍可繼續使用已安裝 Catalog/Lock。若 local runtime inventory 有缺檔、額外檔案或 hash drift，launcher/updater 會 fail closed，應重新執行可信 installer。

## Tracked pollution 與 cleanup

Personal artifacts 必須保持 untracked。若 manifest 能證明的受管路徑已進入 Git index，bootstrap 會在任何 target/index mutation 前停止，列出污染路徑，且不會自動修復 index。

先檢查內容與 manifest，再明確授權 cleanup：

```powershell
& "$env:CODEX_HOME\hooks\cleanup-ai-instructions-pollution.ps1" `
  -RepositoryRoot (git rev-parse --show-toplevel) `
  -Authorize
```

Cleanup 僅對下列路徑執行 `git rm --cached`：manifest v2 列出、目前仍 tracked、未 staged、且本機 bytes 仍等於 manifest hash 的檔案，以及 manifest 本身。它會保留 working-tree files、更新 `.git/info/exclude`，但不 commit 或 push。若有 staged conflict、customized bytes、未知 manifest、unsafe path，或目標是本 canonical source Repository，整次操作會停止並 rollback index/exclude。

Cleanup 後由使用者自行檢查並決定產品 Repository 的 commit：

```powershell
git status --short
git diff --cached --name-status
```

## Rollback 與復原

- Installer/updater 的一般失敗會自動恢復上一個完整 runtime/config 組合。
- 若 rollback 本身失敗，錯誤會保留並回報 backup path；先保存該目錄再人工處理。
- Process 被強制中止導致 runtime/config mismatch 時，launcher 會 fail closed；重新執行上一個可信 commit 的 installer。
- Target fan-out 或 stash apply 失敗時，mutation engine 恢復 target bytes、manifest、index 與 `.git/info/exclude`；新舊 `PersonalAgent` evidence 會保留供復原，不會刪除其他 stash。
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

CI 在 Windows PowerShell 5.1 與 PowerShell 7 執行 regression、production lock 與 production smoke。

## 主要檔案

- `scripts/install-ai-instructions-bootstrap.ps1`：transactional installer 與 v1–v4 migration。
- `scripts/bootstrap-ai-instructions-installed.ps1`：stable launcher、更新前後 runtime validation。
- `scripts/ai-instructions-runtime-contract.psm1`：config v4、bundle v2 與 exact inventory 契約。
- `scripts/ai-instructions-updater.psm1`、`scripts/update-ai-instructions.ps1`：更新 workflow 與 installed command。
- `scripts/bootstrap-ai-instructions-multisource.ps1`：Catalog selection、immutable acquisition 與 composition。
- `scripts/bootstrap-ai-instructions.ps1`：manifest protection、self-healing、local ignore、recovery stash 與 rollback。
- `scripts/cleanup-ai-instructions-pollution.ps1`：明確授權的 tracked pollution cleanup。
- `catalog/`：schemas、examples、Catalog、source pins 與 Lock。
- `tests/`：PowerShell 5.1／7 Pester suites。
