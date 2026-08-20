# SyuanTsai AI Instructions

這個 Repository 是個人 Codex／GitHub Copilot Instructions、Skills Catalog 與安裝 runtime 的 canonical source；production Agent Skills 由 Catalog 指向的外部 repositories 提供。換電腦後，只要讓 Codex 完整讀取本檔案並依照「新電腦安裝」執行，即可重建目前的按需 bootstrap 設定。

## Agent Skills Catalog P0 契約

為了讓 Agent Skills 由多個外部 repositories 提供，同時保留選擇性安裝、版本鎖定與安全同步，本 Repository 維護下列跨 Repository 契約：

- Skills Catalog schema 1：stable Skill ID、group、profiles、compatibility、hard／conditional／recommended dependencies 與 lifecycle。
- Catalog lock schema 1：將 branch／tag／commit ref 鎖定到完整 commit SHA、archive hash 與每個 Skill 的 deterministic content hash。
- Managed manifest schema 2：每個目標檔案各自記錄 source Repository、ref、commit、version、Skill identity、source／target path 與 hash。
- 個人 sync configuration schema 3：在既有 allowlist／exclusions 之外，新增 Catalog ref、profiles 與 individual include／exclude。

完整規則、升級行為、去識別化 examples 與 executable schemas 請見 [`catalog/README.md`](catalog/README.md)。契約 validator 可用下列方式執行：

```powershell
Import-Module .\scripts\skills-catalog-contract.psm1 -Force
Test-SkillsCatalogContract `
  -CatalogPath .\catalog\examples\skills-catalog.example.json `
  -LockPath .\catalog\examples\skills-catalog-lock.example.json `
  -ManifestPath .\catalog\examples\managed-manifest-v2.example.json `
  -ConfigurationPath .\catalog\examples\ai-instructions-sync-v3.example.json
```

production bootstrap 已使用這組契約：tracked Catalog lock 固定四個外部來源，schema v3 選出 Skills，manifest v2 記錄每個檔案的來源 provenance。Runtime 不使用 Git submodule，也不依 source ID 寫 domain-specific 分支。

## 給新電腦 Codex 的指示

在這個 Repository 根目錄開啟 Codex，貼上以下內容：

```text
請完整讀取 README.md，依「新電腦安裝」重建個人 Codex bootstrap 設定。
保留既有的 ~/.codex/AGENTS.md 與 hooks.json 內容，合併本文件指定的區塊，並移除舊版 bootstrap SessionStart hook、保留其他 hooks。將 ai-instructions-sync.json 遷移成 README 指定的 schema，保留仍允許自動 commit 的 Repository URL、明確排除同步的 Repository URL 與 Repository-relative 目錄，移除不再支援的舊版本機路徑設定。
安裝後依「驗證」執行檢查；不得 push，也不得覆寫目標 Repository 已自行修改或不受 manifest 管理的 Instructions 或 Agent Skills。
```

## 目前的按需同步流程

只有 Codex 準備建立或更新 production code 的實作計畫時，個人 `AGENTS.md` 才會要求執行已安裝的 `bootstrap-ai-instructions.ps1`。單純問問題、釐清需求、確認或解釋問題，以及其他尚未開始規劃 code 的工作，不執行同步，也不會僅為這些工作將共享 Instructions 或 manifest 加入 Repository。

同步流程如下：

1. 取得目前所在的 Git Repository 根目錄；不在 Git Repository 時直接略過。
2. 若目前就是本 Instructions 來源 Repository，直接略過，避免把維護用的根目錄 `AGENTS.md` 當成 fan-out 目標。
3. 驗證安裝時一併部署的 Catalog 與 tracked lock，依個人 schema v3 設定的完整 commit SHA 下載 Instructions，並只從 lock 的 `resolvedCommit` 下載被選取的外部 Skill 來源。
4. Codex 的來源與目標 mapping：
   - `.codex/AGENTS.en.md` → 目標 Repository 的 `AGENTS.md`
   - `.codex/AI-Rules/*.en.md` → 目標 Repository 的 `.codex/AI-Rules/*.en.md`
