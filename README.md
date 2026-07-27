# SyuanTsai AI Instructions

這個 Repository 是個人 Codex 與 GitHub Copilot Instructions 的唯一來源。換電腦後，只要讓 Codex 完整讀取本檔案並依照「新電腦安裝」執行，即可重建目前的自動 bootstrap 設定。

## 給新電腦 Codex 的指示

在這個 Repository 根目錄開啟 Codex，貼上以下內容：

```text
請完整讀取 README.md，依「新電腦安裝」重建個人 Codex bootstrap 設定。
保留既有的 ~/.codex/AGENTS.md 與 hooks.json 內容，只合併本文件指定的區塊與 SessionStart hook。將 ai-instructions-sync.json 遷移成 README 指定的 schema，保留仍允許自動 commit 的 Repository URL、明確排除同步的 Repository URL 與 Repository-relative 目錄，移除不再支援的舊版本機路徑設定。
安裝後依「驗證」執行檢查；不得 push，也不得覆寫目標 Repository 已自行修改或不受 manifest 管理的 Instructions。
```

## 目前的自動化流程

每次 Codex task 啟動時，個人 `SessionStart` hook 會執行已安裝的 `bootstrap-ai-instructions.ps1`：

1. 取得目前所在的 Git Repository 根目錄；不在 Git Repository 時直接略過。
2. 若目前就是本 Instructions 來源 Repository，直接略過，避免把維護用的根目錄 `AGENTS.md` 當成 fan-out 目標。
3. 從 GitHub Repository `SyuanTsai/SyuanTsai-AI-Instructions` 的 `main` branch 下載 ZIP archive，取得最新英文 Instructions。
4. Codex 的來源與目標 mapping：
   - `.codex/AGENTS.en.md` → 目標 Repository 的 `AGENTS.md`
   - `.codex/AI-Rules/*.en.md` → 目標 Repository 的 `.codex/AI-Rules/*.en.md`
5. GitHub Copilot 的來源與目標 mapping：
   - `.github/copilot-instructions.en.md` → 目標 Repository 的 `.github/copilot-instructions.md`
   - `.github/AI-Rules/*.en.md` → 目標 Repository 的 `.github/AI-Rules/*.en.md`
6. 使用目標 Repository 的 `.codex/ai-instructions.manifest.json` 記錄受管理檔案及最後套用的 SHA-256。
7. 來源 Agent 更新後，只自動更新內容仍等於 manifest hash 且沒有 staged changes 的受管理檔案；尚未 commit 的前一次同步結果仍可繼續更新。
8. 來源新增 rule module 時自動建立；來源移除 rule module 時，只刪除未被專案修改的受管理檔案。
9. 已由專案自行修改或原本就不受管理的 Instructions 不覆寫；若 Base file 不受管理，整個 family 都不自動補齊，並在輸出中列出衝突路徑。
10. 舊版 bootstrap 建立的檔案若仍與其 `chore: add shared AI instructions` 建立 commit 完全一致，會安全接管並建立 manifest。
11. 讀取目前 Repository 的 `origin` URL 與 task 啟動目錄；若實際 Repository 位置列在個人 `~/.codex/ai-instructions-sync.json` 的 `excludedRepositoryUrls`，或啟動目錄位於 `excludedRepositoryPaths` 的 repo-relative 目錄底下，直接略過，不下載、不套用、不建立 stash 或 commit。
12. 只有實際 Repository 位置列在 `autoCommitRepositoryUrls` 時才自動 commit。首次建立使用 `chore: add shared AI instructions`，後續更新使用 `chore: sync shared AI instructions`。
13. 非 allowlist 且未被排除的 Repository 或目錄仍同步 Instructions 與 manifest，但不 stage、不 commit；同步結果會建立為名稱 `PersonalAgent` 的 Git stash，隨即用 `git stash apply` 抓回 working tree，stash 本身保留。
14. 來源沒有更新時保留現有 `PersonalAgent` stash；需要更新時，先成功建立並套用新版 stash，再刪除舊的同名 stash。其他 stash 不受影響。
15. 所有 Repository 都保留 unrelated staged/unstaged changes，而且永遠不自動 push。

