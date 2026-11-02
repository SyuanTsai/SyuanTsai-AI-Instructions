# SYP-354：共用平台模組與 installer 跨平台設計

## 1. 需要使用者核准的決策

- **A1：Unix mutation 的保證邊界。** 建議採 Standard §8.4 已允許的 cooperative advisory lock，加 directory-relative no-follow 操作、身分重驗、private staging 與 applied-state recovery；所有 updater、launcher、bootstrap、reconciler 與 recovery 都遵守同一鎖協定。它不能等效阻止同帳號、不遵守鎖的惡意 writer。遇到需要此強度的工作，應在隔離帳號／外部 sandbox 或受保護 broker 中執行，否則 fail closed。替代方案是 Unix 一律要求外部隔離，安全邊界較強，但增加一般本機安裝成本。不得以重驗取代強制互斥並宣稱完全等效。
- **A2：平台實作與分發方式。** 建議公開單一 `scripts/platform-runtime.psm1` façade，內含 Windows／Linux／macOS adapter；檔案與鎖使用 C# P/Invoke，Unix 程序啟動使用小型、經 authority inventory 綁定的 native supervisor。替代方案是維持受驗證外部工具組合，但 macOS 的 session 建立、精確 process identity 與 ABI 探測仍需 helper，且工具 dependency closure 更大。S3 可先實作已有 Standard 授權的 runner 能力；本提案的 installer 接線需核准。
- **A3：預設 projection 與專案層啟用。** 建議 USER 同時管理 `~/.agents/skills` 與 `~/.claude/skills`；`~/.copilot/skills` 預設關閉、明確選用。三個合法 project roots 都提供相同 API，但由明確 project opt-in 啟用，consumer bootstrap 預設仍為 Instructions-only，不因 USER 缺件而回退 REPO。替代方案是明確選擇 AI 後只安裝其所需 USER projections；仍須支援所有 Standard locations，不能把缺少 host 當成刪除其他 projection 的授權。
- **A4：契約採版本化遷移。** 建議採 §6 的 Catalog／Lock v3、USER manifest v3、managed manifest v4、runtime bundle v3、sync config v5 及新 recovery journal；新 reader 先上線，再啟用新 writer。替代方案是維持 Catalog v2，把多位置規則放在獨立、同樣 pinned 的 projection contract，但須明確保留 v2 `targetPath` 的原義，不能直接 reinterpret。版本號為本提案，不是既有 schema。
- **A5：Instructions 同源產生。** 建議由共通語意來源加受限 host adapter 產生 Codex、Copilot、Claude 輸出；以 machine-readable invariant／route parity 驗證共同規範，host-specific 掛載與路徑可不同。替代方案是三份完全相同正文並使用共同規則路徑，生成較簡單，但須先驗證每個 host 的實際載入能力。Skills 的完整 package bytes 則一律相同，不適用此文字差異例外。
- **A6：雲端 setup 與預設權限。** 建議以無互動 setup script 在使用者可寫的 physical root 安裝經驗證的 portable pwsh，再呼叫同一 installer／updater；新 private directory 為 `0700`，data／journal 為 `0600`，需要執行的 launcher 為 `0700`。不自動改 shell profile 或取得系統權限。替代方案是平台管理者預建受驗證映像與 runtime；setup 只驗證及使用映像中的實體執行檔。

**主控決議（2026-11-03，使用者指示 SYP-350 期間免人工核准，由主控決定）：**

- A1、A3、A4、A5、A6：採用上列建議方案。
- A2：採用單一 `scripts/platform-runtime.psm1` façade 與三平台 adapter，**不另建置或分發獨立 native supervisor 執行檔**。Unix 的檔案、鎖與程序啟動以 C# P/Invoke 直接呼叫 libc（例如 `openat`／`O_NOFOLLOW`、`fstatat`、`flock`、`renameat`、`posix_spawn` 搭配 `POSIX_SPAWN_SETPGROUP`），以 process group 加 PID／啟動時間身分驗證滿足 D2；理由是獨立 native binary 會引入需逐平台建置與審查的工具鏈及分發面。若某平台的 libc 能力經實測不足以達成 fail-closed 保證，該能力以 typed failure 拒絕，並在對應 Step 記錄，不以未驗證的替代方式放寬。

**已核准且不重開決策：** D2 為 macOS process group／session 加 PID／啟動時間驗證，強隔離交外部 sandbox；D3 拒絕 symlink、Windows reparse／junction 及一般檔案多重 hard link；D4 Unix environment 只改 process scope，持久化另給手動指引；D5 共用抽象由本 Repository 以 authority pin 分發。

本文件是待核准的實作設計，不修改 normative Standard，也不宣稱三平台驗收完成。程式碼基線為本 checkout 的 `f5952f5484b2426451f687c4d162719d67786563`；以下 `檔案:行號` 是此基線的定位。已讀指定 installer、三支 bootstrap、reconciler、migration、runner、contract、Catalog schemas 與 README，並追查直接相依的 updater、resolver、remediation 與 workflow。

**來源缺口：** 此 checkout 找不到 `docs/delivery/syp-351/cross-platform-inventory.md`，tracked inventory 與 `licensing-scope.json` 也沒有該項；因此未聲稱已核對其逐腳本盤點或授權分類。本文改以實際程式碼建立證據，授權清單暫比照現有 `docs/delivery/syp-214/README.md` 的 `Apache-2.0`，待該報告可用後交叉核對。任務提及的 Instructions 同源規則在目前 Standard **§4.2**；目前 **§4.4** 是 required package files，兩者均已核對。

## 2. 現行 Windows 保證清單

以下區分 installer、USER／REPO lifecycle 與中央 runner。這是靜態程式證據，不是本次重新執行 Windows 測試的結果；不能把單一 helper 的保證擴大到所有 caller。