5. GitHub Copilot 的來源與目標 mapping：
   - `.github/copilot-instructions.en.md` → 目標 Repository 的 `.github/copilot-instructions.md`
   - `.github/AI-Rules/*.en.md` → 目標 Repository 的 `.github/AI-Rules/*.en.md`
6. Codex 與 GitHub Copilot 共用 Agent Skills 的 mapping：外部來源 `.agents/skills/<skill-name>/**` → 目標 Repository 的相同路徑；只同步 selection 選中、lock 驗證通過、合法命名且含 `SKILL.md` 的 Skill，scripts、references、assets、hidden resources 與二進位內容都以原始位元組安全同步。
7. 使用目標 Repository 的 manifest v2 記錄 catalog／lock identity，以及每個受管理檔案的 source Repository、ref、commit、version、路徑與 SHA-256。既有 manifest v1 只有在所有受管檔案未修改時才一次性升級；否則在寫入前停止。
8. 目標 Repository 可繼續以 Git ignore（包含 `.gitignore`、`.git/info/exclude` 或 global excludes）排除個人 Agent 設定；即使規則同時排除 `AGENTS.md`、`.codex/**`、`.github/copilot-instructions.md`、`.github/AI-Rules/**` 或 `.agents/skills/**`，仍依 manifest 正確新增、更新或移除共享受管理檔案。allowlist commit 與非 allowlist `PersonalAgent` stash 只對精確的受管理檔案與 manifest 越過 ignore，不納入同目錄中的個人設定、unmanaged 檔案或其他 ignored 內容。
9. 來源 Agent 或 Skill 更新後，只自動更新內容仍等於 manifest hash 且沒有 staged changes 的受管理檔案；尚未 commit 的前一次同步結果仍可繼續更新。
10. 來源新增 rule module、Skill 或 Skill resource 時自動建立；來源移除時，只刪除未被專案修改的受管理檔案。
11. 已由專案自行修改或原本就不受管理的 Instructions 與 Skills 不覆寫；若 Base file 不受管理，整個 instruction family 都不自動補齊，並在輸出中列出衝突路徑。
12. 舊版 bootstrap 建立的檔案若仍與其 `chore: add shared AI instructions` 建立 commit 完全一致，會安全接管並建立 manifest。
13. 讀取目前 Repository 的 `origin` URL 與 task 啟動目錄；若實際 Repository 位置列在個人 `~/.codex/ai-instructions-sync.json` 的 `excludedRepositoryUrls`，或啟動目錄位於 `excludedRepositoryPaths` 的 repo-relative 目錄底下，直接略過，不下載、不套用、不建立 stash 或 commit。
14. 只有實際 Repository 位置列在 `autoCommitRepositoryUrls` 時才自動 commit。首次建立使用 `chore: add shared AI instructions`，後續更新使用 `chore: sync shared AI instructions`。
15. 非 allowlist 且未被排除的 Repository 或目錄仍同步 Instructions、Skills 與 manifest，但不 stage、不 commit；同步結果會建立為名稱 `PersonalAgent` 的 Git stash，並以停用 `core.autocrlf` 的方式 apply 回 working tree，避免 Skill raw bytes 被換行轉換。
16. 來源沒有更新時保留現有 `PersonalAgent` stash；需要更新時，先成功建立、套用並重新驗證所有受管檔 hash，再刪除舊的同名 stash。驗證失敗時保留新舊 stash；其他 stash 不受影響。
17. 所有 Repository 都保留 unrelated staged/unstaged changes，而且永遠不自動 push。

## 新電腦安裝

### 1. 前置需求

