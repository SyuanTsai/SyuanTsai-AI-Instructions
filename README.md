# SyuanTsai AI Instructions

這個 Repository 是個人 Codex／GitHub Copilot Instructions、Skills Catalog 與安裝 runtime 的 canonical source；production Agent Skills 只由 Catalog 指向的外部 repositories 提供，本 Repository 不保存共用 Skill source。換電腦後，只要讓 Codex 完整讀取本檔案並依照「新電腦安裝」執行，即可重建目前的按需 bootstrap 設定。

## Agent Skills Catalog P0 契約

為了讓 Agent Skills 由多個外部 repositories 提供，同時保留選擇性安裝、版本鎖定與安全同步，本 Repository 維護下列跨 Repository 契約：

- Skills Catalog schema 1：stable Skill ID、group、profiles、compatibility、hard／conditional／recommended dependencies 與 lifecycle。
- Catalog lock schema 1：將 branch／tag／commit ref 鎖定到完整 commit SHA、archive hash 與每個 Skill 的 deterministic content hash。
- Managed manifest schema 2：每個目標檔案各自記錄 source Repository、ref、commit、version、Skill identity、source／target path 與 hash。
- 個人 sync configuration schema 3：在既有 allowlist／exclusions 之外，記錄已安裝 AI-Instructions runtime/Catalog bundle 的 Repository + immutable commit，以及 profiles 與 individual include／exclude。
- Runtime bundle metadata schema 1：安裝到 Codex Home 的 `runtime-bundle.json` 必須與 schema v3 的 bundle repository/ref 完全一致，否則 installed launcher fail closed。

完整規則、升級行為、去識別化 examples 與 executable schemas 請見 [`catalog/README.md`](catalog/README.md)。契約 validator 可用下列方式執行：

```powershell
Import-Module .\scripts\skills-catalog-contract.psm1 -Force
Test-SkillsCatalogContract `
  -CatalogPath .\catalog\examples\skills-catalog.example.json `
  -LockPath .\catalog\examples\skills-catalog-lock.example.json `
  -ManifestPath .\catalog\examples\managed-manifest-v2.example.json `
  -ConfigurationPath .\catalog\examples\ai-instructions-sync-v3.example.json
```

production bootstrap 已使用這組契約：tracked Catalog lock 固定外部來源，schema v3 選出 Skills，manifest v2 記錄每個檔案的來源 provenance。Runtime 不使用 Git submodule，也不依 source ID 寫 domain-specific 分支。`Skill-Darktide-Translate`（SYP-88／SYP-92）是獨立產品，不在此 Catalog、Lock 或 bootstrap fan-out 範圍內。

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
3. installed launcher 先比對 `runtime-bundle.json` 與 schema v3 config 的 bundle Repository／commit，再驗證 bundled Catalog 與 tracked lock；依該 immutable commit 下載 Instructions，並只從 lock 的 `resolvedCommit` 取得被選取的外部 Skill 來源。
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
- 能連線至 `https://github.com/SyuanTsai/SyuanTsai-AI-Instructions` 與 Catalog 選中的外部 Skill repositories。

### 2. 取得來源 Repository

Repository 可以放在任意本機路徑，不得依賴舊電腦的 `C:\GitFile\...` 路徑：

```powershell
git clone https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git
Set-Location .\SyuanTsai-AI-Instructions
```

如果已經 clone，先確認目前 branch、來源與 working tree：

```powershell
git switch main
git pull --ff-only
git remote get-url origin
git status --short
```

Installer 只允許即將安裝的 launcher、runtime modules、Catalog 與 Lock tracked bytes 完全等於目前 `HEAD`。這些檔案有 staged／unstaged 修改時會在 Codex Home mutation 前 fail closed，避免 `catalog.ref = HEAD` 卻安裝 local edits。

### 3. 執行本機安裝腳本

Codex home 優先使用 `CODEX_HOME`；未設定時使用目前使用者的 `~/.codex`。安裝腳本會：

- 在 temporary staging directory 建立 launcher、完整 runtime、Catalog、Lock、`runtime-bundle.json` 與新 schema-v3 config。
- 在 staging 先驗證 PowerShell parse、Catalog/Lock contract 與 bundle/config identity。
- 正常安裝時先啟用會 fail-closed 的 launcher，再 swap runtime，最後才更新 config；後續步驟失敗時 rollback 舊 launcher、runtime、config、`AGENTS.md` 與 `hooks.json`。
- 建立或遷移 `$codexHome/ai-instructions-sync.json` 為 schema version 3；v1／v2 保留合法 routing arrays，既有 v3 保留 profiles 與 individual include／exclude，但 bundle Repository／ref 必須與本次 installer checkout 一起前進。
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

安裝後的 bootstrap script 不依賴來源 Repository 的本機路徑；執行時使用 bundle/config 的 immutable commit 下載 Instructions，並依 lock 的 immutable source commits 取得 external Skills，先驗證 archives 與 Skill inventories，再依 manifest v2 安全同步。

### 4. 設定允許自動 commit、排除同步與 Skill selection

