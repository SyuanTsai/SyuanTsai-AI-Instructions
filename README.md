# SyuanTsai AI Instructions

## Overview

**What it is:** the single source of truth for my AI coding-agent setup — shared instructions for **Codex, GitHub Copilot and Claude**, plus a version-pinned catalog of reusable Agent Skills.

**Problem it solves:** keeping AI agents consistent and safe across many repositories. Instead of hand-copying prompts, every repository gets the same reviewed rules and Skills, pinned to exact versions.

**How it works**
- One common instruction source generates the Codex, GitHub Copilot and Claude variants, so the three tools follow the same rules.
- The Skills catalog points to separate Skill repositories ([Skill-General](https://github.com/SyuanTsai/Skill-General), Skill-Atlassian-Ecosystem, Skill-Code-Collaboration, Skill-Knowledge-Content) and locks each one to a commit SHA and content hash.
- A bootstrap fans the instruction files out into product repositories on Windows, Linux and macOS. Shared Skills are installed once per user under `~/.agents/skills` by default; the optional V3V5 USER projection remains Windows-only and also projects the same managed bytes to `~/.claude/skills` while managing the repository-instructions section in `~/.claude/CLAUDE.md`. Later `Auto` installs and updates preserve that v3/v5 selection and any config-v5 capability evidence declared with `-CapabilityEvidence` (or the legacy environment variable); `state: "absent"` explicitly revokes a capability, while `-ClearCapabilityEvidence` clears stored evidence. When connector or environment evidence is unknown, a capability-gated Skill already listed in the managed USER manifest is preserved and updated with a warning; a fresh install still filters it. Unmanaged differing bytes fail with `unmanaged-collision` and must be backed up and moved manually. A verified v3/v5 runtime may additionally project Skills into explicitly selected project roots. That project selection is global and applies to every consumer repository not covered by an exclusion. Updates are checked and reported, not silently auto-installed.
- CI validates contracts and runs security scanning on Skills before anything is published.

**Who it's for:** engineers who want repeatable, reviewable AI-assisted workflows on Windows, Linux or macOS. WSL is not supported.

## 概覽

**這是什麼：** 我個人 AI 程式開發代理（Agent）設定的唯一來源，包含 **Codex、GitHub Copilot、Claude** 共用的指令，以及鎖定版本的可重複使用 Agent Skills 目錄。

**解決什麼問題：** 讓 AI Agent 在多個 Repository 之間保持一致、安全。不再手動複製 Prompt，每個 Repository 都使用同一套經過審查、鎖定版本的規則與 Skills。

**運作方式**
- 由同一份共用指令產生 Codex、GitHub Copilot、Claude 三種版本，三個工具遵循相同規則。
- Skills 目錄指向獨立的 Skill Repository（[Skill-General](https://github.com/SyuanTsai/Skill-General)、Skill-Atlassian-Ecosystem、Skill-Code-Collaboration、Skill-Knowledge-Content），並以 commit SHA 與內容雜湊鎖定版本。
- bootstrap 在 Windows、Linux 與 macOS 將指令檔分發到各產品 Repository；共用 Skills 預設由獨立 updater 安裝在使用者層級的 `~/.agents/skills`。選用的 V3V5 USER projection 仍只支援 Windows；啟用後，同一份受管 bytes 也會投影到 `~/.claude/skills`，並管理 `~/.claude/CLAUDE.md` 的 Repository Instructions 區段。後續 `Auto` 安裝與更新會沿用 v3/v5，以及透過 `-CapabilityEvidence`（或舊環境變數介面）寫入 config v5 的能力證據。`state: "absent"` 可明確撤銷能力，`-ClearCapabilityEvidence` 可清除已存證據；connector／environment 證據未知時，受管 USER manifest 已列出的 capability-gated Skill 會保留、更新並提示，但全新安裝仍會過濾。若未受管的同名檔案 bytes 不同，會以 `unmanaged-collision` 拒絕，必須由使用者先備份並移開。通過驗證的 v3/v5 runtime 可再把 Skills 投影到明確選取的 project roots；這是全域 opt-in，會套用到所有未排除的 consumer Repository。有新版本時只檢查並通知，不會自動悄悄安裝。
- 發布前由 CI 驗證契約，並對 Skills 執行安全掃描。

**適用對象：** 想要在 Windows、Linux 或 macOS 使用可重複、可審查 AI 輔助開發流程的工程師；不支援 WSL。

---

這個 Repository 是個人 Codex／GitHub Copilot Instructions、Skills Catalog 與安裝 runtime 的 canonical source。共用 Agent Skills 只由 Catalog 指向的 external repositories 提供，本 Repository 不保存 Skill source 副本。

本 Repository 與採用其共用 AI-Instructions／Skills runtime 的消費 Repository，其本機 Agent 開發、安裝、執行、驗證、測試與 acceptance 支援 Windows、Linux 及 macOS；不支援 WSL。這項 host 範圍不涵蓋下游產品的 target／deployment OS，也不限制核准 connector 背後遠端 SaaS 的服務 OS。Required CI 的目前實作範圍另見測試章節，不以支援範圍推導 required checks。

目前 runtime 採用 branch-independent 的個人本機 artifacts 模型：fan-out 到產品 Repository 的 `AGENTS.md`、`.codex/AI-Rules/**`、GitHub Copilot Instructions 與 manifest 會存在 working tree、套用於所有 branch，但由 `.git/info/exclude` 排除。一般同步不會替產品 Repository stage 或 commit；只有偵測到歷史上已 tracked 的 reserved Agent artifacts 時，會建立一次性的隔離本機 remediation commit。Bootstrap 永遠不會 push 產品 Repository。共用 Catalog Skills 預設只由 USER updater 安裝／更新至 `~/.agents/skills/**`；USER 缺少或不可用也不回退 REPO。只有通過 v3/v5 gate 且 `projections.project` 明確非空時，project-scope durable transaction 才會從同一 immutable Catalog source 寫入 `.agents/skills/**`、`.claude/skills/**` 或 `.github/skills/**`。這個設定是全域 opt-in，會套用到所有未排除的 consumer Repository；專案自有 Skills 永遠保留。若任何選定的 project Skill 與 tracked、staged、unmanaged、drift 或 reparse 內容衝突，bootstrap 會在任何 mutation 前整筆拒絕，Instructions 也不更新；請移除或改名專案自有 Skill，或將該 Skill 從 `projections.project` 移除後重試。「只拒絕 project transaction、Instructions 仍完成」保留為 follow-up，不屬目前發布模型。

## Production 契約

- Skills Catalog schema 3：stable Skill ID、profiles、compatibility、dependencies、lifecycle，以及 `user-agents`／`user-claude` USER projections。
- Catalog lock schema 3：把外部來源鎖定到完整 commit SHA、archive hash、Skill content hash 與 projection contract hash。
- USER managed manifest schema 3：在 v3/v5 opt-in 後記錄兩個 projection 的完整 provenance、content hash 與 generation；legacy v2/v4 仍使用 manifest v2。
- Personal sync configuration schema 5：在 v3/v5 opt-in 後記錄 exclusions、immutable runtime pin、Skill selection、更新 policy 與 USER projections；未 opt-in 的 fresh／v2v4 `Auto` 安裝仍維持 schema 4。
- Runtime bundle schema 3：在 v3/v5 opt-in 後記錄 canonical Repository、commit、acquisition、archive hash、exact runtime inventory 與 projection binding；未 opt-in 的 fresh／v2v4 `Auto` 安裝仍維持 schema 2。
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

## Instructions 來源與產生

三平台 authority artifacts 由 `instructions/common/` 的同源內容與 `ai-instructions-contract.json` 產生。繁體中文是主要維護來源；英文來源保留相同要求、限制與例外。規則路徑在 common source 使用 `{RULE_ROOT}/`，由產生器依 Codex、GitHub Copilot 或 Claude 的 authority root 替換。

只有 Base 中平台能力確實不同的最小內容可使用 `<!-- host:codex|copilot|claude -->` … `<!-- /host -->`；區塊不得巢狀、未閉合、使用未知 host，或跨越 `ai-route`／`ai-invariant` marker 行。一般共通規範不得放入 host 區塊。Rules 不得使用 host 區塊，平台路徑差異只能透過 `{RULE_ROOT}/`，正規化後三平台全文相同。

```powershell
.\scripts\Build-AiInstructions.ps1
.\scripts\Build-AiInstructions.ps1 -Check
```

產生器固定輸出 UTF-8 無 BOM、LF 換行與單一結尾換行。`-Check` 只比對、不寫入，並在 common source 或 authority artifact 漂移時列出受影響的輸出。Claude authority artifacts 已納入產生與 contract parity；consumer fan-out 是否啟用仍以 contract 的 `fanOut` 宣告為準。

## 內部模組 review assessment

SkillSpector 的 analyzer coverage 不完整時，canonical Stage 4 仍維持 `FAILED`／exit code `20`，不得改寫成掃描完成。中央 authority 可透過 [internal-source-continuation.json](docs/standards/internal-source-continuation.json) 將特定 repository 與 Skill 登錄為內部模組；consumer 不得自行宣告或複製這份 allowlist。


中央登錄的內部模組可用 `New-StandardValidationInternalSourceReviewAssessment` 讀取既有 Report，產生 `consistent`／`inconsistent` 的 evidence-consistency-only 審查資料。所有結果固定 applicability 與 execution provenance `not-verified`、`authorizationGranted=false`、`authorizedOperations=[]`、`publishable=false`、`releaseEligible=false`，不授權 source-merge、release、install、publish 或 catalog adoption。Canonical `FAILED`／20 維持；typed counters、safe Skill IDs、exact findings、raw revision/content 與 authenticated authority binding 保留。介面不執行或派送命令；完整 applicability、可信執行與 protected adoption 為 deferred integration。參見 [Standard §9.3.1](docs/standards/skill-repository-standard.md#931-internal-source-continuation)。

## 同步模型

只有 Codex 準備建立或更新 production code 的實作計畫時，個人 `AGENTS.md` 才會要求執行 installed bootstrap；一般問答、釐清與解釋不執行。

每次執行依序完成：

1. 驗證 installed config／runtime generation（v4＋bundle v2，或 v5＋bundle v3）、所有 runtime bytes、Catalog 與 Lock。
2. 依更新 policy 檢查 canonical protected `main` 或 latest GitHub release；預設只通知，不自動安裝。
3. 依 Catalog selection 解析 external Skills，只取得 lock 中的 immutable commits，驗證 archive 與每個 Skill content inventory。
4. 將 Codex、GitHub Copilot 與 Claude Instructions 組成已驗證 archive，再交給 mutation engine；預設時選中的 Skills 只提供可信 USER inventory 核對。只有通過 v3/v5 gate 且全域 `projections.project` 非空時，multisource 才另外建立 lock-bound project candidate，交由 project-scope durable transaction 套用至所有未排除的 consumer Repository。
5. 在 common Git directory 的 repository operation lock 內先辨識 reserved tracked Agent artifacts。若存在，於 Repository 外保存 HEAD、branch、完整 active index、status、diff、檔案 bytes 與 SHA-256 inventory；加入精確 `info/exclude` 規則，以 task-scoped identity 建立只含 reserved path deletions 的 `chore: stop tracking local AI instructions` 本機 commit，再依最新來源替換精確 runtime files。無 remote、缺少永久 Git identity 或 detached HEAD 都可安全完成；detached HEAD 會建立 `codex/ai-instructions-remediation-*` 本機 branch。任何後續同步失敗會以 applied-state CAS 還原 HEAD、index、檔案與 exclude snapshot；若外部程序已變更其中狀態則保留外部內容並回報 backup，且 consumer commit 永不自動 push。
6. Mutation engine 依 manifest hash 更新未被自訂的檔案、建立新檔、移除來源已刪除且未被修改的檔案。既有 target／manifest 會以 target-root directory handle 的 final path 加上安全 relative path 核對實際 mutation handle，並拒絕 reparse file 與多重 hard-link alias；寫入在同一 deny-write/delete handle 驗證 snapshot original bytes、寫入並保存 applied bytes。新檔建立會從 target root 起逐層持有可阻擋 rename 的 parent handles，建立後再核對 file handle identity，因此 parent-junction swap 不能把 create 導向 root 外。受管檔案移除同樣在 handle-bound root confinement 內驗證 bytes，再由該 handle 設定 delete disposition，關閉後才完成刪除，不留下 verify-to-delete 或 stale-precheck path-swap 窗口。Exact-hash read-only 檔案會在 handle-bound transaction 內暫時清除 attribute；guard handle 保持開啟，且重開的 write handle 必須具有相同 volume/file ID，寫入後恢復 attribute，delete disposition 失敗時也先恢復。Rollback 只處理本交易確實變更且 current state 仍等於 applied state 的路徑；父目錄只在能以 volume/file ID 證明由本交易建立時才會刪除。
7. Bootstrap 另取得 active worktree 原生 `index.lock`，從 tracked/staged preflight 持有到 target、exclude 與 recovery evidence finalization 完成，使外部 staging 無法在成功交易中途插入。它先驗證 `info/exclude` 的完整 parent chain 都是 common Git metadata 內的 non-reparse directory，再以單一 exclusive read-modify-write handle 將所有 live worktree manifest 的精確受管路徑聯集寫入 managed marker block；manifest/config 固定以 UTF-8 讀取，Git C-quoted path 也以 strict UTF-8 bytes 解碼，因此 Unicode Skill resource 不受 Windows code page 影響。最後以不修改 active working tree/index 的 Git plumbing 建立 branch-neutral `PersonalAgent` recovery stash，並再次驗證 bytes 與 stash tree。

來源與目標 mapping：

- `.codex/AGENTS.en.md` → `AGENTS.md`
- `.codex/AI-Rules/*.en.md` → `.codex/AI-Rules/*.en.md`
- `.github/copilot-instructions.en.md` → `.github/copilot-instructions.md`
- `.github/AI-Rules/*.en.md` → `.github/AI-Rules/*.en.md`
- external `skills/<skill-id>/**`（或 legacy source）→ USER `~/.agents/skills/<skill-id>/**`，預設只由 USER updater 套用；明確啟用全域 project projections 時，另由已驗證 project transaction 投影到每個未排除 consumer Repository 的選定 root。

`ai-instructions-contract.json` 只用於維護來源的 inventory、locale／platform parity、route、trigger 與 safety invariant regression，不會 fan out。GitHub Copilot 的 `.github/AI-Rules/**` 是由 Base Instructions 依任務明確要求讀取的條件式模組，不是 `.github/instructions/**/*.instructions.md` 的 path-specific 自動載入檔；不得以 `applyTo: "**"` 將所有模組無條件注入。不同 Copilot surface 對 Base 指示讀取其他 Repository 檔案的能力可能不同，導入新 surface 時應依 [GitHub Copilot custom instructions](https://docs.github.com/copilot/customizing-copilot/adding-custom-instructions-for-github-copilot) 驗證 References／instructions inventory，且跨 surface 必須生效的最小安全邊界應保留在 Base。

未被 Git 追蹤、且沒有 manifest ownership 的 project-owned 或 customized 檔案不覆寫。若 Instructions manifest 缺失，但本機未追蹤 Instructions bytes 精確等於 immutable source，bootstrap 可安全重建其 ownership；Skills 缺少 manifest 時只列報，不以同 hash 接管或刪除。Reserved Agent path 一旦已 tracked，則依上一節流程先完整備份並遷移，不再要求逐 Repository 人工清理。

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

需求：Windows、Linux 或 macOS（不含 WSL）、PowerShell 7 最新穩定版、Git，以及可存取 canonical GitHub Repository 與 Catalog 選中的 external repositories。

### 已知限制

- 只有在 tracked-artifact remediation 必須把 detached HEAD 轉成 symbolic remediation branch 時，Git 必須為 2.46 以上；此路徑使用 `git update-ref --stdin` 的 atomic symref CAS，以免覆寫觀察後發生的外部 HEAD 變更。一般安裝與不需要 detached→symbolic 轉換的同步不增加 Git 版本前提。

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

### Windows Claude Code Skills 選擇啟用

預設 `Auto` 對 fresh 或既有 v2/v4 安裝仍維持 v2/v4。只有在 Windows 上明確指定下列參數，才會安裝 config v5／runtime bundle v3，並把受管 Skills 同時投影到 `~/.agents/skills` 與 `~/.claude/skills`：

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1 -WriterSchema V3V5

$codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
  $env:CODEX_HOME
} else {
  Join-Path $HOME '.codex'
}
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -Apply -OutputFormat Json
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -VerifyOnly -OutputFormat Json
```

成功啟用後，installer 的 `Auto`、launcher 自動更新，以及 `update-agent-environment` 的 Apply／VerifyOnly 都會沿用 config v5 的 `projections.user`；明確要求 `V2V4` 會以 `downgrade-refused` 拒絕。`user-claude` 也會更新 `~/.claude/CLAUDE.md` 的受管 Repository Instructions 區段，個人區段保持原 bytes。

能力證據同樣由 config v5 沿用。`-CapabilityEvidence` 接受完整 JSON array 並整份取代舊值；`state: "absent"` 明確表示能力不存在，`[]` 或 `-ClearCapabilityEvidence` 會清除。兩個參數互斥，且只適用 V3V5：

```powershell
.\scripts\install-ai-instructions-bootstrap.ps1 -WriterSchema V3V5 `
  -CapabilityEvidence '[{"kind":"connector","id":"datadog","state":"configured"}]'

# 修改／撤銷
.\scripts\install-ai-instructions-bootstrap.ps1 `
  -CapabilityEvidence '[{"kind":"connector","id":"datadog","state":"absent"}]'

# 清除全部已存證據
.\scripts\install-ai-instructions-bootstrap.ps1 -ClearCapabilityEvidence
```

若兩個參數都未提供，但 `AI_INSTRUCTIONS_CAPABILITY_EVIDENCE` 非空，installer 會為相容舊用法而把該值持久化；三者都沒有時沿用 config。每次 reconciliation 會以環境變數按 `(kind,id)` 覆蓋 config 證據，但不回寫 config。沒有 connector／environment 證據代表狀態未知：全新安裝仍不安裝受限 Skill；若受管 USER manifest 已列出該 Skill，則保留並更新到目前 pin、顯示如何宣告或以 `absent` 撤銷，VerifyOnly 仍回 `current`。platform、shell、removed lifecycle、明確 exclude 與 `command` 判斷不受此保留規則影響。

若 `~/.claude/skills/<skill-id>` 已有不同的未受管 bytes，結果會包含 `failureDetails[].code = "unmanaged-collision"`，且兩個 Skills roots、manifest 與 `CLAUDE.md` 都不變。先自行備份並移開整個舊手動副本，或只移開衝突的 Skill 目錄，再重試；installer 不會自動備份接管：

```powershell
$manualRoot = Join-Path $HOME '.claude\skills'
$manualBackup = Join-Path $HOME ('.claude\skills.manual-' + (Get-Date -Format 'yyyyMMddHHmmss'))
Move-Item -LiteralPath $manualRoot -Destination $manualBackup

# 或只移開診斷指出的單一目錄：
Move-Item -LiteralPath (Join-Path $HOME '.claude\skills\<skill-id>') `
  -Destination (Join-Path $HOME '.claude\<skill-id>.manual')
```

Linux 與 macOS 的 V3V5 USER projection runtime 尚未支援，會回 `projection-runtime-unavailable`；這不影響 installer、bootstrap 與基礎 USER runtime 的三平台支援。WSL 不支援。

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

## Personal sync configuration v4／v5

Installer 的 fresh／v2v4 `Auto` 路徑會把 v1／v2／v3／v4 idempotent 遷移為 v4；明確 `V3V5` 或既有 v3/v5 的 `Auto` 則寫入 v5，並保留既有合法的 `projections.user`／`projections.project`。舊 `autoCommitRepositoryUrls`、`autoCommitRepositoryPaths` 與 `repositoryUrls` 會移除；exclusions 與 v3/v4 Skill selections 保留。

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

`catalog.repository/ref` 由 installer 管理；不得手動改成其他 Repository 或 mutable ref。使用者可維護 exclusions、Skill selections 與 `updates` policy；v5 另可維護契約允許的 projections。`minimumCheckIntervalMinutes` 的合法範圍是 1 到 2147483647。

## Runtime 更新

預設 `notify-only`：launcher 解析 canonical candidate，若有新版只寫 receipt 與通知，仍使用目前已驗證 runtime。`outcome = available` 會明確標示 `classification = notification`、`installationState = not-installed`、`retryable = false`，不得解讀為已安裝或更新失敗。

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
- 使用 per-Codex-Home update lock 阻止並行檢查，並以獨立 install lock 序列化 manual/updater transaction；updater 從 active runtime preflight、remote resolution、archive acquisition 到 non-install receipt 落盤都持有 install-state lock，只在交給 candidate installer 前釋放。Verified launcher／updater snapshot／Agent environment updater／cleanup 在使用 runtime 時持有 shared read lock，installer 只有取得 exclusive lock 才能 swap；Agent environment `-Apply` 不呼叫 updater，會在同一份 verified runtime read lease 下完成 desired-state resolution 與 reconciliation。Installer 取得鎖後會重驗 updater 選擇 candidate 時的 current commit 與 mode/channel/ref，核准已撤銷或 policy 已變更時在任何 mutation 前停止；
- 以原子替換的 `ai-instructions-update-receipt.json` 記錄 current、available、installed、offline、stale、drift 或 failed；`current` 以 `currentCommit` 表示已解析版本且 `candidateCommit` 為 `null`，避免重複身分無法由 JSON Schema 驗證。若舊 receipt 損壞，先 quarantine 再從已驗證 runtime 繼續檢查。

最小檢查間隔尚未經過時，updater 回傳不落盤的 `rate-limit` workflow 結果並保留上一份有效 receipt；鎖已被其他 updater／installer 持有時則回傳不落盤的 `concurrent` 並讓 manual command／launcher fail closed。兩者都不屬於 update receipt schema 的 persisted outcomes。

網路不可用或 GitHub API 暫時 rate-limited 時，updater 不會破壞或降級現有 runtime；已驗證 runtime 仍可繼續使用已安裝 Catalog/Lock。Stable launcher 以自身內建、未載入 runtime code 的 preflight 先驗證 strict config/bundle、launcher reference 與完整 inventory，manual updater／Agent environment updater／cleanup 也先呼叫同一 preflight，通過後才載入任何 runtime module。Launcher／updater 會輸出 failure `classification` 與 `retryable`；只有 sandbox／permission denial 可在核准後重試一次，configuration、compatibility 或 integrity failure 不得迴圈重跑。若 stable launcher 與 reference copy 不同，或 local runtime inventory 有缺檔、額外檔案、reparse point 或 hash drift，所有 stable entry point 都會 fail closed，應重新執行可信 installer。

## 使用者層級 Agent 環境同步

完成 runtime 安裝後，可從任何目錄依目前 verified runtime 同步 `$HOME/.agents/skills`。這個命令不檢查或安裝 AI-Instructions candidate；需要更新 runtime 時，先使用上一節的 updater 明確完成，再執行同步：

```powershell
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -Apply -OutputFormat Json
```

本修正合併並發布後，每個彼此獨立的 `CODEX_HOME` 各執行一次下列升級／正規化／驗證流程；不需要逐一修改 consumer Repository：

```powershell
$codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
  $env:CODEX_HOME
} else {
  Join-Path $HOME '.codex'
}
& (Join-Path $codexHome 'hooks\update-ai-instructions.ps1') -ForceCheck -InstallApproved
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -Apply -OutputFormat Json
& (Join-Path $codexHome 'hooks\update-agent-environment.ps1') -VerifyOnly -OutputFormat Json
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

## Linux／macOS setup

- Linux setup 在 runtime 與 USER VerifyOnly 成功後，將精確 `catalog.ref` 的 Instructions 與 lock 驗證過的 Skills archives 原子寫入 `CODEX_HOME/ai-instructions-source-cache`（0700／0600）。受限 session 的 fan-out 使用此私有快取；pin／lock 過期時提示並回到下載，符合版本的快取若缺檔、格式錯誤或 hash 不符則以 integrity 停止。

這個 setup entry point 支援 Linux 與 macOS（不含 WSL）。Linux 預設會準備 canonical pwsh、安裝或更新 v3/v5 runtime，並把 `user-agents` 與 `user-claude` 投影到目前的 USER home；macOS 仍只執行既有的 P10a runtime 準備／驗證流程。

取得方式：以 git clone 取得 Repository，checkout 固定的 full commit SHA，並把同一個 SHA 傳給 `--expected-commit`。Setup 會先以自包含 verifier、在停用 Git replace objects 的情況下確認 `HEAD` 等於該值；六個 setup 檔案及 `scripts/platform-runtime.psd1` 宣告的完整 platform runtime closure，逐檔比較 expected commit blob、stage-zero index blob 與 `hash-object --no-filters` 的 raw worktree blob。這條路徑不執行 repository-local filter、textconv、diff driver、hook 或 fsmonitor；完成前不載入 Repository module。

```sh
git clone https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git ai-instructions
cd ai-instructions
git checkout --detach <40 位小寫 commit SHA>
sh scripts/setup-agent-environment.sh --expected-commit <同一個 SHA>
sh scripts/setup-agent-environment.sh --expected-commit <同一個 SHA> --offline
```

若 clone 建立於 `.gitattributes` 強制 setup／platform runtime 檔案使用 LF 之前，舊的 CRLF working-tree bytes 會造成 hash mismatch。先 commit 或完整備份所有本機變更，確認 working tree／index 可被覆寫後，再依目前 attributes 從 index 重新展開：

```sh
git add --renormalize .
git checkout-index --force --all
```

- Linux 未指定 mode 時等同 `--prepare`；macOS 仍須明確指定 `--prepare` 或 `--offline`。`--prepare` 允許網路，依 `scripts/setup-agent-environment.policy.tsv`（由 `setup-agent-environment.policy.json` 衍生）下載並驗證官方 PowerShell 7.6.6 release asset。runtime 首次 publication 仍以 create-only rename、`durably flushes` parent 與 readback 完成既有 WAL 契約。Linux 首次執行以 installer 的 `-WriterSchema V3V5` 建立 config v5／bundle v3，再以 public USER coordinator Apply 及 VerifyOnly；成功 receipt 為 `completed`，S7～S9 都有 completed evidence，`runtimeCommit` 等於 expected commit。
- 受限出站網路（egress allowlist）須允許 `github.com`、`objects.githubusercontent.com`、`release-assets.githubusercontent.com` 與 `codeload.github.com`。`--prepare` 從 `github.com` 及其 release asset redirect hosts 下載官方 PowerShell；USER coordinator（`update-agent-environment.ps1`）依 `catalog/skills-catalog-lock.json` 的 immutable pin，從 `https://codeload.github.com/<owner>/<repo>/zip/<commit>` 下載每個 Skills source ZIP。已安裝 coordinator 的 WhatIf preflight，以及後續 Apply／VerifyOnly 都會下載。Setup 的 runtime 更新使用 expected commit 的本機 `git archive`，不呼叫 `api.github.com`；該 API 僅用於 installed updater 自己的遠端更新檢查，不屬於 setup。`HTTPS_PROXY`／`HTTP_PROXY`／`NO_PROXY` 及其小寫版本會傳給 setup 子程序。
- 已安裝 coordinator 的 WhatIf preflight 若因 `codeload.github.com` 被封鎖而失敗，setup 會在任何 runtime mutation 前以 exit 31 `projection-failed` 拒絕。Projection 拒絕訊息除了 child stderr，也含 coordinator JSON 的去敏摘要（`outcome`、`exitCode`、`Code`、第一個 `failed` 與最多三筆 `failureDetails`），例如 `Child result: ... failed=Response status code does not indicate success: 403 (Forbidden).`。
- Linux 重跑依 pin 選擇唯讀驗證或既有 updater workflow：相同 commit 先以 installed launcher 的 `-ValidateOnly` 驗證，再執行 projection preflight／Apply／VerifyOnly。乾淨的相同 pin 重跑保持 `CODEX_HOME` 與受管 USER trees byte-identical；若 manifest-owned 檔案發生受管 drift，Apply 會修復受管內容，而 collision／ownership 檢查會保留 unmanaged bytes 不變。expected commit 前進時只接受目前 installed pin 的 descendant，並在獨立 pwsh 子程序中安裝新 pin、以 `Auto` 保持 V3V5，接著重新 Apply／VerifyOnly projections。所有子程序均以關閉的 stdin、`-NoProfile -NonInteractive` 執行。
- 雲端環境可能沿用 cached environment snapshot；修改環境 setup script 的 `--expected-commit` pin 不保證既有快取會重跑 setup。變更 pin 後，請核對 setup receipt 的 `runtimeCommit` 或 `~/.codex/hooks/ai-instructions-runtime/runtime-bundle.json` 的 `commit`；在 session 內手動執行 setup 只影響該 session。
- 每個雲端 session 都從環境的 setup snapshot 重建；session 內的 `~/.claude` 變更、update-check receipts 與 fan-out 結果不會保留到下一次，因此 installed bootstrap 每個 session 都會重新執行更新檢查與 fan-out。Fan-out 使用 setup 寫入的 source cache，不需在 session 內存取 GitHub。
- 雲端 session 的 runtime／Skills 更新只能透過修改環境 setup script 的 `--expected-commit` pin 並重建 setup snapshot；session 內的更新或編輯會遺失。
- `--offline`：不連網，只讀 cache 並重驗既有 canonical pwsh；cache 必須是目前 uid 擁有、link count 1、`0600` 的一般檔案。Setup 會以 no-follow 方式複製到本次 private temp snapshot，後續 hash、解壓與 PowerShell handoff 只使用該 snapshot。cache 缺少、metadata／hash 不符或尚未 `--prepare` 都會以 typed exit code 失敗，不做任何更新。結果為 `verified-runtime-only`。
- Setup root 固定為 `$HOME/.local/share/ai-instructions-setup`（不讀 XDG）：`cache/` 放已驗證的 archive，`pwsh/<version>-<rid>-<random>/` 放 immutable canonical pwsh attempt，`pwsh-tmp/` 是 pwsh hand-off 使用、持久存在且會驗證 owner 與 `0700` mode 的 private `TMPDIR`，`receipts/runtime-<version>-<rid>.json` 是唯一 current pointer，另有 `setup-receipt.json`（`0600`）。`tmp/run.<pid>.<random>/` 只屬於單次執行；結束時只會 best-effort 移除本次已知檔案與空目錄，不遞迴刪除、掃描或接管舊 tmp tree。強制終止可能留下私有 tmp 或未被 receipt 指向的 runtime orphan；不要用自動清理猜測 ownership。重驗失敗時 fail closed，不會自動重裝；同時執行時以 setup lock 序列化，被占用時回 `concurrent`，結束時不持有 lock。
- Receipt 同時以單行 JSON 輸出到 stdout，欄位含 `schemaVersion`、`result`、`code`、`exitCode`、OS／architecture／RID、`setupCommit`、`runtimeCommit`、policy hash、pwsh 路徑與 version、.NET version、capability 名稱與狀態，以及 S5～S9 步驟狀態。Linux completed receipt 的 `runtimeCommit` 為 expected commit；P10a runtime-only receipt 仍為 `null`。路徑一律寫成 `~/...`，不含使用者名稱、token 或 site。
- `CODEX_HOME` 只在 setup 的 process scope 設為 `~/.codex`；外部已設成其他值時回 `codex-home-conflict`。Transaction store 不存在或為空的實體目錄時視為 clean；若 store 是 link、非目錄、不可列舉，或內含任何 entry，setup 回 `interrupted-install` 並附上 recover 指令，不會自動 recover。Setup 自己在 publication swap 留下的 durable journal 則會在取得 setup lock 後依 recorded state 安全完成或回復；無法證明狀態時同樣 fail closed。
- Windows 也可直接執行 `pwsh -NoProfile -NonInteractive -File scripts/setup-agent-environment.ps1 -Prepare|-Offline -ExpectedCommit <SHA> -ArchivePath <本機 zip>`。zip 必須是 policy 指定的官方 asset（例如 `PowerShell-7.6.6-win-x64.zip`），由使用者自行從 PowerShell 官方 GitHub release 下載；policy 就是同一個 commit 的 `scripts/setup-agent-environment.policy.json`，setup 會驗證檔名與 SHA-256。

Runtime 發布的 crash-state 契約如下；任何狀態都不會回收或覆寫已發布的 runtime 目錄：

Durability closure rule：任何 commit marker（`journal.json`、runtime pointer receipt、setup receipt 或 shared-cache publication）發布前，它所依賴的檔案必須完成資料／metadata flush，所有新目錄 entry 必須由 `Confirm-PlatformDirectoryDurability` 完成 parent-directory flush 與 identity/path readback，完整 runtime directory inventory 也必須逐目錄 flush。任何一步失敗都不得發布 marker；WAL 狀態留給下一個持鎖執行者處理，未收據化 runtime 則保留為 orphan。盤點涵蓋 shell run tmp／private snapshot，以及 PowerShell 的 lock、transaction、journal、stage、displaced、runtime、cache 與 receipts；暫存物與 lock 沒有 commit marker，因此不宣稱跨斷電持久，只要求 ownership、readback 與安全清理。

| 中斷點 | 可見狀態 | 下一次持鎖執行 |
|---|---|---|
| private stage 建立前 | 沒有 runtime attempt | 建立全新的 attempt |
| stage 完整、unique runtime rename 前 | 只有私有 stage／tmp（可能成為 orphan） | 建立全新的 attempt；不掃描舊 tmp，也不使用未收據化 stage |
| unique runtime rename 後、尚無可恢復的 receipt WAL（包含 parent flush／readback 失敗） | 未被引用、durability 未確認或尚未收據化的 immutable runtime orphan | 不發布 pointer；保留 orphan，建立新 attempt |
| runtime directory 已 durable flush 並 read back，完整 receipt WAL stage 已提交、pointer 尚未 rename | 可恢復的 receipt stage 與它指向的原 runtime | resolver 完成原 pointer，接著重驗原 runtime |
| pointer receipt 發布後 | receipt 唯一命名 current runtime | 僅重驗 receipt 指向的目錄；失敗即拒絕 |

手動持久化（D4）：setup 不會修改 `~/.profile` 等 shell profile，也不寫入任何 Atlassian／Datadog／Jira 設定。需要在新的 shell 沿用時，請自行決定是否在個人 profile 中設定 `CODEX_HOME="$HOME/.codex"`。Receipt 內的路徑是 `~/...`，不是可直接傳給程序的絕對路徑；必須讀取 `runtime-<version>-<rid>.json` 的 `executablePath`，再以目前的 `$HOME` 展開；不可自行推導含 random attempt ID 的路徑。

已知限制：

- K13（由 SYP-535 另行追蹤）：`~/.claude/CLAUDE.md` managed section 保持 verified runtime 產生的原樣；雲端 PATH 沒有 pwsh 時，該區段的 rules 仍無法直接執行。
- 祖先目錄不得為 symbolic link，且須屬於 root 或目前使用者、不可 group／other 寫入（sticky 例外）。macOS 的 `/var` 等 symlink 祖先，以及 Fedora Atomic 的 `/home` → `/var/home`，會被拒絕。
- A1：Unix 的保證是 cooperative lock、不跟隨 link 與重驗；同帳號、不遵守 lock 的惡意 writer 不在保證範圍內。
- P8：所有 projection root 與 USER home 必須在同一個 filesystem；setup 的暫存與 cache 也放在 setup root 底下以便同 filesystem `mv`。
- Setup native tests 已在 GitHub Actions `ubuntu-26.04`（x64）與 `macos-26-arm64` 的 Unix probe 各通過 59/59。其他 RID（例如 linux-arm64、osx-x64）尚未實跑；這些 probe 是目前的 CI 證據，不代表 Linux／macOS 已成為 required checks。D9 的真實雲端 acceptance 屬於 P10b。musl 系統回 `unsupported-platform`。canonical pwsh 需要系統已有其執行依賴（例如 ICU）；setup 不安裝系統套件，也不轉傳 `DOTNET_*` 等 loader／runtime 變數。

Typed exit code（shell 與 PowerShell 共用，定義在 `scripts/agent-environment-setup.psm1`）：

| Exit code | Code | 說明 |
| --- | --- | --- |
| 0 | `success` | 完成（`prepared-runtime-only`、`verified-runtime-only` 或 `completed`） |
| 1 | `internal-error` | 未預期的錯誤 |
| 10 | `usage` | 參數錯誤或缺少必填參數 |
| 11 | `unsupported-platform` | OS／architecture／musl 沒有 pinned asset |
| 12 | `home-invalid` | `HOME` 不是存在、可寫的絕對路徑目錄 |
| 13 | `unsafe-path` | 祖先為 symlink、屬主或權限不安全，或路徑型別錯誤 |
| 14 | `missing-dependency` | 缺少 git、tar、curl／wget、sha256sum／shasum 等工具 |
| 15 | `commit-mismatch` | `HEAD`、setup 檔案或完整 platform runtime closure 與 `--expected-commit` 不一致，或存在 staged／working-tree／untracked 替身 |
| 16 | `policy-invalid` | policy、schema 或衍生 TSV 不合法或不一致 |
| 17 | `download-failed` | 官方 archive 下載失敗 |
| 18 | `archive-hash-mismatch` | archive 的 SHA-256 或檔名與 policy 不符 |
| 19 | `archive-unsafe` | archive 含 link、裝置、絕對路徑或 traversal 成員 |
| 20 | `cache-missing` | 已驗證的 archive cache 不存在 |
| 21 | `runtime-missing` | `--offline` 時尚未 `--prepare` 過 canonical pwsh |
| 22 | `runtime-incomplete` | 持鎖期間預期的 runtime pointer receipt 遺失或發生 create-only publication 衝突 |
| 23 | `runtime-verification-failed` | canonical pwsh 準備或重驗失敗（不自動重裝） |
| 24 | `runtime-baseline-unavailable` | 不是 PowerShell 7 加 .NET 8 以上 |
| 25 | `capability-unavailable` | 必要的 platform capability 不可用 |
| 26 | `concurrent` | 另一個 setup、updater 或 USER projection 執行正持有對應 lock |
| 27 | `interrupted-install` | `CODEX_HOME` 或 `$HOME` 有非空或不安全的 transaction store／legacy residue |
| 28 | `codex-home-conflict` | `CODEX_HOME` 已設成 `~/.codex` 以外的值 |
| 29 | `projection-collision` | USER projection target 已有無法證明 ownership 的 unmanaged bytes；在 installer／updater mutation 前拒絕，Apply 仍會再次檢查 |
| 30 | `update-failed` | Linux installer／updater 未能產生並驗證要求的 V3V5 pin |
| 31 | `projection-failed` | USER projection Apply／VerifyOnly 失敗或 readiness 不一致 |

## Linux/macOS setup

- After runtime and USER VerifyOnly succeed, Linux setup atomically caches the exact `catalog.ref` instruction archive and lock-verified Skills archives in private `CODEX_HOME/ai-instructions-source-cache` (0700/0600). Fan-out in restricted sessions uses this cache; stale pins/locks report and use downloads, while matching caches with missing files, malformed metadata or hash mismatches stop with an integrity refusal.

This setup entry point supports Linux and macOS, but not WSL. Linux prepares the canonical pwsh, installs or updates the v3/v5 runtime, and projects `user-agents` plus `user-claude` into the current USER home. macOS retains the existing P10a runtime preparation and verification behavior.

How to obtain it: git clone the repository, check out a fixed full commit SHA, and pass the same SHA to `--expected-commit`. Before importing any repository module, a self-contained verifier disables Git replace objects and checks that `HEAD` equals that commit. For each of the six setup files and every member of the complete platform runtime closure declared by `scripts/platform-runtime.psd1`, it directly compares the expected commit blob, the stage-zero index blob, and the raw worktree blob from `hash-object --no-filters`. This path does not execute repository-local filters, textconv, diff drivers, hooks, or fsmonitor.

```sh
git clone https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git ai-instructions
cd ai-instructions
git checkout --detach <40-character lowercase commit SHA>
sh scripts/setup-agent-environment.sh --expected-commit <same SHA>
sh scripts/setup-agent-environment.sh --expected-commit <same SHA> --offline
```

Clones created before `.gitattributes` enforced LF for setup and platform-runtime files can retain CRLF working-tree bytes and fail the raw-blob hash check. Commit or fully back up local changes first and make sure the worktree and index may be overwritten, then refresh the checkout under the current attributes:

```sh
git add --renormalize .
git checkout-index --force --all
```

- On Linux, omitting the mode means `--prepare`; macOS still requires an explicit `--prepare` or `--offline`. Prepare may use the network and verifies the official PowerShell 7.6.6 asset. A first Linux run calls the installer with `-WriterSchema V3V5`, then runs public USER Apply and VerifyOnly for `user-agents` and `user-claude`. A successful receipt is `completed`, records completed S7-S9 evidence, and binds `runtimeCommit` to the expected commit.
- Restricted egress allowlists must permit `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`, and `codeload.github.com`. Prepare downloads official PowerShell from `github.com` and its release asset redirect hosts; the USER coordinator (`update-agent-environment.ps1`) downloads each Skills source ZIP from `https://codeload.github.com/<owner>/<repo>/zip/<commit>` using the immutable pins in `catalog/skills-catalog-lock.json`. Downloads occur in the already installed coordinator's WhatIf preflight and again in Apply/VerifyOnly. Setup's runtime update uses a local `git archive` of the expected commit and does not call `api.github.com`; that API is only used by the installed updater's own remote update check, outside setup. `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` and their lowercase forms are forwarded to setup children.
- If blocked access to `codeload.github.com` fails the installed coordinator's WhatIf preflight, setup refuses with exit 31 `projection-failed` before any runtime mutation. Projection refusals include child stderr plus a sanitized summary of the coordinator JSON (`outcome`, `exitCode`, `Code`, the first `failed`, and up to three `failureDetails`), for example `Child result: ... failed=Response status code does not indicate success: 403 (Forbidden).`.
- Linux reruns select read-only validation or the existing updater workflow by pin. The same commit first uses the installed launcher's `-ValidateOnly` path, then runs projection preflight, Apply, and VerifyOnly. A clean same-pin rerun remains byte-identical across `CODEX_HOME` and the managed USER trees; if a manifest-owned file has managed drift, Apply repairs the managed content while collision and ownership checks leave unmanaged bytes untouched. A changed expected commit must be a descendant of the installed pin; an isolated pwsh child runs the updater and installs it with `Auto` so V3V5 remains active, then Apply/VerifyOnly runs again. Every child receives closed stdin and `-NoProfile -NonInteractive`.
- Cloud environments may reuse a cached environment snapshot: changing the environment setup script's `--expected-commit` pin does not guarantee that an existing cache reruns setup. After changing the pin, check `runtimeCommit` in the setup receipt or `commit` in `~/.codex/hooks/ai-instructions-runtime/runtime-bundle.json`; running setup manually in a session affects only that session.
- Each cloud session is rebuilt from the environment's setup snapshot; in-session changes to `~/.claude`, update-check receipts, and fan-out results are not kept for the next session, so the installed bootstrap runs its update check and fan-out again in every session. Fan-out uses the setup-written source cache and needs no GitHub access in the session.
- Updating runtime or Skills for cloud sessions requires changing the environment setup script's `--expected-commit` pin and rebuilding the setup snapshot; in-session updates or edits are lost.
- `--offline` never uses the network. The cache must be a regular file owned by the current uid, with link count 1 and mode `0600`. Setup makes a no-follow copy into its private per-run temp snapshot; all subsequent hashing, extraction and PowerShell handoff use only that snapshot. A missing cache, invalid metadata, a hash mismatch or a missing `--prepare` is a typed failure with no update. Result: `verified-runtime-only`.
- The setup root is fixed at `$HOME/.local/share/ai-instructions-setup` (XDG is not read): `cache/` holds verified archives, `pwsh/<version>-<rid>-<random>/` immutable canonical pwsh attempts, `pwsh-tmp/` is the persistent private `TMPDIR` for the pwsh hand-off with owner and `0700` mode checks, and `receipts/runtime-<version>-<rid>.json` is the only current pointer alongside `setup-receipt.json` (`0600`). `tmp/run.<pid>.<random>/` belongs only to one invocation; the exit trap best-effort removes known files and empty directories from that invocation, but never recursively deletes, scans or adopts an older tmp tree. Forced termination can leave private tmp or a runtime orphan not named by a receipt; automated cleanup must not guess ownership. A failed re-verification fails closed without reinstalling. Concurrent runs are serialized by the setup lock and a busy lock returns `concurrent`; no lock is held after exit.
- The receipt is also printed to stdout as one JSON line with `schemaVersion`, `result`, `code`, `exitCode`, OS/architecture/RID, `setupCommit`, `runtimeCommit`, the policy hash, pwsh path and version, .NET version, capability names and statuses, and the S5-S9 step states. A completed Linux receipt binds `runtimeCommit` to the expected commit; P10a runtime-only receipts keep it `null`. Paths are always `~/...`; no user name, token or site is recorded.
- `CODEX_HOME` is set to `~/.codex` for the setup process scope only; a different pre-set value returns `codex-home-conflict`. An absent transaction store or an empty physical directory is clean. A linked store, non-directory store, unreadable store, or any entry under an install or agent-environment transaction store in `CODEX_HOME` or `$HOME` returns `interrupted-install` with a recover command; setup never recovers those external transactions automatically. A durable journal left by setup's own publication swap is safely completed or rolled back under the setup lock according to its recorded state; an unprovable state still fails closed.
- On Windows run `pwsh -NoProfile -NonInteractive -File scripts/setup-agent-environment.ps1 -Prepare|-Offline -ExpectedCommit <SHA> -ArchivePath <local zip>`. The zip must be the official asset named by the policy (for example `PowerShell-7.6.6-win-x64.zip`), downloaded by the user from the official PowerShell GitHub release; the policy is `scripts/setup-agent-environment.policy.json` at the same commit, and setup verifies the file name and SHA-256.

Runtime publication has the following crash-state contract; no state reclaims or overwrites a published runtime directory:

Durability closure rule: before any commit marker (`journal.json`, runtime pointer receipt, setup receipt, or shared-cache publication) is published, every file it depends on must complete its data/metadata flush, every new directory entry must complete parent-directory flush plus identity/path readback through `Confirm-PlatformDirectoryDurability`, and every directory in the complete runtime inventory must be flushed. A failed step publishes no marker: WAL state is left for the next lock holder, while an unreceipted runtime remains an orphan. The inventory covers the shell run tmp/private snapshot and the PowerShell lock, transaction, journal, stage, displaced, runtime, cache, and receipt writes. Temporary artifacts and the lock have no commit marker, so they make no power-loss durability claim beyond ownership, readback, and safe cleanup.

| Interruption point | Visible state | Next lock holder |
|---|---|---|
| Before private-stage creation | No runtime attempt | Creates a fresh attempt |
| Stage complete, before the unique runtime rename | Private stage/tmp only (possibly orphaned) | Creates a fresh attempt; does not scan old tmp or use an unreceipted stage |
| After the unique runtime rename with no recoverable receipt WAL yet (including parent-flush/readback failure) | Unreferenced immutable runtime orphan whose durability is unconfirmed or which is not yet receipted | Publishes no pointer; preserves the orphan and creates a fresh attempt |
| After the runtime directory is durably flushed and read back, with a complete receipt WAL stage committed but before pointer rename | Recoverable receipt stage and the original runtime it names | The resolver completes the original pointer, then re-verifies the original runtime |
| After pointer receipt publication | Receipt uniquely names the current runtime | Re-verifies only that directory; any failure refuses |

Manual persistence (D4): setup never edits shell profiles such as `~/.profile` and never writes Atlassian, Datadog or Jira settings. To reuse the environment in a new shell, decide yourself whether to set `CODEX_HOME="$HOME/.codex"` in your personal profile. Receipt paths are `~/...`, not absolute paths that can be passed directly to a process. Read `executablePath` from `runtime-<version>-<rid>.json` and expand it with the current `$HOME`; never derive the path containing the random attempt ID yourself.

Known limitations:

- K13 (tracked separately by SYP-535): the `~/.claude/CLAUDE.md` managed section remains exactly as the verified runtime produces it, so its rules cannot run directly on a cloud host whose PATH has no pwsh.
- Ancestor directories must not be symbolic links, must be owned by root or the current user, and must not be group/other writable unless sticky. macOS symlinked ancestors such as `/var` and Fedora Atomic `/home` → `/var/home` are refused.
- A1: on Unix the guarantee is a cooperative lock, no link following and re-verification; a same-account malicious writer that ignores the lock is out of scope.
- P8: all projection roots and the USER home must share one filesystem; the setup temp and cache also live under the setup root so `mv` stays on one filesystem.
- The setup native tests passed 59/59 in Unix probes on GitHub Actions `ubuntu-26.04` (x64) and `macos-26-arm64`. Other RIDs (for example linux-arm64 and osx-x64) have not run. These probes are current CI evidence; they do not make Linux/macOS required checks. Real cloud acceptance under D9 belongs to P10b. musl systems return `unsupported-platform`. The canonical pwsh needs its system runtime dependencies (for example ICU); setup installs no system packages and never forwards loader/runtime variables such as `DOTNET_*`.

Typed exit codes (shared by the shell and PowerShell entry points, defined in `scripts/agent-environment-setup.psm1`):

| Exit code | Code | Meaning |
| --- | --- | --- |
| 0 | `success` | Completed (`prepared-runtime-only`, `verified-runtime-only`, or `completed`) |
| 1 | `internal-error` | Unexpected failure |
| 10 | `usage` | Invalid or missing arguments |
| 11 | `unsupported-platform` | No pinned asset for the OS/architecture, or musl |
| 12 | `home-invalid` | `HOME` is not an existing, writable absolute directory |
| 13 | `unsafe-path` | Symlinked, unsafely owned or writable ancestor, or wrong path type |
| 14 | `missing-dependency` | git, tar, curl/wget, sha256sum/shasum or another tool is missing |
| 15 | `commit-mismatch` | `HEAD`, a setup file or the complete platform runtime closure differs from `--expected-commit`, or a staged, working-tree or untracked substitute exists |
| 16 | `policy-invalid` | The policy, schema or derived TSV is invalid or inconsistent |
| 17 | `download-failed` | The official archive download failed |
| 18 | `archive-hash-mismatch` | The archive SHA-256 or file name does not match the policy |
| 19 | `archive-unsafe` | The archive has a link, device, absolute or traversal member |
| 20 | `cache-missing` | The verified archive cache is missing |
| 21 | `runtime-missing` | `--offline` without a prepared canonical pwsh |
| 22 | `runtime-incomplete` | The expected runtime pointer receipt disappeared under the lock, or create-only publication conflicted |
| 23 | `runtime-verification-failed` | Preparing or re-verifying the canonical pwsh failed (no automatic reinstall) |
| 24 | `runtime-baseline-unavailable` | Not PowerShell 7 on .NET 8 or later |
| 25 | `capability-unavailable` | A required platform capability is unavailable |
| 26 | `concurrent` | Another setup, updater, or USER projection run holds the corresponding lock |
| 27 | `interrupted-install` | A non-empty or unsafe transaction store, or legacy residue, exists under `CODEX_HOME` or `$HOME` |
| 28 | `codex-home-conflict` | `CODEX_HOME` is set to a value other than `~/.codex` |
| 29 | `projection-collision` | A USER projection target contains unmanaged bytes without ownership evidence; setup refuses before installer/updater mutation and Apply checks again |
| 30 | `update-failed` | The Linux installer/updater did not produce and verify the requested V3V5 pin |
| 31 | `projection-failed` | USER projection Apply/VerifyOnly failed or readiness was inconsistent |

## 舊 REPO Skills 遷移

Bootstrap 先按完整 Skill 盤點；只有舊 manifest 的所有 files 都 unchanged、ignored/untracked，且 USER stable ID、可信來源／immutable pin 與完整 inventory 一致，才備份後移除精確舊檔及相應 entries。USER 新版的 hash 不會用來判斷舊 REPO bytes。客製、額外資源、tracked/staged、unknown ownership、missing manifest、USER 不可用或競態都保留整個 Skill，並回報人工處理或 USER 修復需求。`-WhatIf` 只盤點，不寫 manifest、exclude、index 或 payload；遷移日誌及 raw-byte 備份保留在 Repository 外。恢復及 SYP-259 跨主機部署步驟見 [SYP-214 runbook](docs/delivery/syp-214/README.md)。

## Tracked Agent artifact 自癒

Personal artifacts 必須保持 untracked。Bootstrap 以 `git rev-parse --show-toplevel`、Git common directory、worktree 與 branch identity 序列化每個 Repository；Windows 或 `core.ignorecase=true` 會使用 Git index 的實際 spelling 處理大小寫變體。允許的範圍只包含 root `AGENTS*.md`、`.agents/**`（排除 `.agents/skills/**`）、明確 Codex/GitHub Instructions runtime paths，以及舊 manifest 安全列出的 Instructions targets。`.agents/skills/**` 與 `.codex/skills/**` 的 tracked、staged 或專案自有內容不進入 reserved remediation。Manifest 若把 tracked production file 指到 scope 外，會在任何 mutation 前 fail closed。

自癒先把精確目標 bytes、HEAD／branch、active index、porcelain-v2 status、staged／unstaged diff 與 SHA-256 inventory 保存到系統 temp 下的 `codex-agent-artifact-backups`，再更新獨立的 remediated exclude block。取得 Git 原生 `index.lock` 後會先比對 backup index SHA-256；備份後插入的外部 staging 會原樣保留並讓本次 remediation 停止。Commit tree 從原 HEAD 的 private index 建立，只允許 `D` 狀態的 reserved paths；active index 則獨立移除相同 paths，因此無關 staged changes 不會進入 commit。刪除檔案前也會重驗 backup hash。Retired `search-with-felo` 名稱本身不是移除證據，客製、未受管與 tracked Skills 都保留。成功後立即執行正常 Instructions 同步；沒有 tracked reserved Instructions artifact 時不建立 remediation commit。

`cleanup-ai-instructions-pollution.ps1` 保留作為舊版 runtime 的明確授權診斷工具，但不是新版 bootstrap 的前置步驟。Consumer remediation commit 只留在本機，任何 runtime 都不得自動 push。

## Rollback 與復原

- Installer/updater 的一般失敗會自動恢復上一個完整 runtime/config 組合；stable-file rollback 會逐檔比較 transaction-applied bytes，保留並回報並行外部修改，同時繼續恢復其他未 drift 檔案。Transaction runtime 會先隔離到 recovery backup，重新驗證 exact bundle/inventory 後才清除；無法證明仍是 candidate 的內容會保留。Staging 驗證尚未進入 active swap 就失敗時，也會清除 staging/backup transaction directories。
- 若 rollback 本身失敗，錯誤會保留並回報 backup path；先保存該目錄再人工處理。
- Process 被強制中止導致 runtime/config pin mismatch 時，launcher 會 fail closed；若 config 與 runtime 各自有效且 active inventory／stable entry-point identity 完整，可由同一 updater 的 `-RecoverInterruptedInstall` 只對齊 verified runtime pin 並立即返回，不會接續 update check 或 install。其他 drift 仍須重新執行可信 installer。
- Target fan-out 或 evidence store/verification 失敗時，mutation engine 以包含 manifest 在內的 canonical path raw SHA-256 驗證 live bytes；target／manifest 與 `.git/info/exclude` 都只在 current state 仍等於本交易 applied state 時還原。外部 drift 會原樣保留、其他未 drift 路徑仍各自安全復原，整體回報需要人工處理並保留 recovery backup。Evidence 建立本身不修改產品 index。新 `PersonalAgent` evidence 綁定 hashed worktree identity 與 exact managed Git-blob fingerprint，並以 private temporary index、`commit-tree` 與 `stash store` 建立三親 stash commit；stash tree 驗證通過後才清理同一 worktree、已證明由 runtime 建立的 prior evidence。Legacy／同名 user stash 與其他 linked worktree evidence 都會保留；若執行 drop 時仍發生外部 index drift，會依 Git 回報的實際 commit hash 還原非預期刪除的 stash 並保留舊 evidence。
- 不要用 `git reset --hard` 清理 personal artifacts；這些檔案本來就不應在 index。

設計、安全狀態機與操作 runbook 見 [docs/syp-101-autonomous-update-self-healing.md](docs/syp-101-autonomous-update-self-healing.md)。SYP-86 舊 cutover 文件只保留歷史背景，若與本文件衝突以 SYP-101 為準。

## 驗證

修改或 Review Skill source／Web Consumer 前，請讀取 [Skill 更新與範圍維護準則](docs/skill-maintenance-guidelines.md)；該文件僅供開發維護，不屬於一般 Skill 使用或安裝前置。

契約與完整回歸：

```powershell
Invoke-Pester -Script .\tests -PassThru
.\scripts\update-skills-catalog-lock.ps1 -Check
git diff --check
```

Production smoke 會用目前 clean pinned commit 安裝 temporary Codex Home，透過 real immutable archives 對 disposable target 執行兩次 bootstrap，先套用 temporary USER Skills，再驗證 consumer Instructions manifest、零共用 Skill entries、USER bytes 不變、project Skill 保留、exact bytes、clean status、unchanged HEAD/index 與 stable `PersonalAgent` evidence：

```powershell
.\scripts\test-syp101-production-smoke.ps1
```

既有 runbook 的 `.\scripts\test-production-cutover.ps1` 仍保留為相容入口，並轉交同一份 SYP-101 smoke。

Required CI 仍只在 Windows 最新穩定 PowerShell 7 執行 regression、production lock 與 production smoke；一般 pull request 只執行 Windows Core 與 Windows Install Smoke，另有 workflow_dispatch 手動三平台診斷 workflow，且其結果不代表三平台 required 驗證。

## 授權

本 Repository 自行撰寫且明列於 [逐檔範圍表](licensing-scope.json) 的通用核心採 [Apache-2.0](LICENSE)。這不是涵蓋全部檔案、歷史版本或外部 Skill source 的統一授權；八個待確認模板／歷史規劃檔不在本次授權範圍。

請一併閱讀 [授權範圍](LICENSE-SCOPE.md)、[NOTICE](NOTICE)、[來源說明](PROVENANCE.md) 與 [外部來源聲明](THIRD_PARTY_NOTICES.md)。四個 Skill Repository 為同源拆分、分別維護的來源，其版本授權由各自文件說明。

Runtime／Instructions／選取的 Skill 會遞送來源版本的授權文件、來源路徑與 hash 收據，並納入既有受管 inventory。詳見 [授權文件遞送](docs/license-delivery.md)。既有舊 pin 若沒有授權聲明，會明確提示缺失；不會套用中央來源的新授權。

## 主要檔案

- `scripts/install-ai-instructions-bootstrap.ps1`：transactional installer、v1–v5 configuration migration 與 Windows V3V5 opt-in gate。
- `scripts/installer-safe-mutation.psm1`：installer stable-file 的 handle-bound mutation 與目錄 guard。
- `scripts/bootstrap-ai-instructions-installed.ps1`：stable launcher、更新前後 runtime validation。
- `scripts/ai-instructions-runtime-contract.psm1`：config v4／v5、bundle v2／v3、platform gate 與 exact inventory 契約。
- `scripts/ai-instructions-updater.psm1`、`scripts/update-ai-instructions.ps1`：更新 workflow 與 installed command。
- `scripts/agent-environment-reconciler.psm1`、`scripts/update-agent-environment.ps1`：使用者層級 Catalog Skills transaction、recovery 與 verified-runtime reconciliation 入口。
- `scripts/bootstrap-ai-instructions-multisource.ps1`：Catalog selection、immutable acquisition 與 composition。
- `scripts/bootstrap-ai-instructions.ps1`、`scripts/agent-artifact-remediation.psm1`：manifest protection、tracked reserved artifact 自癒、local ignore、recovery evidence 與 rollback。
- `scripts/ai-instructions-rollout.psm1`、`scripts/invoke-ai-instructions-rollout.ps1`：fixed-drive Repository discovery、逐 Repo bootstrap、post-scan 與結構化 rollout report。
- `scripts/cleanup-ai-instructions-pollution.ps1`：舊 runtime 使用的明確授權 tracked pollution 診斷／cleanup。
- `catalog/`：schemas、examples、Catalog、source pins 與 Lock。
- `tests/`：PowerShell 7 Pester suites；目前 required CI 的實際平台範圍如上所述。