- Windows PowerShell 5.1 或 PowerShell 7。
- Git 可由終端機執行；只有 allowlist Repository 的自動 commit 需要先設定 `user.name` 與 `user.email`。
- Codex Desktop 或其他會載入個人 `AGENTS.md` 的 Codex surface。
- 能連線至 `https://github.com/SyuanTsai/SyuanTsai-AI-Instructions`。

### 2. 取得來源 Repository

Repository 可以放在任意本機路徑，不得依賴舊電腦的 `C:\GitFile\...` 路徑：

```powershell
git clone https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git
Set-Location .\SyuanTsai-AI-Instructions
```

如果已經 clone，先確認目前 branch 與來源：

```powershell
git switch main
git pull --ff-only
git remote get-url origin
```

### 3. 執行本機安裝腳本

Codex home 優先使用 `CODEX_HOME`；未設定時使用目前使用者的 `~/.codex`。執行安裝腳本會完成下列本機設定：

- 安裝 `bootstrap-ai-instructions-installed.ps1` 作為個人 hook，並將 multi-source wrapper、mutation engine、安全 ZIP 模組、Catalog 與 tracked lock 複製到 `$codexHome/hooks/ai-instructions-runtime/`；執行時不依賴 clone 的本機路徑。
- 建立或遷移 `$codexHome/ai-instructions-sync.json` 為 schema version 3；v1／v2 保留合法 routing arrays 並新增安全 Catalog defaults，既有 v3 原樣保留 profiles 與 individual include／exclude，未知 schema 在安裝檔案變更前停止。
- 在 `$codexHome/AGENTS.md` 新增或更新 `Repository Instructions Bootstrap` 區塊，保留其他個人規則。
- 從 `$codexHome/hooks.json` 移除舊版 bootstrap `SessionStart` entry，保留其他 hooks；檔案不存在時不建立。

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1
```

若要在安裝時加入允許自動 commit 的 Repository，可傳入 URL；請只使用真實 remote URL，不要使用本機資料夾路徑：

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1 `
  -AutoCommitRepositoryUrls @(
    'git@example.com:your-account/owned-project-a.git',
    'https://example.com/your-account/owned-project-b.git'
  )
```

若要在安裝時加入完全不套用共享 Instructions 的 Repository，可傳入排除 URL；若只要排除 monorepo 內某個規劃目錄，可傳入 repo-relative path：

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1 `
  -ExcludedRepositoryUrls @(
    'git@example.com:your-account/planning-only-project.git'
  ) `
  -ExcludedRepositoryPaths @(
    'docs/architecture-planning'
  )
```

安裝後的 bootstrap script 不依賴來源 Repository 的本機路徑；執行時只下載 schema v3 與 lock 指定的完整 commits，先驗證所有 archives 與 Skill inventories，再依 manifest v2 安全同步新增、更新與移除。

### 4. 設定允許自動 commit 與排除同步的 Repository 或目錄

安裝腳本會建立或保留 `$codexHome/ai-instructions-sync.json`。需要手動調整 allowlist、Repository 排除清單或目錄排除清單時，編輯成以下格式：

```json
{
  "schemaVersion": 3,
  "autoCommitRepositoryUrls": [
    "git@example.com:your-account/owned-project-a.git",
    "https://example.com/your-account/owned-project-b.git"
  ],
  "excludedRepositoryUrls": [
    "git@example.com:your-account/planning-only-project.git"
  ],
  "excludedRepositoryPaths": [
    "docs/architecture-planning"
  ],
  "catalog": {
    "repository": "https://example.org/acme/ai-instructions.git",
    "ref": "89abcdef0123456789abcdef0123456789abcdef",
    "profiles": ["core"],
    "includeSkills": [],
    "excludeSkills": []
  }
}
```

請只在個人 `~/.codex/ai-instructions-sync.json` 填入真實 URL；本 Repository 的文件與測試只能使用虛構範例，不得記錄私人 Repository 的組織、名稱或 URL。

規則：