| ID | 現行保證及限制 | 程式位置 |
| --- | --- | --- |
| W01 | Stable file 以 `CreateFileW` 取得讀寫／delete handle，僅允許 `FileShareRead`，拒絕並行 write/delete；新檔使用 `CreateNew`。寫入在同一 handle 讀取原 bytes、比較、寫入、flush、readback。這是 handle-bound 更新，並非整檔 rename 的 crash atomicity。 | `scripts/installer-safe-mutation.psm1:251`、`:273`、`:299`、`:716`、`:728` |
| W02 | Target-root 與中間 directory 以 `FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT` 開啟，允許 read/write share、禁止 delete share；transaction 持有 Codex Home／hooks、staging／backup guards，阻止受 guard 保護的 parent rename／junction swap。開檔後核對 final path。 | `scripts/installer-safe-mutation.psm1:191`、`:473`、`:515`；`scripts/install-ai-instructions-bootstrap.ps1:527`、`:598` |
| W03 | Preflight 逐祖先檢查型別與 reparse；mutation handle 驗證非 directory、非 reparse、`NumberOfLinks == 1`，避免 hard-link alias。Installer 已持有的 install lock 路徑在一般 file ownership probe 有特例，不能說所有鎖都經同一 link-count 檢查。 | `scripts/install-ai-instructions-bootstrap.ps1:85`、`:109`；`scripts/installer-safe-mutation.psm1:230`、`:553` |
| W04 | Read-only file 透過 attribute handle 暫清屬性，重新開 write handle 後比較 volume／file index 身分；完成或失敗還原屬性。Delete 經 `SetFileInformationByHandle` 標記 delete-on-close。 | `scripts/installer-safe-mutation.psm1:323`、`:437`、`:464`、`:588`、`:825` |
| W05 | Installer 記錄 original／applied bytes；apply 比較 original，rollback 只還原仍等於 applied bytes 的檔案，保留外部變更。新檔 rollback 同樣先比較再刪除。記憶體 transaction state 本身不是持久 journal。 | `scripts/install-ai-instructions-bootstrap.ps1:316`、`:337`、`:360`；`scripts/installer-safe-mutation.psm1:754`、`:840` |
| W06 | Runtime 先 staging／驗證，舊 runtime 搬至 backup，再安裝 candidate；例外先 quarantine，只有 inventory／candidate identity 完整一致才刪除失敗 runtime；無法安全 rollback 則保留 backup。多個 move／stable-file 更新不是單一跨檔原子交易。 | `scripts/install-ai-instructions-bootstrap.ps1:582`、`:621`、`:642`、`:655`、`:678`、`:724` |
| W07 | Per-Codex-Home update lock 排除並行 updater，獨立 install lock 排除 manual install／swap；launcher shared read lease 保護 runtime 使用期間。Updater 持 install-state lock 完成 preflight／acquisition，交 installer 前釋放；installer 取得鎖後重驗 current commit 與 mode/channel/ref，避免過期核准。 | `scripts/ai-instructions-updater.psm1:362`、`:381`、`:388`、`:495`；`scripts/install-ai-instructions-bootstrap.ps1:530`、`:542`、`:565`；`scripts/bootstrap-ai-instructions-installed.ps1:317`、`:395` |
| W08 | Immutable Git objects 匯出 source snapshot，或以 archive hash／安全解壓取得來源；installed launcher 在載入 runtime module 前驗證 config、bundle、stable reference 及完整 inventory。缺件、額外檔案或 hash drift fail closed。 | `scripts/install-ai-instructions-bootstrap.ps1:211`、`:384`、`:416`；`scripts/bootstrap-ai-instructions-installed.ps1:116`、`:161`、`:215`、`:267`；`scripts/bootstrap-ai-instructions-multisource.ps1:273` |
| W09 | REPO operation lock 序列化 common Git metadata；active index 使用原生 create-only `index.lock`；exclude 透過受保護 handle 合併 live worktree manifest 精確 paths，CAS rollback 保留外部變更。Publication 另有 identity、DACL、read-only、stage／tombstone journal 驗證。 | `scripts/bootstrap-ai-instructions.ps1:1494`、`:1508`、`:1703`、`:1730`、`:1837`、`:2493`、`:2626` |
| W10 | USER reconciler 先驗證 desired state，再持 user-scope global lock，保護 manifest、backup、journal 與 recovery；不接管未知個人 Skill。其現行檔案更新是 path 檢查加 temporary file／`Move-Item`，不具 W01 全套 handle 強度。 | `scripts/agent-environment-reconciler.psm1:234`、`:259`、`:406`、`:657`、`:743`、`:951`、`:1082` |
| W11 | Legacy REPO Skills 只有 ownership、完整 inventory/hash、ignored/untracked、可信 USER inventory 全部吻合才列為可移除；tracked/staged/customized 保留；mutation 前再驗 Git／USER evidence。Reserved remediation 明確排除 Skills。 | `scripts/repo-shared-skills-migration.psm1:189`、`:224`、`:284`；`scripts/agent-artifact-remediation.psm1:115`；`scripts/bootstrap-ai-instructions-multisource.ps1:290` |
| W12 | 中央 runner 的 trusted-supervisor RSA attestation 驗證 candidate、核准、publish/install 與 post-install inventory 綁定；不是 `install-ai-instructions-bootstrap.ps1` 直接提供的本機 installer 簽章保證。現行 updater 的模式／channel 檢查也不能冒稱 RSA approval。 | `scripts/Invoke-StandardValidation.ps1:958`、`:975`、`:7588`、`:7626`、`:7709`、`:7817` |
| W13 | Windows runner／Pester shard 使用 kill-on-close Job Object，bootstrap 在加入 Job 前等待 release；hidden／`CreateNoWindow`、環境 allowlist、bounded timeout／output 與 owned descendant cleanup。Shard 有 PID＋start time evidence。 | `scripts/Invoke-StandardValidation.ps1:3731`、`:3834`、`:3911`；`scripts/Invoke-PesterShardProcess.ps1:320`、`:355`、`:1059`、`:1622`、`:1637` |

補充現況：`README.md:5`、`:96`、`:313` 仍記 Windows-only；`ai-instructions-contract.json` 只列 Codex／Copilot，並保留 `base.windows-only-local-runtime`。這些是尚待 migration 的 runtime 契約，不覆蓋新版 Standard。`Invoke-PesterShardProcess.ps1:25` 仍硬性拒絕非 Windows；validator 則已有 `setsid`、`unshare`、`/proc`、`prctl` subreaper 分支（`:3458`、`:3758`），不能因此宣稱 macOS 已支援。Core-only 分支目前只有 process group，Linux 尚需補足 §8.4 的額外 containment。

## 3. 共用平台模組設計（D5）

### 3.1 Owner、分發與可信載入

建議新增 `scripts/platform-runtime.psd1`／`scripts/platform-runtime.psm1` 作唯一公開入口，實作放在 `scripts/platform/`：`PlatformNative.cs`、`Windows.psm1`、`Linux.psm1`、`MacOS.psm1`；native supervisor source 放在 `scripts/platform/native/`。名稱均為提案。經 review 的 build recipe、RID-specific helper asset 及其 hash 要隨 authority bundle inventory 綁定；不從 consumer 的 PATH 尋找同名 helper，不在 consumer 現場下載未綁定 binary。

Authority commit、bundle hash、實際使用的完整 file inventory 依 Standard §3.2／§3.4 驗證；host adapter 只選能力與參數，不重定義 policy。Installer runtime bundle 必須包含實際需要的模組 closure。既有 `installer-safe-mutation.psm1` 公開函式可暫作 wrapper，將 Windows 已有行為留在共用 Windows adapter；完成 regression 後才移除重複 native code。