## 新電腦安裝

### 1. 前置需求

- Windows PowerShell 5.1 或 PowerShell 7。
- Git 可由終端機執行；只有 allowlist Repository 的自動 commit 需要先設定 `user.name` 與 `user.email`。
- Codex Desktop 或其他支援 Codex hooks 的 Codex surface。
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

- 複製 `scripts/bootstrap-ai-instructions.ps1` 到個人 hook 目錄。
- 建立或遷移 `$codexHome/ai-instructions-sync.json` 為 schema version 2，只保留允許自動 commit 的 Repository URL、明確排除同步的 Repository URL 與 Repository-relative 目錄，移除不再支援的舊版本機路徑設定。
- 在 `$codexHome/AGENTS.md` 新增或更新 `Repository Instructions Bootstrap` 區塊，保留其他個人規則。
- 在 `$codexHome/hooks.json` 的 `hooks.SessionStart` 新增或更新唯一一個 bootstrap entry，保留其他 hooks。

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

安裝後的 bootstrap script 不依賴來源 Repository 的本機路徑；執行時會直接從 GitHub 下載最新英文版 Instructions，並依 manifest 安全同步新增、更新與移除。

### 4. 設定允許自動 commit 與排除同步的 Repository 或目錄

安裝腳本會建立或保留 `$codexHome/ai-instructions-sync.json`。需要手動調整 allowlist、Repository 排除清單或目錄排除清單時，編輯成以下格式：

```json
{
  "schemaVersion": 2,
  "autoCommitRepositoryUrls": [
    "git@example.com:your-account/owned-project-a.git",
    "https://example.com/your-account/owned-project-b.git"
  ],
  "excludedRepositoryUrls": [
    "git@example.com:your-account/planning-only-project.git"
  ],
  "excludedRepositoryPaths": [
    "docs/architecture-planning"
  ]
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
- 設定檔不存在、清單為空或目前 Repository 不在清單時，仍會同步檔案，但不會 stage、commit 或 push；同步內容會保存到 `PersonalAgent` stash 並立即 apply 回 working tree。
- 只有明確列入清單的 Repository 才會自動 commit；自動 commit 仍永遠不會 push。
- 不要把主要負責人不是自己的 Repository 加入清單。

最安全的預設設定是空清單：

```json
{
  "schemaVersion": 2,
  "autoCommitRepositoryUrls": [],
  "excludedRepositoryUrls": [],
  "excludedRepositoryPaths": []
}
```

### 5. 確認個人 AGENTS.md

安裝腳本會保留既有個人規則，並新增或更新下列區塊；若手動維護，確認同一區塊不要重複附加：

```markdown
## Repository Instructions Bootstrap