- 判斷依據是 `git remote get-url origin` 回傳的實際 Repository URL，不使用本機資料夾名稱或絕對路徑。
- SSH 與 HTTPS URL 會正規化為相同的 host 與 Repository path；比對不分大小寫，尾端 `.git` 與斜線不影響結果。
- Repository 移動資料夾或換電腦後不需要修改 allowlist；若 `origin` 改指向 fork 或其他 Repository，便不再符合 allowlist。
- 列在 `excludedRepositoryUrls` 的 Repository 直接略過同步；適合只用來規劃架構、沒有實際程式碼或不應套用共享 Agent Instructions 的專案。
- 列在 `excludedRepositoryPaths` 的目錄會依 task 啟動目錄判斷；當 Codex 從該 repo-relative 目錄或其子目錄啟動時略過同步，從同一個 Repository 的其他目錄啟動時仍照常同步。
- `excludedRepositoryPaths` 只接受 repo-relative path，例如 `docs/architecture-planning`；不得使用本機絕對路徑、`.` 或 `..`。
- 同一個 Repository 同時列在 `autoCommitRepositoryUrls` 與 `excludedRepositoryUrls`，或啟動目錄命中 `excludedRepositoryPaths` 時，以排除為優先。
- `catalog.ref` 必須是安裝來源的完整小寫 40-character commit SHA；`profiles`、`includeSkills` 與 `excludeSkills` 決定實際 fan-out 的 Skill set，明確 exclude 優先。
- 設定檔不存在、清單為空或目前 Repository 不在清單時，仍會同步檔案，但不會 stage、commit 或 push；同步內容會保存到 `PersonalAgent` stash 並立即 apply 回 working tree。
- 只有明確列入清單的 Repository 才會自動 commit；自動 commit 仍永遠不會 push。
- 不要把主要負責人不是自己的 Repository 加入清單。

最安全的預設設定是空清單：

```json
{
  "schemaVersion": 3,
  "autoCommitRepositoryUrls": [],
  "excludedRepositoryUrls": [],
  "excludedRepositoryPaths": [],
  "catalog": {
    "repository": "https://example.org/acme/ai-instructions.git",
    "ref": "89abcdef0123456789abcdef0123456789abcdef",
    "profiles": ["core"],
    "includeSkills": [],
    "excludeSkills": []
  }
}
```

### 5. 確認個人 AGENTS.md

安裝腳本會保留既有個人規則，並新增或更新下列區塊；若手動維護，確認同一區塊不要重複附加：

```markdown
## Repository Instructions Bootstrap

- 只有準備建立或更新 production code 的實作計畫時，才執行 `$CODEX_HOME/hooks/bootstrap-ai-instructions.ps1`；未設定 `CODEX_HOME` 時使用 `~/.codex/hooks/bootstrap-ai-instructions.ps1`。
- 單純問問題、釐清需求、確認或解釋問題，以及其他尚未開始規劃 code 的工作，不得執行 bootstrap，也不得僅為這些工作將共享 Instructions 或 manifest 加入 Repository。
- 同步完成後，先讀取 Repository 新增或更新的 `AGENTS.md` 與目前任務適用的規則模組，再提出實作計畫。
- 以 `.codex/ai-instructions.manifest.json` 管理共享檔案；只更新未被專案修改的受管理檔案，不得覆寫 customized 或 unmanaged Instructions。
- Repository 可繼續用 Git ignore 排除個人 Agent 設定；ignore 不代表 manifest 管理的共享檔案是 customized 或 unmanaged。bootstrap 只可對精確的受管理檔案與 manifest 越過 ignore，不得納入同目錄中的個人設定、unmanaged 檔案或其他 ignored 內容，也不得因受管理路徑被 ignore 而停止。
- Repository 的 `origin` 實際位置列在 `~/.codex/ai-instructions-sync.json` 的 `excludedRepositoryUrls`，或 task 啟動目錄位於 `excludedRepositoryPaths` 的 repo-relative 目錄底下時，直接略過同步；不得使用本機資料夾位置判斷。
- 只有 Repository 的 `origin` 實際位置列在 `autoCommitRepositoryUrls` 時才自動 commit。非 allowlist 且未被排除的 Repository 或目錄仍同步檔案，但不得 stage 或 commit，並以 `PersonalAgent` stash 保存後立即 apply 回 working tree。
- 更新非 allowlist Repository 時，只能在新版 `PersonalAgent` stash 成功建立並套用後刪除舊的同名 stash；不得刪除其他 stash。
- allowlist Repository 只 commit bootstrap 新增、更新、移除的受管理檔案與 manifest；首次使用 `chore: add shared AI instructions`，後續使用 `chore: sync shared AI instructions`，永遠不得自動 push。
- GitHub 無法存取、目前位置不是 Git Repository 或無法安全隔離 commit 時，停止 bootstrap 並回報原因。
```