**Bootstrap trust cycle：** stable launcher 必須保留最小 preflight，不可先 import 未驗證的 platform module 再用它驗自己。由已可信 installer／launcher 內嵌的最小 verifier 建立安全 handle／lease、驗證完整 bundle 後才 import；verifier 的 native 部分亦屬 stable inventory，與 launcher 同交易更新。首次 cloud bootstrap 由 pinned setup／預建映像提供最初 trust anchor。不能用 candidate 提供的 hash 自我授權。

### 3.2 呼叫模型與可行性

API 回傳可 `Dispose()` 的 lease/context，不只回傳字串。共同 evidence 含 `apiVersion`、OS／architecture、filesystem capability、authority binding、`lockPrimitive`、`isolationCapability`；檔案身分含 Windows volume/file ID 或 Unix device/inode，程序含 PID／start identity。Journal 可序列化 observation，但不能序列化 handle 後當成重啟後仍有效；recovery 必須重新開啟及驗證。

PowerShell 7 透過 `Add-Type` 載入受驗證 C#，以 `DllImport`／`NativeLibrary` 接 native API，使用 `SafeHandle` 管理 fd／HANDLE、`SetLastError` 及明確 errno mapping。`.NET 8+` 是建議的最低 runtime API 基線；不是所有 PowerShell 7 版本都建立在 .NET 8 上，preflight 需同時檢查兩者。實際 canonical CI 仍依 Standard 取得最新穩定 PowerShell 7，不能把最低版本當成 latest-stable 證據。

Linux libc 與 macOS libSystem 的 flags、`struct stat`、alignment、`off_t`／時間欄位、x64／arm64 ABI 不可共用硬編碼 layout。建議把 ABI-sensitive stat／process 查詢收斂至小型 native shim，公開固定寬度資料結構；P/Invoke 薄層仍負責 fd 操作。可先驗證每個支援 RID 的 C# layout，若無法可靠驗證則改用 shim，不能跳過 `st_nlink`。未知 ABI、filesystem 或 native symbol 缺失回傳 capability failure，mutation 前停止。此技術方案尚未在 Unix host 實測。

### 3.3 公開函式與三平台實作

表中 R 指 S3 中央 runner（validator／authority gate／Pester shard），I 指 S4 installer、bootstrap、reconciler／recovery。參數是擬定 contract，不是現行可執行命令。

| 公開介面與輸出 | Windows | Linux | macOS | 使用者／失敗行為 |
| --- | --- | --- | --- | --- |
| `Get-PlatformCapabilities -Required <set>` → capability receipt | 探測 Win32 file ID、Job、filesystem／ACL | 探測 libc、filesystem、flock、subreaper／namespace | 探測 libSystem、filesystem、flock、session／process identity | R/I；實際測試後才能標 available；未知必需能力即拒絕 |
| `Open-PlatformDirectory -Root -RelativePath -CreatePrivate` → directory lease | 逐祖先 no-reparse handle，deny-delete，核對 final path | 從已驗證 anchor 逐段 `open/openat(O_NOFOLLOW\|O_DIRECTORY\|O_CLOEXEC)`；`fstatat(AT_SYMLINK_NOFOLLOW)`／`lstat`，新段 `mkdirat` | 同 directory-relative API，使用 Darwin flags/layout | R/I；禁止 `..`、空段、absolute child；任何 ancestor symlink 拒絕，包含 dangling link |
| `Open-PlatformFile -ParentLease -Leaf -Access -CreateMode` → file lease | `CreateFileW`、`OPEN_REPARSE_POINT`、CreateNew／OpenExisting、deny-write/delete | `openat` 加 `O_NOFOLLOW\|O_CLOEXEC`，create-only 用 `O_CREAT\|O_EXCL`；先不 truncate，開後 `fstat` 驗 regular | 同 Linux、Darwin ABI | R/I；先核對 identity/type/link count 再讀寫，不跟隨 link |
| `Assert-PlatformFileIdentity -Lease -Expected -SingleLink` → observation | `GetFileInformationByHandle`，volume／file index／NumberOfLinks | `fstat` 比 dev/inode/type，regular file `st_nlink == 1`；對照 parent 名稱的 `fstatat` | 同 Linux | R/I；目錄不套用 nlink=1；驗證前後 alias／identity 改變均停止 |
| `Enter-PlatformLock -ParentLease -Leaf -Mode Shared/Exclusive -Timeout` → lock lease | 保留 FileShare Read／None 協定及 handle identity | `openat` 安全 lock file＋`flock(LOCK_SH/LOCK_EX\|LOCK_NB)`、deadline retry | 同 flock 協定 | R/I；不依賴 Unix FileShare；不可混用 flock/fcntl 卻假定互斥 |
| `Publish-PlatformFile -ParentLease -StageLease -ExpectedState -NoReplace -Journal` → publication receipt | 既有 handle-bound rename／stage/tombstone 及 DACL preservation | 同 filesystem `renameat` replace；no-replace 需 `renameat2(RENAME_NOREPLACE)` capability | `renameat` replace；no-replace 需 `renameatx_np(RENAME_EXCL)` capability | R/I；rename 前後重驗及 journal；no-replace 不可用即停，不以先 Test-Path 再 rename 模擬 |
| `Remove-PlatformOwnedFile -ParentLease -Leaf -ExpectedState -Journal` | handle delete-on-close | 經驗證名稱移至 private tombstone，再 `unlinkat`，每步核對 ownership | 同 Linux | I，R 用於 owned artifacts；unlinkat 不是 fd-bound conditional delete，A1 限制必須可見 |
| `Get/Set-PlatformPermissions -Lease -Policy/-Snapshot` | 既有 DACL／read-only 以 handle 取得與還原 | `fstat` uid/gid/mode、`fchmod`；需要 ACL 時 native ACL API | `fchmod` 及 Darwin ACL adapter，必要時核對 flags | R/I；禁止 chmod 遞迴接管未知檔案；不能保留既有 ACL／flags 即保留原件、fail closed |
| `Start-PlatformOwnedProcess -ExecutableLease -ArgumentList -Environment -Deadline -IsolationRequirement` → process lease | Job Object＋release handshake，hidden／CreateNoWindow | native supervisor 先建立 session/process group，再設 subreaper；或通過 probe 的 PID namespace／cgroup | native supervisor `setsid/setpgid`，以 libproc 或經驗證 native 查詢取得 PID、PPID、start identity | R；無互動 terminal、清空 inherited env 後 allowlist；不可在多執行緒 CLR 內自行 fork 後執行 managed code |
| `Stop-PlatformOwnedProcess -Lease -GracePeriod -Deadline` → cleanup receipt | TerminateJobObject、wait、identity-checked observation | group TERM→KILL、subreaper `waitpid`／namespace/cgroup ownership 檢查 | group TERM→KILL、逐 PID/start identity 驗證及等待 | R；alive/unknown 都不是 cleanedUp；PID reuse 不可誤殺，強隔離要求無法滿足則不啟動 |
| `Resolve-PlatformPowerShell -Policy -DestinationLease -OfflineCache` → verified runtime | 官方 Windows asset、SHA-256、實體 `pwsh.exe` | 官方相符 OS/architecture asset、安全展開、實體 `pwsh`、執行權限 | 官方 macOS 相符 asset、同 Linux | R/I setup；解析最新穩定版與下載 identity 在一次 run freeze；離線僅接受 policy 允許且完整驗證 cache |
| `Initialize-PlatformPester -Policy -RuntimeReceipt -DestinationLease` → module receipt | 共用 package payload／manifest／closure 驗證 | 同 Windows；以實體 module path import | 同 Linux | R；接入既有 resolver，區分 regression Pester 4.10.1 與 formal gate approved latest-stable，不自行升版混用 |
| `Set-PlatformProcessEnvironment -Name -Value` → scope receipt | 明確 Process scope；持久化若需要由 caller 另行授權 | `[Environment]::SetEnvironmentVariable(..., Process)` | 同 Linux | D4 預留；只提供手動持久化說明資料，不實作 Atlassian、不修改 profile、不回傳 secret value |