安裝腳本會建立或保留 `$codexHome/ai-instructions-sync.json`。一般只應手動調整 routing arrays 與 Skill selection；`catalog.repository` / `catalog.ref` 是 installer 管理的 runtime bundle identity，不應手動指向其他 Catalog Repository。

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
    "repository": "https://github.com/example/ai-instructions.git",
    "ref": "89abcdef0123456789abcdef0123456789abcdef",
    "profiles": ["core"],
    "includeSkills": [],
    "excludeSkills": []
  }
}
```

Repository 內文件與測試只能使用虛構範例，不得記錄私人 Repository 的組織、名稱或 URL。實際安裝時 `catalog.repository` 與 `catalog.ref` 由 installer 產生。

規則：

- 判斷 allowlist／exclude 的依據是 `git remote get-url origin` 回傳的實際 Repository URL，不使用本機資料夾名稱或絕對路徑。
- SSH 與 HTTPS URL 會正規化為相同的 host 與 Repository path；比對不分大小寫，尾端 `.git` 與斜線不影響結果。
- 列在 `excludedRepositoryUrls` 的 Repository 直接略過同步。
- 列在 `excludedRepositoryPaths` 的目錄會依 task 啟動目錄判斷；從該 repo-relative 目錄或其子目錄啟動時略過同步。
- `excludedRepositoryPaths` 只接受 repo-relative path，例如 `docs/architecture-planning`；不得使用本機絕對路徑、`.` 或 `..`。
- 同一個 Repository 同時列在 `autoCommitRepositoryUrls` 與 `excludedRepositoryUrls`，或啟動目錄命中 `excludedRepositoryPaths` 時，以排除為優先。
- `catalog.repository/ref` 必須匹配已安裝 `runtime-bundle.json`；不匹配時 launcher fail closed，重新執行 installer 修復。
- `profiles`、`includeSkills` 與 `excludeSkills` 決定實際 fan-out 的 Skill set；removed ID／alias 有 replacement 時會遷移到 replacement stable ID，明確 exclude 最終優先。
- 設定檔不存在、清單為空或目前 Repository 不在 allowlist 時，仍會同步檔案，但不會 stage、commit 或 push；同步內容會保存到 `PersonalAgent` stash 並立即 apply 回 working tree。
- 只有明確列入 allowlist 的 Repository 才會自動 commit；永遠不會自動 push。

最安全的 routing / selection 預設是空 routing 清單與 `core` profile；bundle identity 仍由 installer 寫入：

```json
{
  "schemaVersion": 3,
  "autoCommitRepositoryUrls": [],
  "excludedRepositoryUrls": [],
  "excludedRepositoryPaths": [],
  "catalog": {
    "repository": "https://github.com/example/ai-instructions.git",
    "ref": "89abcdef0123456789abcdef0123456789abcdef",
    "profiles": ["core"],
    "includeSkills": [],
    "excludeSkills": []
  }
}
```

### 5. 確認個人 AGENTS.md

安裝腳本會保留既有個人規則，並新增或更新 `Repository Instructions Bootstrap` 區塊。若手動維護，確認同一區塊不要重複附加。核心規則是：只在準備建立或更新 production code 的實作計畫時執行 bootstrap；一般問答不執行；只更新 manifest 管理且未被專案修改的檔案；exclude 優先；非 allowlist 只更新 working tree 並保留 `PersonalAgent` stash；allowlist 只 commit 精確受管檔且永不 push。

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

Installer 會在 active runtime mutation 前建立 transaction backup；正常例外會自動 restore 舊 launcher、runtime、config、`AGENTS.md` 與 `hooks.json`。若 rollback 本身失敗，backup 會保留並在錯誤訊息中回報路徑。程序被強制中止而留下 runtime/config mismatch 時，新 launcher 會 fail closed，重新執行 installer 即可完成修復。Target manifest migration / rollback 詳情見 [`docs/syp-86-production-cutover.md`](docs/syp-86-production-cutover.md)。

## 驗證

### 設定驗證

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$hookScript = Join-Path $codexHome 'hooks\bootstrap-ai-instructions.ps1'
$runtimeBundle = Join-Path $codexHome 'hooks\ai-instructions-runtime\runtime-bundle.json'
$hooksFile = Join-Path $codexHome 'hooks.json'
$syncConfigurationFile = Join-Path $codexHome 'ai-instructions-sync.json'

Test-Path -LiteralPath $hookScript
Get-Content -Raw -LiteralPath $runtimeBundle | ConvertFrom-Json | Out-Null
Get-Content -Raw -LiteralPath $syncConfigurationFile | ConvertFrom-Json | Out-Null
Select-String -LiteralPath (Join-Path $codexHome 'AGENTS.md') -SimpleMatch 'Repository Instructions Bootstrap'
if (Test-Path -LiteralPath $hooksFile) {
    Get-Content -Raw -LiteralPath $hooksFile | ConvertFrom-Json | Out-Null
    -not [bool](Select-String -LiteralPath $hooksFile -SimpleMatch 'bootstrap-ai-instructions.ps1' -Quiet)
}
```