- 開始處理 Git Repository 時，由 `SessionStart` hook 從 `SyuanTsai/SyuanTsai-AI-Instructions` 的 GitHub `main` branch 下載並同步英文 Codex 與 GitHub Copilot Instructions。
- 若 hook 未執行，先執行：`$CODEX_HOME/hooks/bootstrap-ai-instructions.ps1`；未設定 `CODEX_HOME` 時使用 `~/.codex/hooks/bootstrap-ai-instructions.ps1`。
- 以 `.codex/ai-instructions.manifest.json` 管理共享檔案；只更新未被專案修改的受管理檔案，不得覆寫 customized 或 unmanaged Instructions。
- Repository 的 `origin` 實際位置列在 `~/.codex/ai-instructions-sync.json` 的 `excludedRepositoryUrls`，或 task 啟動目錄位於 `excludedRepositoryPaths` 的 repo-relative 目錄底下時，直接略過同步；不得使用本機資料夾位置判斷。
- 只有 Repository 的 `origin` 實際位置列在 `autoCommitRepositoryUrls` 時才自動 commit。非 allowlist 且未被排除的 Repository 或目錄仍同步檔案，但不得 stage 或 commit，並以 `PersonalAgent` stash 保存後立即 apply 回 working tree。
- 更新非 allowlist Repository 時，只能在新版 `PersonalAgent` stash 成功建立並套用後刪除舊的同名 stash；不得刪除其他 stash。
- allowlist Repository 只 commit bootstrap 新增、更新、移除的受管理檔案與 manifest；首次使用 `chore: add shared AI instructions`，後續使用 `chore: sync shared AI instructions`，永遠不得自動 push。
- GitHub 無法存取、目前位置不是 Git Repository 或無法安全隔離 commit 時，停止 bootstrap 並回報原因。
```

### 6. 確認 SessionStart hook

安裝腳本會保留所有既有 hooks，並在 `hooks.SessionStart` 中加入或更新以下 entry。`command` 與 `commandWindows` 內必須使用新電腦 `$hookScript` 的完整絕對路徑，不能複製舊電腦的 username 或磁碟路徑。

```json
{
  "matcher": "startup",
  "hooks": [
    {
      "type": "command",
      "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"<ABSOLUTE_HOOK_SCRIPT_PATH>\"",
      "commandWindows": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"<ABSOLUTE_HOOK_SCRIPT_PATH>\"",
      "timeout": 60,
      "statusMessage": "Downloading shared AI instructions from GitHub"
    }
  ]
}
```

合併規則：

- `hooks.json` 不存在時才建立完整文件。
- 已存在時，只新增或更新這一個 `SessionStart` entry，不得刪除其他 event、matcher 或 command。
- 寫入前後都必須用 `ConvertFrom-Json` 驗證 JSON。
- 同一個 bootstrap command 只能保留一份。

### 7. 重新啟動並信任 hook

關閉並重新開啟 Codex。因為 hook definition 是本機可執行命令，首次安裝或內容變更後，使用 Codex 的 `/hooks` 檢查並信任這個 hook。

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

## 驗證

### 設定驗證

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$hookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
$hooksFile = Join-Path $codexHome 'hooks.json'
$syncConfigurationFile = Join-Path $codexHome 'ai-instructions-sync.json'

Test-Path -LiteralPath $hookScript
Get-Content -Raw -LiteralPath $hooksFile | ConvertFrom-Json | Out-Null
Get-Content -Raw -LiteralPath $syncConfigurationFile | ConvertFrom-Json | Out-Null
Select-String -LiteralPath $hooksFile -SimpleMatch 'bootstrap-ai-instructions.ps1'
Select-String -LiteralPath (Join-Path $codexHome 'AGENTS.md') -SimpleMatch 'Repository Instructions Bootstrap'
```

五項都必須成功，且 `hooks.json` 不得包含舊電腦的絕對路徑。逐一確認 `autoCommitRepositoryUrls` 只包含允許自動 commit 的 Repository、`excludedRepositoryUrls` 只包含應完全略過同步的 Repository、`excludedRepositoryPaths` 只包含應略過同步的 repo-relative 目錄，並用 `git remote get-url origin` 核對實際 URL。

### Script tests

在本 Repository 根目錄執行：

```powershell
Import-Module Pester
Invoke-Pester .\tests
```

預期結果為 `18 passed, 0 failed`。測試涵蓋首次建立、自動更新、無變更不重複 commit、保留 customized Instructions、舊版 bootstrap 接管、安全移除 rule module、保留 unrelated staged/unstaged changes、以實際 origin URL 判斷 allowlist 與排除清單、以 task 啟動目錄判斷 repo-relative 排除路徑、SSH/HTTPS URL 等價比對、資料夾同名不誤判、非 allowlist 不 commit、未 commit 同步結果的連續更新、`PersonalAgent` stash 的建立、重新套用、保留與更新，以及本機安裝腳本的 idempotent 合併與設定遷移。

### Smoke test

分別以 allowlist 與非 allowlist 設定，在可丟棄的空白 Git Repository 中執行已安裝的 hook script。確認：