`Publish-PlatformFile` 的 crash-safe 流程為：安全建立同 filesystem stage → 寫完 bytes、驗 hash／metadata、`fsync(file)` → durable journal → publication rename → `fsync(parent)` → readback／journal finalize。舊 inode 需要 backup 時，以獨立 copy 或 journal tombstone 保存，禁止用 hard link 備份。`renameat` 不提供 compare-and-swap；ExpectedState 比較與 rename 的結合只在遵守鎖的 participants 間成立。`EXDEV`、directory fsync 不支援、ACL 無法還原等情況須明確失敗，不能悄悄改 copy/delete。

### 3.4 路徑、鎖及程序的安全界線

Directory fd 防止後續操作被換成 symlink 而重新導向，但不能阻止 Unix 上原 directory 被有權者搬走；祖先／parent 名稱與 fd 身分必須在 publication 前後重驗。偵測搬移後停止，保留只屬於該交易的 evidence，不對新占用同名路徑的物件做補償刪除。若要求「惡意同 UID 即使在最後檢查後動手也絕無錯誤變更」，僅 dirfd、chmod 0700、flock 不足；須 A1 外部隔離。不得將 post-check 描述為消除所有 TOCTOU。

鎖檔必須是固定 inode 的普通單 link 檔案；正常 release 只 unlock/close，不 unlink 後重建，否則新舊 inode 可各自持鎖。lock receipt 記錄 primitive、owner PID/start、transaction ID，PID 僅作診斷，不用 PID 判定後強拆活鎖。Git `index.lock` 是例外：它是 Git 自有 create-only presence protocol，應用 `O_EXCL` 保留該協定，不能以 flock 取代。

既有鎖順序需在接線前依 caller graph 固定：updater 先 update lock 再 install-state lock，交 installer 前釋放後由 installer重驗；runtime user 持 shared install lease，涉及 USER Skills 時再取 user global lock。REPO 路線將 USER migration lock、repository operation lock、index.lock 的取得順序收斂為單一順序並測試；不增加任何反向 acquisition。多 root projection 以同一 USER coordinator lock／journal 管理，不因 `CODEX_HOME` 不同而各自寫共用 Skills。

S3 對接：`Invoke-StandardValidation.ps1` 與 `Invoke-PesterShardProcess.ps1` 使用所有 R primitives，移除 duplicated Job／Unix containment；`Invoke-StandardAuthorityGate.ps1` 使用安全 temporary roots、runtime/tool/Pester receipts 及 process API。`Resolve-StandardValidationTool.ps1` 的安全工具 closure、launcher 與 Pester preparation 也要委派共用模組。不能只移植最外層三支 runner 而保留底層 Windows-only gate。

Linux 預設採 process group＋專用 supervisor subreaper；經 probe 可改為 PID namespace 或 cgroup，evidence 依實際機制寫 `linux-process-group-subreaper`、`linux-pid-namespace` 或對應 cgroup 名稱。macOS 使用 `macos-process-group`，Windows 使用 `windows-job-object`。macOS 無 Linux subreaper，daemonize/setsid 逃逸與 supervisor 突然死亡不能靠 polling 宣稱完整 containment；不可信 candidate 必須在平台提供的無 secrets、低權限外部 sandbox 執行。可信 fixture 的 group cleanup 仍須確認所有可證明 owned descendants 退出；無法確認時 `cleanedUp=false`。

## 4. 逐項等效設計與測試

| 對應 | Linux／macOS 設計及保證差異 | 驗收方法 |
| --- | --- | --- |
| W01 | no-follow file lease＋global/cooperative locks，寫入改走完整 stage publication；沒有 Windows deny-write/delete 強制分享語意 | 兩個獨立 pwsh writer 爭鎖；讀者只能見完整 publication；不遵守鎖的 writer 用來證明限制，不能把測到偵測成功當作強制互斥 |
| W02 | 逐段 dirfd，所有後續操作 `*at` relative；parent 被改名不導向新 symlink，但不能禁止改名 | root、中間 parent、leaf swap barrier；outside sentinel 不受跟隨連結寫入；搬移導致 identity mismatch 時失敗並保留 evidence |
| W03 | `lstat/fstatat` 不跟隨 link，開後 `fstat` regular/nlink=1，所有安全路徑含 lock／journal／trust anchor 一致採用 | leaf/ancestor/dangling symlink、hard link、FIFO/socket/device、alias 在 preflight 後出現；mutation 前失敗，檢查原檔 bytes 不變 |
| W04 | snapshot uid/gid/mode/ACL/必要 flags；fd 操作 metadata；delete 用 private tombstone 協定 | readonly、不可寫 parent、extended/default ACL、flags；rollback 還原允許保留的 metadata，unsupported 不做部分接管 |
| W05 | durable journal 記 original/applied bytes hash、length、identity、metadata 與 generation；僅 expected applied state 還原 | 每步 failpoint、外部 concurrent edit、刪後重建同 bytes／不同 inode；保留新檔，不以 hash 相等取代 ownership |
| W06 | runtime directory 同 filesystem stage／backup／quarantine，install lock 下完成 swap，journal 記各 rename 階段；跨檔 transaction 是 recoverable，不是全域原子 | SIGKILL 注入 swap 前後、config 更新前後；下次 launcher 對 mismatch fail closed；recovery 驗完整 inventory 後才還原或清除 |
| W07 | shared/exclusive flock 保留兩種鎖及 read lease；鎖內重驗 candidate／policy，lease 不可跨 exec 意外洩漏 | manual/updater/launcher 三程序競態、兩 CODEX_HOME、approval 撤回、timeout、lock substitution、owner crash 後再取鎖 |
| W08 | 相同 immutable source/archive/hash contract；source 讀取與 safe extraction 亦經 no-follow API，拒絕 archive links／unsafe names | 缺／多檔、hash drift、ZIP/TAR traversal/link、source snapshot substitution；module side effect marker 必須證明未在失敗前執行 |
| W09 | common Git operation flock＋原生 index.lock，exclude parent dirfd、publication journal 與 live worktree union | linked worktree 並發、外部 git add、exclude custom bytes、malformed marker、branch/HEAD/index 保留；正常同步不 commit，remediation 測試僅在 disposable fixture |
| W10 | reconciler 每個 write/delete/backup/journal 改用同一安全 API；跨 projection coordinator 加 final manifest commit record | 兩 updater 同時更新、WhatIf 零 mutation、半完成 journal 阻止 apply、未知個人 Skill 保留、recover 再執行冪等 |
| W11 | 既有 ownership/hash/Git/USER evidence 延伸為 projection-aware；舊 REPO 清理仍只針對有證據的 legacy paths | USER projection 缺件／較舊／多檔、tracked/staged/customized 全保留；不可因新增 Claude 路徑推論其為可刪舊副本 |
| W12 | 以 `.NET RSA.Create()`／ImportParameters、SHA-256 與明確 PKCS#1 padding 保持既有 wire payload；安全開 trust anchor；不更換簽章語意 | Windows 簽署 fixture 跨平台驗證及反向驗證、Unicode/canonical payload、錯 candidate、錯 key、payload tamper、unsigned evidence 一律拒絕 |
| W13 | Windows Job 不降級；Linux group＋subreaper/namespace/cgroup；macOS group/session＋PID/start identity；都不提供 filesystem isolation | grandchildren、短命 parent、double-fork、setsid、PID reuse fixture、timeout/cancel、超量輸出、supervisor crash；未完整回收不可 PASS，需強隔離時驗 external sandbox |