### 6. 確認已停用 SessionStart bootstrap

安裝腳本不建立 bootstrap `SessionStart` hook。若 `hooks.json` 已有舊版 `bootstrap-ai-instructions.ps1` entry，安裝時只移除該 entry；其他 event、matcher 與 command 全部保留。`hooks.json` 不存在時不建立，存在時則在寫入前後使用 `ConvertFrom-Json` 驗證 JSON。

### 7. 重新啟動 Codex

關閉並重新開啟 Codex，讓更新後的個人 `AGENTS.md` 生效。之後在開始規劃 production code 時，Codex 會先按規則執行同步腳本；一般問答不會觸發。

## 在其他 branch 取得 PersonalAgent

非 allowlist Repository 同步後，Agent 檔案仍會留在目前 working tree，同時保留一份 `PersonalAgent` stash。切換到其他 branch 後，可先尋找同名 stash：

```powershell
git stash list --format='%gd %gs'
```

確認 reference 後套用，例如：

```powershell
git stash apply 'stash@{0}'
```

使用 `apply`，不要使用 `pop`，才能繼續保留 `PersonalAgent` stash。若目標 branch 已有同路徑的自訂 Instructions，Git 可能產生 conflict；不得使用 force 覆寫，應保留專案版本或人工合併。

## 升級與 rollback

先備份個人 `ai-instructions-sync.json`，再執行 installer。若 schema v1 manifest 含 customized、staged 或 missing managed files，bootstrap 會停止，不會自動升級；先保留專案內容並人工決定是否移除舊 manifest。完整的 preflight、rollback 與復原步驟見 [`docs/syp-86-production-cutover.md`](docs/syp-86-production-cutover.md)。

## 驗證

### 設定驗證

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$hookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
$hooksFile = Join-Path $codexHome 'hooks.json'
$syncConfigurationFile = Join-Path $codexHome 'ai-instructions-sync.json'

