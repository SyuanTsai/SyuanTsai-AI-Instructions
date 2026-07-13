# SyuanTsai AI Instructions

這個 Repository 是個人 Codex 與 GitHub Copilot Instructions 的唯一來源。換電腦後，只要讓 Codex 完整讀取本檔案並依照「新電腦安裝」執行，即可重建目前的自動 bootstrap 設定。

## 給新電腦 Codex 的指示

在這個 Repository 根目錄開啟 Codex，貼上以下內容：

```text
請完整讀取 README.md，依「新電腦安裝」重建個人 Codex bootstrap 設定。
保留既有的 ~/.codex/AGENTS.md 與 hooks.json 內容，只合併本文件指定的區塊與 SessionStart hook。
安裝後依「驗證」執行檢查；不得 push，也不得覆寫任何測試 Repository 已存在的 Instructions。
```

## 目前的自動化流程

每次 Codex task 啟動時，個人 `SessionStart` hook 會執行已安裝的 `bootstrap-ai-instructions.ps1`：

1. 取得目前所在的 Git Repository 根目錄；不在 Git Repository 時直接略過。
2. 檢查 Codex 與 GitHub Copilot 兩組 Instructions 是否缺少 Base file。
3. 只有發現缺少的 Instructions 時，才從 GitHub Repository `SyuanTsai/SyuanTsai-AI-Instructions` 的 `main` branch 下載 ZIP archive。
4. Codex 缺少時，從英文來源建立：
   - `.codex/AGENTS.en.md` → 目標 Repository 的 `AGENTS.md`
   - `.codex/AI-Rules/*.en.md` → 目標 Repository 的 `.codex/AI-Rules/*.en.md`
5. GitHub Copilot 缺少時，從英文來源建立：
   - `.github/copilot-instructions.en.md` → 目標 Repository 的 `.github/copilot-instructions.md`
   - `.github/AI-Rules/*.en.md` → 目標 Repository 的 `.github/AI-Rules/*.en.md`
6. 不覆寫任何已存在的 Base file 或 rule module。
7. 只 stage 與 commit 本次建立的檔案，commit message 固定為 `chore: add shared AI instructions`。
8. 保留原本 staged、unstaged 與 unrelated changes，不自動 push。

## 新電腦安裝

### 1. 前置需求

- Windows PowerShell 5.1 或 PowerShell 7。
- Git 可由終端機執行，且已設定 `user.name` 與 `user.email`。
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

### 3. 安裝 bootstrap script

Codex home 優先使用 `CODEX_HOME`；未設定時使用目前使用者的 `~/.codex`。把 Repository 中已測試的 script 複製到個人 hook 目錄：

```powershell
$repositoryRoot = (git rev-parse --show-toplevel).Trim()
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$hookDirectory = Join-Path $codexHome 'hooks'
$hookScript = Join-Path $hookDirectory 'bootstrap-ai-instructions.ps1'

New-Item -ItemType Directory -Force -Path $hookDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\bootstrap-ai-instructions.ps1') -Destination $hookScript -Force
```

安裝後的 script 不依賴來源 Repository 的本機路徑；執行時會直接從 GitHub 下載最新英文版 Instructions。

### 4. 更新個人 AGENTS.md

編輯 `$codexHome/AGENTS.md`。保留既有個人規則，確認下列區塊存在；若已存在則更新，不要重複附加：

```markdown
## Repository Instructions Bootstrap

- 開始處理 Git Repository 時，由 `SessionStart` hook 從 `SyuanTsai/SyuanTsai-AI-Instructions` 的 GitHub `main` branch 下載並建立缺少的英文 Codex 與 GitHub Copilot Instructions。
- 若 hook 未執行且根目錄缺少 `AGENTS.md` 或 `.github/copilot-instructions.md`，先執行：`$CODEX_HOME/hooks/bootstrap-ai-instructions.ps1`；未設定 `CODEX_HOME` 時使用 `~/.codex/hooks/bootstrap-ai-instructions.ps1`。
- 只建立缺少的 Instructions，不得覆寫既有檔案。
- 只 commit bootstrap 新增的檔案，commit message 使用 `chore: add shared AI instructions`，不得自動 push。
- GitHub 無法存取、目前位置不是 Git Repository 或無法安全隔離 commit 時，停止 bootstrap 並回報原因。
```