以上涵蓋現行保證的移植目標，也明列現行 helper 強度不一致之處。對於 Windows handle 強制互斥沒有 Unix 原生等價的項目，驗收必須同時核對使用前提，不能只驗 happy path。

## 5. 安裝位置與輸出

### 5.1 Runtime 與 Skill projection

| 範圍 | 位置／用途 | 建議行為 |
| --- | --- | --- |
| Runtime owner | `CODEX_HOME`；未設定時 `~/.codex`，含 hooks、runtime、config、update receipts／locks | 保留名稱避免打斷既有入口；三 AI 共用 installer engine，Claude 不需先安裝 Codex 應用程式 |
| USER shared Skills | `~/.agents/skills/<skill-id>` | Codex／Copilot 共用，維持現有管理位置 |
| USER Claude | `~/.claude/skills/<skill-id>` | 與 shared Skills 由同一 source pin／inventory 產生實體 copy |
| USER optional Copilot | `~/.copilot/skills/<skill-id>` | 預設不額外複製；明確 opt-in 並驗證 host discovery／重複載入問題 |
| Project opt-in | `.agents/skills/<skill-id>`、`.claude/skills/<skill-id>`、`.github/skills/<skill-id>` | 支援全部 roots 的 versioned projection；不變更 project-owned/tracked Skills，不作 USER fallback |
| USER Instructions | 既有 `CODEX_HOME/AGENTS.md` bootstrap section；擬新增 `~/.claude/CLAUDE.md` managed section | 共通規範同源，保留個人 section；Copilot USER Instructions discovery 尚未驗證，不另發明全域檔名 |
| REPO Instructions | `AGENTS.md`、`.github/copilot-instructions.md`、新增 `CLAUDE.md`，及其生成 rule paths | 相同 canonical revision 產生，追蹤來源與 output hash；依 host adapter 載入條件式規則 |

Skill content hash 依 canonical package relative paths 計算，不包含 host prefix；每個 projection 都保存相同完整 package bytes/per-file SHA-256，包括 binary resources、選用 adapter metadata 與相同 license delivery payload。不得換行轉換、模板化 Skill 正文、以 symlink 或 hard link 節省空間。Filesystem execute mode 屬明確 metadata policy，不能藉 chmod 修改 package bytes；需要保留 source executable bit 時，須把該 metadata 納入契約與驗收。

各 projection 的 lifecycle 狀態獨立記錄，但同一選定 source revision 的 publish 必須一起驗證。跨 root／跨 filesystem 無單一 atomic rename：各 target 在同 filesystem staging，coordinator journal 記 prepare/apply/verify/finalize；全數成功才發布新 manifest generation，否則 rollback 或 recovery-required。外部 AI reader 不一定遵守此鎖，因此不能承諾所有 AI 同瞬間看見一致版本；建議在 host 未執行 Skill 的維護時段更新，並在完成前阻止本 runtime 宣稱 ready。這是 A3 應接受的限制。

### 5.2 Instructions 同源、保留路徑及 ignore

共通語意先維護繁體中文，再產生英文與三 host 輸出；新增 Claude platform 至 `ai-instructions-contract.json`，並同步兩語系、各 route/invariant 及 parity regression。共同規則的限制與例外必須一致；平台專屬 connector 能力仍只能放對應 adapter，不憑空複製到 Claude。提案可將共同內容放 `instructions/common/`，生成現有 `.codex/`、`.github/` 與新 `.claude/` authority artifacts；路徑與生成器需 A5 核准後才建立。

REPO reserved inventory 加入精確 `CLAUDE.md` 及受管的 Claude Instructions/rule files；`.git/info/exclude` marker 僅加入該 worktree manifest 的實際 targets，再合併其他 live worktree manifests。不可用整個 `.claude/**` wildcard 隱藏使用者設定。Instructions output 可有 host-specific 路徑，manifest 記 canonical source identity／renderer identity／output hash；parity 比較規範語意，不能只比三份檔案 byte hash。

所有 Skill roots——既有 `.agents/skills/**`、`.codex/skills/**`，以及新增 `.claude/skills/**`、`.github/skills/**`——明確排除 reserved Instructions remediation。Project opt-in 管理的 exact Skill files 可以 local-ignore，但不因路徑名或同 hash 接管既有 tracked/staged/unmanaged 檔案。新 `CLAUDE.md` 若已有內容，先依 ownership 分類、備份及產生可 review 的遷移結果，不擴張既有自動刪除範圍。後續若變更 reserved lifecycle policy，須先依 Repository 規範更新 authority/tests；本設計不授予刪除任何 consumer 檔案的操作權。

## 6. Schema 影響與相容策略

目前 JSON schemas 多數 `additionalProperties: false`；新欄位不能直接塞回舊版本。Catalog v1/v2 readers、USER manifest v1/v2、REPO manifest v2/v3 與現行 bundle/config 需分開評估。