- 建立 `AGENTS.md`、`.codex/AI-Rules/*.en.md`、`.github/copilot-instructions.md`、`.github/AI-Rules/*.en.md` 與 `.codex/ai-instructions.manifest.json`。
- allowlist Repository 的最新 commit message 是 `chore: add shared AI instructions`，而且只包含 bootstrap 新增的檔案。
- 非 allowlist Repository 取得相同檔案，但 HEAD、Git index 與遠端都不變；檔案留在 working tree，且 `git stash list` 只出現一份最新的 `PersonalAgent` stash。
- excluded Repository 不建立 `AGENTS.md`、manifest、commit 或 `PersonalAgent` stash，並輸出 repository is excluded。
- 從 excluded repo-relative 目錄啟動時，不建立 `AGENTS.md`、manifest、commit 或 `PersonalAgent` stash，並輸出 directory is excluded；從同一 Repository 的其他目錄啟動時仍照常同步。
- 新建 `PersonalAgent` stash 後檔案會自動 apply 回 working tree，stash reference 仍存在；無來源更新時不重建 stash。
- 未變更來源時再執行一次，顯示 Instructions 已是最新版本且不新增 commit。
- 使用更新過的來源 archive 做 Regression Test 時，未客製化的受管理檔案會更新，commit message 是 `chore: sync shared AI instructions`。
- 修改一個目標 Agent 後再同步，該檔案會保留且輸出列出 customized path，其他未修改的受管理檔案仍正常更新。
- 測試完成後只刪除可丟棄的測試 Repository，不得在正式 Repository 做清除操作。

## 維護與更新

- 共通 Instructions 依根目錄 `AGENTS.md` 維護：先改繁體中文來源，再同步 Codex、GitHub Copilot 與英文版本。
- 修改 `scripts/bootstrap-ai-instructions.ps1` 時，先更新 `tests/bootstrap-ai-instructions.Tests.ps1` 並執行 Pester。
- 本 Repository 的英文 Instructions 更新並 push 至 GitHub 後，各專案會在下一個 Codex task 啟動時同步未被客製化的受管理檔案。
- 修改 `~/.codex/ai-instructions-sync.json` 的 `autoCommitRepositoryUrls` 即可依 origin URL 控制哪些 Repository 允許自動 commit；修改 `excludedRepositoryUrls` 可讓規劃用或不應套用共享 Instructions 的 Repository 完全略過同步；修改 `excludedRepositoryPaths` 可排除同一 Repository 內的規劃目錄。未列入且未排除的 Repository 更新 working tree 並保留 `PersonalAgent` stash。
- 已存在但不受 manifest 管理的專案 Instructions 不會被自動接管；唯一例外是可由 Git history 證明仍未修改的舊版 bootstrap 產物。
- bootstrap script 更新後，個人 hook 目錄中的已安裝副本不會自動更新。重新執行「安裝 bootstrap script」並重啟 Codex；若 `hooks.json` definition 沒有改變，通常不需要重新信任，但仍可用 `/hooks` 檢查狀態。
- `scripts/`、`tests/` 與本 `README.md` 必須一併 commit 並 push，否則新電腦無法從 GitHub 還原完整設定。

## 相關檔案

- `AGENTS.md`：本 Instructions Repository 的維護規範。
- `.codex/`：fan-out 給 Codex 的繁體中文與英文 Instructions。
- `.github/`：fan-out 給 GitHub Copilot 的繁體中文與英文 Instructions。
- `scripts/bootstrap-ai-instructions.ps1`：從 GitHub 安全同步受管理 Instructions，依個人排除清單跳過指定 Repository 或目錄，依 allowlist 決定 commit，或以 `PersonalAgent` stash 保存非 allowlist 內容的 bootstrap script。
- `scripts/install-ai-instructions-bootstrap.ps1`：在本機 Codex home 安裝 hook script、合併 `AGENTS.md`、`hooks.json` 與 `ai-instructions-sync.json`。
- `tests/bootstrap-ai-instructions.Tests.ps1`：bootstrap script 的 Pester tests。
- `tests/install-ai-instructions-bootstrap.Tests.ps1`：本機安裝腳本的 Pester tests。
