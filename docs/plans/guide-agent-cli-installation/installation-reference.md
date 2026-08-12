# AI Agent CLI 引導安裝 Skill：安裝與驗證參考

## 文件定位

- 狀態：規劃參考，尚未建立或啟用正式 Skill。
- 更新日期：2026-08-12。
- 目標環境：Windows、PowerShell 7、以 npm 為優先安裝方式。
- 涵蓋工具：OpenAI Codex CLI、GitHub Copilot CLI、FELO AI CLI、Google Antigravity CLI（`agy`）與 JetBrains Junie CLI（`junie`）。
- 用途：供後續建立「盤點本機狀態、逐步引導使用者安裝、登入並驗證 AI Agent CLI」的 Skill 使用。

本文件記錄會隨供應商版本改變的操作資料。正式 Skill 每次引導安裝前仍應查閱供應商官方文件，不得把本文件的套件版本、需求或登入畫面視為永久契約。

## 目錄

- [已確認的名稱](#已確認的名稱)
- [Skill 的預期互動邊界](#skill-的預期互動邊界)
- [共用前置檢查](#共用前置檢查)
- [OpenAI Codex CLI](#1-openai-codex-cli)
- [GitHub Copilot CLI](#2-github-copilot-cli)
- [FELO AI CLI](#3-felo-ai-cli)
- [Google Antigravity CLI](#4-google-antigravity-cliagy)
- [JetBrains Junie CLI](#5-jetbrains-junie-cli)
- [最終整體驗證](#最終整體驗證)
- [常見失敗分類與安全處理](#常見失敗分類與安全處理)
- [未來 Skill 建議結構](#未來-skill-建議結構)

## 已確認的名稱

使用者可能以簡稱或拼字近似名稱提出需求。開始安裝前，先確認名稱映射：

| 使用者名稱 | 本文件對應工具 | 執行命令 |
| --- | --- | --- |
| Codex | OpenAI Codex CLI | `codex` |
| Copilot | GitHub Copilot CLI | `copilot` |
| FELO | FELO AI CLI | `felo` |
| AGY | Google Antigravity CLI | `agy` |
| Junie | JetBrains Junie CLI | `junie` |

若使用者指的是其他同名產品，先停止並釐清，不得依名稱相似度安裝套件。

## Skill 的預期互動邊界

1. 預設只提供指令、解釋預期結果並檢查使用者貼回的非敏感輸出；除非使用者另外明確授權，Agent 不代替使用者安裝或登入。
2. 先做唯讀盤點，再一次引導一套 CLI。每套完成「安裝 → PATH → 版本 → 登入 → 狀態或 smoke test」後才進入下一套，便於定位失敗。
3. 優先使用供應商正式支援的 npm 套件；沒有官方 npm 套件時，才提供供應商的 Windows 安裝器。
4. 不要求使用者貼出 API key、access token、OAuth authorization code、完整私人設定檔或帳號識別資訊。
5. 遠端 PowerShell 安裝器會執行供應商提供的程式碼。顯示來源網域與用途，取得使用者確認後才引導執行。
6. 工作區信任與工具權限由使用者逐一決定；不建議略過權限檢查或使用自動核准選項。

## 共用前置檢查

請使用者在一般 PowerShell 7 視窗中執行：

```powershell
node --version
npm --version
pwsh --version
git --version
npm config get prefix
```

再盤點既有命令與所有解析位置：

```powershell
$commands = @('codex', 'copilot', 'felo', 'agy', 'junie')
foreach ($commandName in $commands) {
    Get-Command $commandName -All -ErrorAction SilentlyContinue |
        Select-Object Name, CommandType, Source
}
```

判讀原則：

- GitHub Copilot CLI 的 npm 安裝目前要求 Node.js 22 以上；為簡化共同環境，五套工具以 Node.js 22 LTS 或更新的受支援 LTS 為基準。
- `Get-Command` 沒有輸出代表命令尚未安裝或不在 `PATH`，不能只以安裝程式回報成功作為完成證據。
- `codex` 可能同時來自 Codex Windows App 與 npm global prefix。保留兩者沒有問題，但應辨識目前優先解析的版本。
- 安裝或修改 `PATH` 後，先關閉並重新開啟 PowerShell，再重新驗證。

若 PowerShell 因 execution policy 阻擋 `npm.ps1`，改用 `npm.cmd` 執行相同 npm 命令，不需要為此降低整台機器的 execution policy：

```powershell
npm.cmd --version
```

## 1. OpenAI Codex CLI

### 官方來源

- [Codex CLI](https://learn.chatgpt.com/docs/codex/cli)
- [OpenAI authentication](https://learn.chatgpt.com/docs/auth)

### npm 安裝或更新

```powershell
npm install --global @openai/codex@latest
```

### 安裝驗證

```powershell
npm list --global @openai/codex --depth=0
Get-Command codex -All | Select-Object Name, CommandType, Source
codex --version
```

若 Windows App 的 `codex.exe` 優先於 npm shim，先取得 npm global prefix，再直接驗證 npm 版本：

```powershell
$npmPrefix = npm prefix --global
& (Join-Path $npmPrefix 'codex.cmd') --version
```

不要為解決優先順序而直接刪除 Windows App。先確認使用者希望保留哪套入口，再調整使用者層級 `PATH` 或明確呼叫 npm shim。

### 登入與狀態驗證

```powershell
codex login
codex login status
```

`codex login` 會開啟瀏覽器。一般互動使用優先選擇 ChatGPT 登入；API key 屬於用量計費的另一種登入方式，不應在沒有使用者選擇時預設採用。

通過條件：

- `codex --version` 成功。
- `codex login status` 顯示有效登入方式。
- `Get-Command codex -All` 的優先路徑符合使用者預期。

## 2. GitHub Copilot CLI

### 官方來源

- [Installing GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)

### 前置需求

- Node.js 22 或更新版本。
- Windows 使用 PowerShell 6 或更新版本。
- GitHub 帳號具備可使用的 Copilot 方案；組織提供的方案還需要管理員啟用 Copilot CLI policy。

### npm 安裝或更新

```powershell
npm install --global @github/copilot@latest
```

這是執行命令為 `copilot` 的獨立 CLI，不應與舊版 `gh-copilot` extension 或 AWS Copilot CLI 混淆。

### 安裝驗證

```powershell
npm list --global @github/copilot --depth=0
Get-Command copilot -All | Select-Object Name, CommandType, Source
copilot --version
```

### 登入與驗證

```powershell
copilot
```

進入互動介面後輸入：

```text
/login
```

依畫面在瀏覽器完成 GitHub 登入。登入後執行 `/help` 或送出不修改檔案的簡單問題作為 smoke test，再退出互動介面。

通過條件：

- `copilot --version` 成功。
- 互動介面不再要求 `/login`。
- 組織 policy 沒有封鎖 CLI。

## 3. FELO AI CLI

### 官方來源

- [FELO Skills and terminal CLI](https://felo.ai/skills)
- [felo-ai npm package](https://www.npmjs.com/package/felo-ai)

### npm 安裝或更新

```powershell
npm install --global felo-ai@latest
```

### 安裝驗證

```powershell
npm list --global felo-ai --depth=0
Get-Command felo -All | Select-Object Name, CommandType, Source
felo --version
```

### 認證

FELO CLI 使用 FELO API key。由使用者在 FELO 帳號介面自行建立 key；Agent 不接收 key。PowerShell 7 可用遮蔽輸入避免 key 出現在命令歷史：

```powershell
$env:FELO_API_KEY = Read-Host 'FELO API key' -MaskInput
felo config set FELO_API_KEY $env:FELO_API_KEY
Remove-Item Env:FELO_API_KEY
```

不得要求使用者執行會把真實 key 直接寫進聊天、Repository、範例檔或可分享 log 的命令。

### Smoke test

```powershell
felo search "What is the official OpenAI documentation URL?"
```

通過條件：

- `felo --version` 成功。
- 搜尋不回報 authentication、quota 或 request failure。
- 使用者只回報成功或安全錯誤分類，不貼 API key 或完整私人設定。

正式 `search-with-felo` Skill 仍必須透過其 compact wrapper 呼叫 FELO；安裝 smoke test 成功不代表可以把 FELO 原始 JSON 直接送入 Agent 上下文。

## 4. Google Antigravity CLI（AGY）

### 官方來源

- [Hands-on with Antigravity CLI](https://codelabs.developers.google.com/antigravity-cli-hands-on)

### 安裝方式

截至本文件更新日，官方 Windows 安裝流程不是 npm 套件，而是供應商 PowerShell 安裝器：

```powershell
irm https://antigravity.google/cli/install.ps1 | iex
```

引導使用者執行前，明確說明命令會下載並立即執行 `antigravity.google` 的遠端程式碼。若使用者希望先檢查內容，改為先下載到暫存檔、檢閱後再執行。

### 安裝與更新驗證

```powershell
Get-Command agy -All | Select-Object Name, CommandType, Source
agy --version
agy --help
```

CLI 提供更新子命令時可使用：

```powershell
agy update
```

更新後再次執行 `agy --version`。

### 登入與驗證

```powershell
agy
```

首次啟動選擇 `Google OAuth` 或使用者指定的 Google Cloud project 方式。OAuth 流程會開啟瀏覽器並要求將 authorization code 貼回終端；Agent 不要求使用者分享該 code。登入後只信任使用者明確認識的工作目錄，並保留預設的 review／permission 行為。

通過條件：

- `agy --version` 與 `agy --help` 成功。
- 重新啟動 `agy` 後不再顯示未登入狀態。
- 使用者已自行選擇工作區信任與工具權限。

## 5. JetBrains Junie CLI

### 官方來源

- [Junie CLI quickstart](https://junie.jetbrains.com/docs/junie-cli-usage.html)
- [Junie CLI reference](https://junie.jetbrains.com/docs/parameters.html)

### 安裝方式

截至本文件更新日，官方 Windows 安裝流程不是 npm 套件，而是 JetBrains PowerShell 安裝器：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://junie.jetbrains.com/install.ps1')"
```

此命令只對該子程序使用 `ExecutionPolicy Bypass`。引導執行前要說明它會下載並立即執行 `junie.jetbrains.com` 的遠端程式碼；若使用者希望檢閱，先下載到暫存檔再執行。

### 安裝驗證

```powershell
Get-Command junie -All | Select-Object Name, CommandType, Source
junie --help
```

若目前版本支援 `--version`，再補充執行：

```powershell
junie --version
```

### 登入與驗證

```powershell
junie
```

互動流程可選擇：

- JetBrains Account：瀏覽器登入，適合使用 JetBrains 訂閱權益。
- `JUNIE_API_KEY`：由使用者至 Junie CLI 頁面建立 token。
- BYOK：由使用者提供所選模型供應商的 API key 或 OAuth。

預設先引導 JetBrains Account；只有使用者明確選擇 usage-based billing 或 BYOK 時才說明 token／provider key。Agent 不接收任何 key。

通過條件：

- `junie --help` 成功。
- 互動啟動後不再顯示未認證狀態。
- 若連接 JetBrains IDE，使用 `/ide` 確認狀態；CLI 本身可用不應依賴 IDE integration 必須成功。

## 最終整體驗證

安裝與登入全部完成後，請使用者執行：

```powershell
$commands = @('codex', 'copilot', 'felo', 'agy', 'junie')
foreach ($commandName in $commands) {
    "--- $commandName ---"
    Get-Command $commandName -All -ErrorAction SilentlyContinue |
        Select-Object Name, CommandType, Source
}

codex --version
copilot --version
felo --version
agy --version
junie --help
codex login status
```

Agent 應將結果整理成狀態表，不把單純「命令存在」誤判為「已登入」：

| CLI | 安裝 | PATH | 版本 | 認證 | Smoke test | 備註 |
| --- | --- | --- | --- | --- | --- | --- |
| Codex | pending/pass/fail | pending/pass/fail | 值或錯誤 | pending/pass/fail | pending/pass/fail | npm／Windows App 來源 |
| Copilot | pending/pass/fail | pending/pass/fail | 值或錯誤 | pending/pass/fail | pending/pass/fail | Copilot policy |
| FELO | pending/pass/fail | pending/pass/fail | 值或錯誤 | pending/pass/fail | pending/pass/fail | 不記錄 key |
| AGY | pending/pass/fail | pending/pass/fail | 值或錯誤 | pending/pass/fail | pending/pass/fail | OAuth／Cloud project |
| Junie | pending/pass/fail | pending/pass/fail | 值或錯誤 | pending/pass/fail | pending/pass/fail | Account／API key／BYOK |

## 常見失敗分類與安全處理

### `command not found` 或 `Get-Command` 無結果

1. 關閉並重新開啟 PowerShell。
2. 執行 `npm prefix --global`，確認 npm global prefix 已加入使用者 `PATH`。
3. 使用 `Get-Command <name> -All` 與 `where.exe <name>` 檢查重複入口。
4. 不直接刪除未知 executable；先辨識安裝來源。

### npm 權限或 script 問題

- `npm.ps1` 被阻擋時使用 `npm.cmd`。
- 不以系統管理員身分作為第一個解法；先檢查 npm global prefix 是否指向使用者可寫位置。
- 不因單一套件要求而永久放寬全機 execution policy。

### 版本不符

- Copilot 若 Node.js 低於 22，先停止 Copilot 安裝並引導更新 Node.js。
- 不用 npm 自行更新 Node.js runtime；使用 Node.js 官方安裝器或作業系統套件管理器。

### 登入失敗

- 只請使用者回報錯誤訊息與錯誤分類，先移除帳號、tenant、token、authorization code 與私人 URL。
- 檢查瀏覽器是否能開啟、系統時間是否正確、公司 proxy／policy 是否阻擋，以及帳號是否具備產品權益。
- 不要求使用者把 credential 存進 Repository 或傳給 Agent 代為登入。

### 遠端安裝器失敗

- 確認 URL 網域與官方文件一致。
- 可下載到新的暫存檔後檢閱內容；不要覆寫 Repository 檔案。
- 安裝器改版或 URL 失效時，重新查詢官方文件，不使用第三方鏡像或名稱相似的 npm 套件替代。

## 未來 Skill 建議結構

若後續正式建立 Skill，建議使用短且動詞導向的名稱，例如 `guide-agent-cli-setup`：

```text
guide-agent-cli-setup/
├── SKILL.md
├── agents/
│   └── openai.yaml
└── references/
    ├── common-windows-checks.md
    ├── codex.md
    ├── copilot.md
    ├── felo.md
    ├── antigravity.md
    └── junie.md
```

`SKILL.md` 只保留下列核心流程：

1. 確認工具名稱、作業系統與使用者是否只要引導。
2. 查閱當次任務涉及的供應商 reference，不一次載入全部文件。
3. 從唯讀盤點開始，依 npm 優先規則選擇安裝方式。
4. 每次只引導一個可驗證步驟，等待使用者貼回安全輸出。
5. 將安裝、PATH、版本、認證與 smoke test 分開判定。
6. 產出狀態表與下一個最小動作，不記錄 credential。

詳細且易變的供應商命令應分拆至一層 `references/`。若未來反覆需要相同的唯讀盤點，可再考慮加入只輸出 allowlist 欄位的 PowerShell script；第一版不需要用 script 代替使用者執行安裝或登入。