| 契約 | 實際現況／證據 | 建議版本與變更 |
| --- | --- | --- |
| Catalog／Lock | `skills-catalog-v2.schema.json:70`、`:74` 及 `skills-catalog-lock-v2.schema.json:29`、`:33` 的單一 `targetPath` 固定 `.agents/skills/<id>`；source 已可用 `skills/<id>`。compatibility enum 已有三 OS，單純支援 OS 不需為 enum 升版 | v3 將 source identity 與 `projections` 分開；projection 採受限 ID／scope／host/root key，不允許任意絕對 destination。Lock 固定 canonical hash 與已核准 projection contract/hash；source pin 不因新增 host 重解或移動 |
| USER managed manifest | `user-skills-managed-manifest-v2.schema.json` 把 target 與 license delivery patterns 綁 `.agents/skills`；reconciler `:494` 亦 exact-check | v3 增 projection ID、scope/root binding、generation、canonical source identity、每位置 files/hash；完整 license payload 與 sourcePath 規則同步。單一 USER coordinator manifest 記所有 USER projections |
| REPO managed manifest | `managed-manifest-v3.schema.json:13` 已有 sourcePath/targetPath/provenance，schema path 本身較通用；但 bootstrap whitelist 與 marker 邏輯未涵蓋 Claude | 若只新增一個 instruction target，schema 形狀未必需升版；本提案因增加 generated-source／renderer provenance、projection/scope/generation，採 v4。不能僅放寬 regex 宣稱完成 migration |
| Runtime bundle | `runtime-bundle-v2.schema.json:7` 綁 commit、archive、inventory；`bootstrap-ai-instructions-installed.ps1:215` strict v2 | 單加 file inventory 可留 v2；本提案為 platform module ABI、required capabilities、RID/helper closure、projection contract identity 採 v3。仍使用 exact inventory，不能省略未執行卻可載入的 dependency |
| Sync config | `ai-instructions-sync-v4.schema.json` 不容納新 projection selection；既有 exclusions/update mode 是使用者設定 | v5 明確 USER/project projection selections、受限 scope 及 default migration；保留 exclusions/mode/channel/ref，不默默授權 auto-install 或把所有 project 啟用 |
| Recovery journals | Bootstrap 有 publication journal/version checks（`bootstrap-ai-instructions.ps1:2626`、`:3909`）；USER recovery 用現有 schema 及 exact properties（`agent-environment-reconciler.psm1:951`、`:1103`） | 各 owner 升其下一版：Unix identity/permission snapshot、lock protocol、projection generation、stage/tombstone/state；先核實現行 reader inventory 再定精確版本。不可把 Windows DACL 欄位塞 mode 字串 |
| Source pins | `skills-catalog-sources.schema.json` v1 綁 immutable commit/version，沒有 target | 若不新增欄位維持 v1；D5 authority module 由 authority inventory 分發，不能混成新共享 Skill source 或任意改 production pins |
| AI Instructions contract | `ai-instructions-contract.json:15` 起只列兩平台，仍有 Windows-only invariant | 新增 Claude 與三平台 invariant／generated artifact contract；只新增可表達欄位時可維持 v1，若改 base/source 語法則升 v2並同步 strict reader/tests；此處建議生成器方案採 v2 |
| Runner evidence／policy | Process result／receipt 有既有 exact property checks，不能無聲增加 capability 欄位 | S3 以明確版本加入 OS、isolation/lock primitive、cleanup identity evidence；既有 RSA payload 改欄位時另升 receipt 版本，舊簽章驗證仍使用舊 payload |

遷移順序：先新增 reader/schema/examples/negative tests，既有 v1/v2 pins 照舊解讀；再以 pinned 新 installer 升級 stable preflight／runtime；驗證新 USER／REPO state 後才開新 writer。轉換需持鎖、備份舊 bytes、完整 inventory、建立 journal，再發布新 generation。未知版本、混合 generation、重複 ID、unsafe paths、hash mismatch 一律拒絕。

Rollback 不是把版本數字減一：新 state 已發布時，舊 launcher 應 compatibility fail closed。只能以可信新版 recovery 檢查 applied state 後還原完整舊 runtime/config/manifest 或重新安裝相容 bundle；未受管 Claude 內容保留。Schema/parser、lock generator、source composition/acquisition、license delivery、examples、README 與 contract tests 同一實作變更同步。此設計不變更任何 production source pin。

## 7. 雲端 Claude 環境

以下為未來 `scripts/setup-agent-environment.sh` 的流程提案，本任務未新增或執行它，也未連網驗證任何雲端產品能力。

1. 平台以已核准、immutable revision 的 setup script 啟動。確認 OS/architecture、有效 USER home、可寫實體 root、網路 policy 與是否為 ephemeral filesystem；拒絕有 symlink ancestor 的設定，不自動 `realpath` 接受後繼續。
2. 若沒有可信 pwsh，最小 shell bootstrap 依 authority 綁定的取得規格選官方 release asset，取得與 policy 綁定的 SHA-256，在執行前驗證並安全展開至 private physical directory。bootstrap 不能依賴尚未安裝的 PowerShell；shell 只負責這個 bootstrap edge，之後 runtime/Pester 全部使用共用模組。無法安全解壓、取得依賴或驗 hash 時停止，不 `curl | sh`、不偷偷 sudo。
3. 以實體 `pwsh` 路徑執行 `-NoProfile -NonInteractive -File`，確認實際 process executable、PowerShell/.NET version、inventory 及 capability receipt，避免 PATH symlink shim。設定 `CODEX_HOME` 僅在目前 setup/process tree 生效。
4. 首次執行從已驗證 immutable authority snapshot 呼叫 `install-ai-instructions-bootstrap.ps1`；尚無 installed updater 時不能直接呼叫不存在的 hook。已安裝時先驗 stable entry point，再呼叫 `hooks/update-ai-instructions.ps1`；`notify-only/available` 不當成 installed。只有已授權更新方式能安裝 candidate。
5. 同一 verified runtime 執行 `hooks/update-agent-environment.ps1 -Apply`，建立 USER `.agents`／`.claude` projections；執行 manifest/inventory/readiness verification。需要 project Instructions 時再呼叫 installed bootstrap；project Skills 只在明確 opt-in 設定下安裝。
6. Setup 在允許下載的階段備妥 runtime、immutable archives 與 dependencies；後續受限網路階段只讀已驗證 cache。離線或 ephemeral cache 缺失須明確失敗，不以 stale 未驗證 package 冒充 latest-stable。重跑 setup 應回傳 current、檔案 hash 不變、沒有遺留 children/locks。

雲端 setup 是否支援 persistence、rootless namespaces、安裝系統依賴、固定工作目錄、網路階段及 Claude 的實際 Skill discovery 都是未驗證項目。驗收應使用 disposable cloud fixture，不把工作環境 secrets、site 或帳號映射寫入 repository。依 Standard §15.1，未來連外 Skill 仍須先確定環境及 site；setup 本身不推論或寫入這些設定。D4 只提供 shell persistence 的手動指引，不自動修改 profile 或實作 Atlassian 設定。