### 5. 合併 SessionStart hook

編輯 `$codexHome/hooks.json`，保留所有既有 hooks，並在 `hooks.SessionStart` 中加入或更新以下 entry。`command` 與 `commandWindows` 內必須使用新電腦 `$hookScript` 的完整絕對路徑，不能複製舊電腦的 username 或磁碟路徑。

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

### 6. 重新啟動並信任 hook

關閉並重新開啟 Codex。因為 hook definition 是本機可執行命令，首次安裝或內容變更後，使用 Codex 的 `/hooks` 檢查並信任這個 hook。

## 驗證

### 設定驗證

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$hookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
$hooksFile = Join-Path $codexHome 'hooks.json'

Test-Path -LiteralPath $hookScript
Get-Content -Raw -LiteralPath $hooksFile | ConvertFrom-Json | Out-Null
Select-String -LiteralPath $hooksFile -SimpleMatch 'bootstrap-ai-instructions.ps1'
Select-String -LiteralPath (Join-Path $codexHome 'AGENTS.md') -SimpleMatch 'Repository Instructions Bootstrap'
```

四項都必須成功，且 `hooks.json` 不得包含舊電腦的絕對路徑。

### Script tests

在本 Repository 根目錄執行：

```powershell
Import-Module Pester
Invoke-Pester .\tests\bootstrap-ai-instructions.Tests.ps1
```

預期結果為 `3 passed, 0 failed`。測試涵蓋建立兩組英文 Instructions、保留既有 Instructions，以及保留 unrelated staged/unstaged changes。

### Smoke test

在一個可丟棄且已設定 Git identity 的空白 Git Repository 中執行已安裝的 hook script。確認：

- 建立 `AGENTS.md`、`.codex/AI-Rules/*.en.md`、`.github/copilot-instructions.md` 與 `.github/AI-Rules/*.en.md`。
- 最新 commit message 是 `chore: add shared AI instructions`。
- commit 只包含 bootstrap 新增的檔案。
- 再執行一次時顯示 Instructions 已存在，不新增 commit。
- 測試完成後只刪除可丟棄的測試 Repository，不得在正式 Repository 做清除操作。

## 維護與更新

- 共通 Instructions 依根目錄 `AGENTS.md` 維護：先改繁體中文來源，再同步 Codex、GitHub Copilot 與英文版本。
- 修改 `scripts/bootstrap-ai-instructions.ps1` 時，先更新 `tests/bootstrap-ai-instructions.Tests.ps1` 並執行 Pester。
- 本 Repository 更新並 push 至 GitHub 後，各專案只有在缺少 Instructions 時才會取得新版；bootstrap 不會覆寫已存在的專案 Instructions。
- bootstrap script 更新後，個人 hook 目錄中的已安裝副本不會自動更新。重新執行「安裝 bootstrap script」，然後重啟 Codex 並重新檢查 hook trust。
- `scripts/`、`tests/` 與本 `README.md` 必須一併 commit 並 push，否則新電腦無法從 GitHub 還原完整設定。

## 相關檔案

- `AGENTS.md`：本 Instructions Repository 的維護規範。
- `.codex/`：fan-out 給 Codex 的繁體中文與英文 Instructions。
- `.github/`：fan-out 給 GitHub Copilot 的繁體中文與英文 Instructions。
- `scripts/bootstrap-ai-instructions.ps1`：從 GitHub 建立缺少 Instructions 並 commit 的 bootstrap script。
- `tests/bootstrap-ai-instructions.Tests.ps1`：bootstrap script 的 Pester tests。