### Regression tests

兩個正式 runtime 都必須通過完整 Pester suite；CI workflow 為 `PowerShell Regression`。測試涵蓋 schema v3 installer transaction/rollback、dirty-source rejection、runtime bundle identity、manifest v1→v2 遷移、per-file provenance、selection／alias／dependency resolution、immutable archive 與 Skill inventory hashes、安全 ZIP extraction、PowerShell 5.1 行為，以及 non-allowlist raw-byte safety。

### Production smoke

CI workflow `SYP86 Production Smoke` 會在 Windows PowerShell 5.1 與 PowerShell 7 執行 `scripts/test-production-cutover.ps1`。它不是 fixture-only test：會用目前 installer 安裝 temporary Codex Home，透過 installed launcher 下載目前 immutable Instructions commit 與 checked-in lock 的真實 external Skill archives，對 disposable non-allowlist target 建立 manifest v2；接著設 `core.autocrlf=true` 再同步一次，要求 managed bytes、Git status、HEAD 與 retained `PersonalAgent` stash 全部不變。

可手動執行：

```powershell
.\scripts\test-production-cutover.ps1
```

### Production lock

`SYP86 Production Lock` 在 PS5.1 / PS7 執行 `scripts/update-skills-catalog-lock.ps1 -Check`，確認真實 source pins、archive hashes 與 Skill content inventory 沒有 drift。

## 維護與更新

- 共通 Instructions 依根目錄 `AGENTS.md` 維護；production Skills 的唯一 canonical source 是 Catalog 指向的 external repositories。本 Repository 不得重新加入 `.agents/skills/<skill-id>/**` source。
- 修改 installer/runtime/Catalog/Lock 前保持 tracked source bytes clean；需要測試 local edits 時使用 disposable clone，不要用 local edits 建立正式 installation pin。
- 修改 `scripts/bootstrap-ai-instructions.ps1`、multi-source wrapper、selection/retrieval/acquisition/composition 或 installer 時，更新相應 Pester tests，並通過三個 CI workflows：`PowerShell Regression`、`SYP86 Production Lock`、`SYP86 Production Smoke`。
- Catalog source pin 更新時重新產生 lock；bootstrap 永遠只依已驗證 immutable commit/hash 契約取得內容。
- `~/.codex/ai-instructions-sync.json` 只手動維護 routing arrays 與 Skill selection；bundle repository/ref 由 installer 管理。
- 已存在但不受 manifest 管理的專案 Instructions 或 Agent Skills 不會被自動接管；唯一例外是可由 Git history 證明仍未修改的舊版 bootstrap 產物。
- bootstrap runtime 更新後，重新執行 installer 並重啟 Codex；個人 hook 不會自行追蹤 mutable branch。
- `scripts/`、`tests/`、workflows 與本 `README.md` 必須一併 commit 並 push，否則新電腦無法從 GitHub 還原完整設定。

## 相關檔案

- `AGENTS.md`：本 Instructions Repository 的維護規範。
- `.codex/`：fan-out 給 Codex 的繁體中文與英文 Instructions。
- `.github/`：fan-out 給 GitHub Copilot 的繁體中文與英文 Instructions。
- `catalog/`：Skills Catalog、source pins、lock、manifest v2 與 sync configuration v3 的 schemas、examples 及跨 Repository 契約。
- `scripts/bootstrap-ai-instructions-installed.ps1`：安裝到個人 hook 的穩定入口；驗證 `runtime-bundle.json` 與 config pin 後啟動 multi-source bootstrap。
- `scripts/bootstrap-ai-instructions-multisource.ps1`：驗證 schema v3、Catalog／lock、來源 archives 與 Skill inventories，組合 Instructions 與選中的 external Skills，並產生 manifest v2 provenance handoff。
- `scripts/bootstrap-ai-instructions.ps1`：multi-source wrapper 的內部 mutation engine；只接受已組合 archive 與 immutable provenance，並處理 manifest v1 safe migration、customized/unmanaged protection、allowlist commit 或 byte-safe `PersonalAgent` stash。
- `scripts/install-ai-instructions-bootstrap.ps1`：transactional installer；驗證 clean pinned source、staging bundle、runtime identity、rollback 與 SessionStart cleanup。
- `scripts/test-production-cutover.ps1`：使用真實 immutable sources 的 production cutover smoke test。
- `scripts/safe-zip.psm1`：PS5.1／7 共用的 single-root、case-collision、traversal、symlink／reparse 安全 extraction。
- `scripts/skills-catalog-contract.psm1`：驗證 Catalog、source pins、lock、manifest 與個人設定的 executable contract。
- `tests/`：Pester regression suites。
- `.github/workflows/pr8-powershell-validation.yml`：完整 dual-runtime PowerShell regression gate。
- `.github/workflows/syp86-production-lock.yml`：真實 production lock drift gate。
- `.github/workflows/syp86-production-smoke.yml`：真實 production cutover/no-op smoke gate。