## 8. 實作拆解

C1–C4 是本設計對所需實作能力的估計，**不是 Standard conformance 等級**：C1 為機械式文件/接線；C2 為單模組契約與測試；C3 為跨模組／平台整合；C4 為 native ABI、安全競態、程序監督或 transaction recovery。不是工時或指定模型。

| Step／階段 | 範圍及預計檔案 | 相依 | 獨立驗收 | 能力 |
| --- | --- | --- | --- | --- |
| P1／S3 可先做 | 定義共用 capability/process/path API 與 authority inventory 接點；新 `scripts/platform-runtime.*`、`scripts/platform/*`、相應 tests | 已核准 D2–D5／Standard；保留 S4 mutation API 為 proposal | Windows wrapper 與既有行為相同；不支持能力有 typed failure；module closure tamper 不可載入 | C3 |
| P2／S3 可先做 | runner 所需 no-follow path、single-link、lock、permissions primitives；native ABI fixtures／platform module | P1 | 三 OS 真 filesystem 測試，unsafe ancestor/leaf、lock substitution 全拒絕；尚不接 production installer | C4 |
| P3／S3 可先做 | 抽出 Job／Linux containment，補 macOS supervisor、PID/start identity；三個中央 runner 與 native supervisor | P1、P2 | timeout/cancel、grandchildren、output quota、env allowlist、cleanup receipts；Core Linux 不再僅 process group | C4 |
| P4／S3 可先做 | verified PowerShell/Pester preparation、resolver／tool closure／POSIX launcher；`Resolve-StandardValidationTool.ps1` 與共用 module | P1、P2；可與 P3 分別驗收 | runtime/hash/architecture mismatch fail closed；regression 4.10.1 與 formal Pester policy 分離；physical launchers／copy-layout dependencies | C3 |
| P5／S3 可先做 | runner receipts／policy/schema 與三平台 Core 接線；`Invoke-StandardAuthorityGate.ps1`、相關 Standard schemas/tests、`pr8-powershell-validation.yml` | P2–P4 | 每平台 canonical authority 一次、完整 retained suite、explicit skip inventory；符合完成條件才把該 leg 加為 required | C3 |
| P6／S4 核准後 | §6 新舊契約、reader-first migration、projection selection；`catalog/schemas/`、`catalog/examples/`、`skills-catalog-contract.psm1`、runtime contract、lock/composition/selection | A3/A4；P1 | 舊 fixtures 可讀、新 reader 拒絕混版／duplicate／unsafe target；舊 reader 對新 state fail closed | C3 |
| P7／S4 核准後 | durable publication、permissions snapshot、CAS/recovery、installer/updater/stable preflight；`installer-safe-mutation.psm1`、`install-ai-instructions-bootstrap.ps1`、installed launcher、updater/runtime contract | A1/A2/A4/A6；P2、P6 | W01–W08 failure matrix、SIGKILL recovery、鎖內 policy 重驗、保持 Windows 行為；無 unsupported filesystem fallback | C4 |
| P8／S4 核准後 | USER 多 projection coordinator、backup/journal、legacy migration；reconciler、`update-agent-environment.ps1`、`repo-shared-skills-migration.psm1` | A3/A4；P6/P7 | 跨位置完整 hash parity、重跑 current、跨 CODEX_HOME 互斥、個人檔保留、partial apply 可恢復 | C4 |
| P9／S4 核准後 | Instructions generator、Claude route、REPO opt-in、exclude/remediation；三支 bootstrap、remediation、`ai-instructions-contract.json`、兩平台及新 Claude 來源、README | A3/A5；P6–P8 | 三 AI 同源/parity、project roots 完整支援、worktree exact exclude、所有 Skill roots 排除 reserved deletion | C3 |
| P10／S4 核准後 | cloud setup bootstrap 與操作文件；新 shell setup、共用 runtime API、README | A6；P4、P7–P9 | disposable cloud 首裝/更新/離線重跑、無 secrets/環境混用、真 host discovery，無系統權限時可預期失敗 | C3 |
| P11／S4 核准後 | 各平台 Install Smoke、production lock／真安裝／idempotence；`syp101-production-smoke.yml`、production-smoke tests／README 支援矩陣 | P7–P10；P5 已完成相同平台 Core | 每個達標 leg 加入即 required；Windows 保持 required；三平台兩 lanes 全過才結束 §18.1.1 過渡 | C3 |

S3 可先做代表不需等待 installer projection／schema 設計核准的分工，不代表本次授權修改程式。若 P1–P5 需要變更 normative contract，仍須先在 `docs/standards/` 更新、同步 machine-readable policy/resolver 與 authority regression 並完成 human review；不能由 helper implementation 自行決定 policy。P6–P11 的 production mutation 在 A1–A6 審閱與必要實驗完成後才開始。

## 9. 測試策略及 CI 導入順序

### 9.1 分層與最小失敗測試

各 Step 的 executable change 依 Testing rules 先建立可重現的 Red fixture，再最小實作 Green，最後移除重複 code。純文件設計本身不新增產品單元測試；本文列出的測試是未來驗收，不能算成本次已通過。

- **Unit／contract：** capability dispatch、ABI identity serialization、safe relative grammar、projection expansion、version transitions、receipt canonicalization、exact property sets、permission policy、unknown OS/native errors。Mock 只驗 policy 判斷，不用 mock 證明 kernel 鎖或隔離。
- **三平台 Pester integration：** 沿用 `tests/install-ai-instructions-bootstrap.Tests.ps1`、`tests/bootstrap-ai-instructions.Tests.ps1`、`tests/agent-environment-reconciler.Tests.ps1`、`tests/ai-instructions-runtime-contract.Tests.ps1`、`tests/skills-catalog-contract.Tests.ps1`、`tests/ai-instructions-contract.Tests.ps1`；另新增共用 platform fixtures。Windows installer 既有 InterT47–InterT54 的鎖、current commit、policy、read lease case 保留。
- **Unix file race：** 真實 symlink（含 dangling、ancestor、loop）、hard link、非 regular file、parent swap、case／Unicode collision、read-only/ACL、umask、無執行權限、跨 device rename、space exhausted、file/parent flush failure。以同步 barrier 注入檢查與 mutation 間競態，不只使用不穩定 sleep。每例保存 outside sentinel／原 bytes／metadata assertion。
- **鎖／recovery：** 獨立 OS processes 驗 shared/exclusive、多 Codex Home 共 USER、不同 projection、owner crash、lock inode replacement、原生 Git index.lock 與 stale journal。對 prepare、stage、rename、manifest commit、rollback 各點注入失敗；安全 state 保留、recovery 可重跑，不能清掉他人新 inode。
- **程序：** Windows Job release handshake、Linux namespace denied 時的 subreaper、macOS session identity、PID reuse、失去 root、double-fork／setsid、timeout/cancel、持管線的 grandchildren、超量 stderr、環境清除、supervisor death。cleanup failure 必須令 canonical check 失敗；外部 sandbox case 與一般 process group case 分開報能力。
- **host acceptance：** 同一 canonical package 投影到所有選定 USER/project roots，完整 bytes/hash parity，測 optional Copilot 重複 discovery、Claude rule routing；檢查 `.git/info/exclude` 精確 marker、HEAD/index 不變與既有個人檔保存。跨 root 更新期間的可見性限制另驗證，不冒稱全域 atomic。