Test-Path -LiteralPath $hookScript
Get-Content -Raw -LiteralPath $syncConfigurationFile | ConvertFrom-Json | Out-Null
Select-String -LiteralPath (Join-Path $codexHome 'AGENTS.md') -SimpleMatch 'Repository Instructions Bootstrap'
if (Test-Path -LiteralPath $hooksFile) {
    Get-Content -Raw -LiteralPath $hooksFile | ConvertFrom-Json | Out-Null
    -not [bool](Select-String -LiteralPath $hooksFile -SimpleMatch 'bootstrap-ai-instructions.ps1' -Quiet)
}
```

各項都必須成功；若 `hooks.json` 存在，不得再包含 bootstrap command。逐一確認 `autoCommitRepositoryUrls` 只包含允許自動 commit 的 Repository、`excludedRepositoryUrls` 只包含應完全略過同步的 Repository、`excludedRepositoryPaths` 只包含應略過同步的 repo-relative 目錄，並用 `git remote get-url origin` 核對實際 URL。

### Script tests

在本 Repository 根目錄執行：

```powershell
Import-Module Pester
Invoke-Pester -Script @(
    '.\tests\bootstrap-ai-instructions.Tests.ps1'
    '.\tests\bootstrap-ai-instructions-multisource.Tests.ps1'
    '.\tests\install-ai-instructions-bootstrap.Tests.ps1'
    '.\tests\skills-catalog-contract.Tests.ps1'
    '.\tests\skills-source-acquisition.Tests.ps1'
    '.\tests\production-skills-catalog.Tests.ps1'
)
```

所有列出的 test files 必須為 `0 failed`。涵蓋 schema v3 installer、manifest v1→v2 遷移、per-file provenance、production lock completeness／staleness、四來源 selection／routing、immutable archive 與 Skill inventory hashes、安全 ZIP extraction、PowerShell 5.1 hidden／long-path 行為，以及 `core.autocrlf=true` 的 non-allowlist raw-byte no-op。

### Smoke test

分別以 allowlist 與非 allowlist 設定，在可丟棄的空白 Git Repository 中執行已安裝的 hook script。確認：

- 建立 `AGENTS.md`、`.codex/AI-Rules/*.en.md`、`.github/copilot-instructions.md`、`.github/AI-Rules/*.en.md`、來源中存在的 `.agents/skills/<skill-name>/**` 與 `.codex/ai-instructions.manifest.json`；不建立 `.agents/skills/.gitkeep`。
- allowlist Repository 的最新 commit message 是 `chore: add shared AI instructions`，而且只包含 bootstrap 新增的檔案。
- 非 allowlist Repository 取得相同檔案，但 HEAD、Git index 與遠端都不變；檔案留在 working tree，且 `git stash list` 只出現一份最新的 `PersonalAgent` stash。
- excluded Repository 不建立 `AGENTS.md`、manifest、commit 或 `PersonalAgent` stash，並輸出 repository is excluded。
- 從 excluded repo-relative 目錄啟動時，不建立 `AGENTS.md`、manifest、commit 或 `PersonalAgent` stash，並輸出 directory is excluded；從同一 Repository 的其他目錄啟動時仍照常同步。
- 新建 `PersonalAgent` stash 後檔案會自動 apply 回 working tree，stash reference 仍存在；無來源更新時不重建 stash。
- 未變更來源時再執行一次，顯示 Instructions 已是最新版本且不新增 commit。
- 使用更新過的來源 archive 做 Regression Test 時，未客製化的受管理檔案會更新，commit message 是 `chore: sync shared AI instructions`。
- 修改一個目標 Agent 後再同步，該檔案會保留且輸出列出 customized path，其他未修改的受管理檔案仍正常更新。
- 將上述任一受管理路徑加入 Git ignore 後，首次同步與後續來源更新仍會正確反映在 working tree；allowlist commit 或非 allowlist `PersonalAgent` stash 只包含精確的受管理檔案與 manifest，相同 ignored 目錄中的個人檔案不會被納入。
- 測試完成後只刪除可丟棄的測試 Repository，不得在正式 Repository 做清除操作。

## 維護與更新

- 共通 Instructions 與 Agent Skills 依根目錄 `AGENTS.md` 維護：Instructions 先改繁體中文來源，再同步 Codex、GitHub Copilot 與英文版本；Agent Skill 維持單一平台中立的 `.agents/skills/<skill-name>/SKILL.md` 與必要資源。
- 修改 `scripts/bootstrap-ai-instructions.ps1` 時，先更新 `tests/bootstrap-ai-instructions.Tests.ps1` 並執行 Pester。
- 本 Repository 的英文 Instructions 更新並 push 至 GitHub 後，各專案會在下一次開始規劃 production code 時同步未被客製化的受管理檔案。
- 修改 `~/.codex/ai-instructions-sync.json` 的 `autoCommitRepositoryUrls` 即可依 origin URL 控制哪些 Repository 允許自動 commit；修改 `excludedRepositoryUrls` 可讓規劃用或不應套用共享 Instructions 的 Repository 完全略過同步；修改 `excludedRepositoryPaths` 可排除同一 Repository 內的規劃目錄。未列入且未排除的 Repository 更新 working tree 並保留 `PersonalAgent` stash。
- 已存在但不受 manifest 管理的專案 Instructions 或 Agent Skills 不會被自動接管；唯一例外是可由 Git history 證明仍未修改的舊版 bootstrap 產物。
- bootstrap script 更新後，個人 hook 目錄中的已安裝副本不會自動更新。重新執行安裝腳本並重啟 Codex，讓個人 `AGENTS.md` 與按需執行的 script 一併更新。
- `scripts/`、`tests/` 與本 `README.md` 必須一併 commit 並 push，否則新電腦無法從 GitHub 還原完整設定。

## 相關檔案

- `AGENTS.md`：本 Instructions Repository 的維護規範。
- `.codex/`：fan-out 給 Codex 的繁體中文與英文 Instructions。
- `.github/`：fan-out 給 GitHub Copilot 的繁體中文與英文 Instructions。
- `.agents/skills/`：歷史來源目錄；production Catalog 的 10 個 Skills 已由四個 external repositories 提供。完成所有 cutover gate 前保留這些 legacy copies 作 rollback，不是 production acquisition source。
  - `plan-production-change`：依 Scope、風險與不確定性建立實作計畫。
  - `verify-data-access-performance`：診斷並驗證 query 效能、query count 與 N+1。
  - `write-copilot-implementation-prompt`：建立自包含的 GitHub Copilot 實作提示詞，並以完整可選名稱建議最低充分模型。
  - `work-with-jira`：依 scoped API 與授權規則安全查詢或修改 Jira Cloud。
  - `investigate-datadog-logs`：優先使用 Datadog connector 查詢或聚合 LOG、分析 APM trace，並處理調查用 Logs Explorer、trace 或 widget URL；純 incident record、dashboard 或 notebook 管理由對應的 Datadog guide 處理。
- `catalog/`：Skills Catalog、lock、managed manifest v2 與個人 sync configuration v3 的 schemas、去識別化 examples 及跨 Repository 契約。
- `scripts/bootstrap-ai-instructions-installed.ps1`：安裝到個人 hook 的穩定入口，從同目錄 runtime bundle 啟動 multi-source bootstrap。
- `scripts/bootstrap-ai-instructions-multisource.ps1`：驗證 schema v3、Catalog／lock、來源 archives 與 Skill inventories，組合 Instructions 與選中的 external Skills，並產生 manifest v2 provenance handoff。
- `scripts/bootstrap-ai-instructions.ps1`：保留直接呼叫的 manifest v1 regression compatibility；production wrapper 提供 provenance 時則安全 mutation、v1→v2 migration、allowlist commit 或 byte-safe `PersonalAgent` stash。
- `scripts/install-ai-instructions-bootstrap.ps1`：在本機 Codex home 安裝 launcher 與完整 runtime bundle、遷移 schema v3、合併 `AGENTS.md`，並移除舊版 bootstrap `SessionStart` hook。
- `scripts/safe-zip.psm1`：PowerShell 5.1／7 共用的 single-root、case-collision、traversal、symlink／reparse 安全 extraction，並將 GitHub 長根目錄縮成固定 `repository`。
- `scripts/skills-catalog-contract.psm1`：以 Windows PowerShell 5.1 相容方式驗證 Catalog、lock、manifest 與個人設定的 schema version、cross-reference、pin、hash 與安全路徑。
- `tests/bootstrap-ai-instructions.Tests.ps1`：bootstrap script 的 Pester tests。
- `tests/install-ai-instructions-bootstrap.Tests.ps1`：本機安裝腳本的 Pester tests。
- `tests/skills-catalog-contract.Tests.ps1`：Catalog P0 契約的 Pester tests 與 invalid fixtures 驗證。