Security fixtures 只用 trusted disposable candidates；不在帶有 secrets 的普通本機環境啟動不可信 candidate。測試層級／固定寬度編號與 Scenario/Purpose 註記遵守 Repository Testing module。

### 9.2 必要 regression

契約變更同步跑 `tests/skills-catalog-contract.Tests.ps1`；Instructions 生成同步跑 `tests/ai-instructions-contract.Tests.ps1`；authority/policy/resolver 變更同步跑 `tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1`、`tests/standard-validation-resolver-hardening.Tests.ps1`。程序相關保留 `tests/standard-process-discovery.Tests.ps1`、`tests/standard-validation-runner.Tests.ps1` 及 shard owner tests。Installer 端再跑 production lock、真實 immutable archive 安裝與二次執行 idempotence，不以 mocked source 取代 Install Smoke。

### 9.3 對應 Standard §18.1.1

1. 保留現有 Windows Core／Install Smoke required gates。現行 workflow 的 Windows PowerShell/Pester bootstrap 是要抽取的起點；未完成 Unix leg 之前，README 應列待完成條件及 evidence，不能標三平台已支援。
2. S3 可先在 disposable/manual 環境收集 Linux／macOS Core 診斷，完成 CI template、canonical authority、完整 retained tests、platform-specific skip inventory 後，才將各平台 Core leg 加入正式 matrix；加入即 required，不能 continue-on-error 或日後降級。
3. S4 完成某平台 installer、production lock、real install 及 idempotence，才將該平台 Install Smoke leg 加入；Core 達標不自動代表 Smoke 達標。兩 lane 的平台進度分別記錄。
4. 最終 Core／Install Smoke 使用 Windows、Linux、macOS，`fail-fast: false`，所有 legs 完成且通過；PowerShell release asset/hash 與 action full-SHA 綁定。Core 每 leg parse tracked scripts、event-aware diff、canonical authority gate 一次、完整保留 non-authority suite 一次。
5. Windows `ExpectedSkippedCount=5` 不可增加；Linux/macOS 使用經 review 的自己的精確 skip inventory，不複製 Windows 數字或跳過必要 canonical checks。`standards-conformance.yml` 保持 workflow_dispatch 診斷，使用相同 authority gate，不能取代 required Core。
6. SYP-353 與 SYP-354 以及兩 lanes 的三平台 required legs 全部完成後才結束過渡。下游採新 authority pin 必須同時採三平台 matrix／全部 leg 聚合語意，不沿用 authority 自身的過渡例外；遠端 ruleset 調整另行授權。

## 10. 風險與未知

| 項目 | 狀態／影響 | 驗證與決策出口 |
| --- | --- | --- |
| SYP-351 報告與其 license entry | **未驗證：此 checkout 缺檔。** 無法宣稱已對齊完整盤點 | 取得本機報告後核對本文 file coverage 與授權分類；不連網補取、不改其他檔案 |
| Native ABI、libc/libSystem 與 .NET 8+ interop | **未驗證：** flags、stat、ACL、libproc、x64/arm64 layout | P2/P3 真平台 ABI probes；未知 RID 先不宣稱支援；必要時採已 hash 綁定的 shim |
| Unix hostile same-UID writer | **已知不等效；強保證未驗證。** flock/0700/dirfd 不能完全取代 deny-write/delete | A1 核准 threat model；需要強保證以 broker／外部 sandbox 實驗；不符合就 mutation 前失敗 |
| macOS process discovery／daemon escape／supervisor crash | **未驗證：** 沒有 Linux subreaper，不可聲稱不可逃逸 | P3/P5 真 macOS sessions、libproc/PID-start、double-fork 測試；strong isolation 場景交 sandbox |
| Linux namespaces/cgroup/subreaper 在 hosted/cloud 的可用性 | **未驗證：** kernel policy／container 限制可能拒絕 | 每 run capability probe，至少一種 Standard 允許的額外 containment；記實際能力而非 OS 推測 |
| Filesystem rename/fsync/ACL/case 語意 | **未驗證：** APFS、Linux filesystem、overlay/network mounts 可能不同；macOS 常見系統路徑別名也可能觸發 symlink 拒絕 | 檢查完整 ancestor；要求配置真正 physical root，不自動接受 symlink。先驗本機 filesystem，network/unknown 不宣稱安全；斷電 durability 另做 fault-injection |
| 三 AI discovery／Instructions routing | **未驗證：** 合法 Standard projection 不等於每個當前 client 已確認載入 | P9/P10 記 client/version、實際 discovery／規則效果，尤其 optional Copilot 雙路徑去重；本次不查外部文件 |
| 跨 root commit 可見性 | **已知非全域 atomic；recovery 行為未驗證。** AI clients 未必持鎖 | A3 接受維護時段限制；P8 測 half-publish、manifest generation、rollback；失敗不標 ready |
| RSA 跨平台 wire compatibility | **未驗證：** `RSACryptoServiceProvider` 換 `RSA.Create()` 不可意外改 padding／canonical bytes | P5 用現有簽章 fixture 交叉驗證，保持 v1 receipts 語意；需要新字段另版本化 |
| Schema/legacy journal migration | **未驗證：** 舊 reader 不可辨識新 state，downgrade 有風險 | P6/P7 reader-first、舊 fixture、crash/recovery matrix；有 active journal 時不得直接升版覆蓋 |
| Cloud setup privileges/network/persistence/dependencies | **未驗證：** 無網路或不允許系統安裝時可能不可用 | P10 disposable cloud 首裝/重跑，預建 image 作替代；無可信取得鏈則 fail closed |
| Source executable mode／license delivery hash parity | **未驗證：** 現行 content hash 是否覆蓋所需 metadata，license output 是否含 target-specific 值需再追查 | P6/P8 對 canonical inventory、archive metadata 與 delivery payload 做雙 projection exact-byte 比較；不得為平台改 Skill bytes |

本次範圍只有此設計文件與 `licensing-scope.json` 的單一條目；未實作上述 API、未安裝工具、未修改 Standard/schema/CI/pins、未執行 installer 或 runner、未 commit/push/切換分支。完成時以本機 JSON／文件檢查、變更範圍檢查及 `git diff --check` 驗證交付，不把設計完整性當成 Unix runtime 驗證。
