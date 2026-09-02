# SYP-101：自主更新、Repository 自癒與污染清理

## 決策摘要

目標 Repository 內的 Instructions、Agent Skills 與 manifest 是「個人、Repository-local、branch-independent」runtime artifacts，不是產品原始碼。它們存在於 working tree，透過 `.git/info/exclude` 的精確 managed block 隱藏，並以 manifest v2 與 `PersonalAgent` stash 作為 provenance／recovery evidence。

正常同步不會 stage、commit 或 push 產品變更。若 reserved Agent artifact 已被 tracked，bootstrap 會在 Repository 外備份檔案、HEAD 與完整 index，建立只含精確 reserved path deletions 的一次性本機 remediation commit，重建最新 runtime 後繼續同步；consumer commit 永遠不會自動 push。只有 tracked path 落在 reserved 範圍外或無法安全隔離時才 fail closed。

## 狀態與信任邊界

### Installed runtime

可信狀態由三份文件共同決定：

1. `ai-instructions-sync.json` schema v4：canonical Repository、immutable commit、selection、exclusions 與 update policy。
2. `runtime-bundle.json` schema v2：同一 Repository/commit、acquisition、archive hash、exact file inventory 與 inventory hash。
3. Checked-in Catalog/Lock：external Skills 的 immutable commits、archive hashes 與 content inventories。

Stable launcher 先以自身內建、未載入 runtime code 的 preflight 驗證 config strict schema、canonical identity、config/bundle pin、完整 non-reparse runtime inventory，以及自身 bytes 與 inventory 內的 reference copy；manual updater、Agent environment updater 與 cleanup 也必須先通過這個 preflight，之後才能載入 installed contract modules。Runtime 接著驗證 Catalog/Lock，installer 則驗證實際 codeload archive hash。任何一項不成立都不得執行下載、fan-out、cleanup 或更新。

### Target Repository

Manifest v2 是 ownership 證據。每個 entry 記錄 artifact identity、來源 Repository/ref/commit/version、source/target path 與 content hash；bootstrap 與 cleanup 在採信前都會執行同一份完整 parser，schema-invalid 或破壞 flat Skill path 的文件不能證明 ownership。

- Manifest entry + exact current hash：可更新、移除或重建。
- Manifest entry + 不同 current hash：視為 customized，保留。
- 無 manifest entry + target 不存在：可建立。
- 無 manifest entry + target 未追蹤且 exact source hash：可安全接管，用於 manifest 自癒。
- 無 manifest entry + target 未追蹤且不同 hash：視為 Repository-owned/unmanaged，保留。
- Reserved path 已 tracked：先完整備份，再由受控 remediation 解除追蹤並依最新中央來源刪除或替換；customized／unmanaged 內容同樣保留於 backup。
- Manifest 宣告的 tracked target 位於 reserved 範圍外：在任何 mutation 前 fail closed。

Reserved scope 是精確的 Agent runtime 契約；不得延伸到整個 `.github`、`.codex` 或其他 production files。

## Update state machine

### 啟用、停用與排程策略

- `updates.mode = auto-install-approved` 啟用已核准 candidate 的自動安裝。
- `updates.mode = notify-only` 停用自動安裝，但保留安全版本檢查、通知與 audit receipt。
- Installed launcher 的 `-SkipUpdateCheck` 只略過當次 production bootstrap 的網路版本檢查；下一次未帶參數的合法 bootstrap 會恢復檢查。契約不提供永久 `disabled` mode。
- 檢查排程由合法 production-code planning 事件驅動，並以 `minimumCheckIntervalMinutes` rate limit。Runtime 不建立 OS scheduled task、background polling 或 SessionStart hook；人工需要立即檢查時使用 updater 的 `-ForceCheck`。

```text
validate installed state
        |
        v
acquire per-home update lock -- held --> concurrent (no mutation)
acquire install-state lock ----- held --> concurrent (no mixed read)
        |
        v
minimum interval active -----------> rate-limit (no network)
        |
        v
resolve canonical candidate
   | transient network/rate limit --> offline receipt; keep current runtime
   | permanent/config error --------> failed receipt; keep current runtime
   | same commit -------------------> current receipt
   | behind/diverged --------------> stale receipt; refuse downgrade
   | newer + notify-only ----------> available receipt
   v
download immutable codeload ZIP
hash + safe extract + parse + Catalog/Lock validation
        |
        v
resolve candidate again
   | changed -----------------------> drift receipt; no install
   v
transactional installer
   | failure -----------------------> rollback + failed receipt
   v
revalidate active state ------------> installed receipt
```

合法 channel/ref 只有 `protected-branch/main` 與 `github-release/latest`。`notify-only` 是預設；`auto-install-approved` 表示使用者已在個人 config 核准該 channel，單次 `-InstallApproved` 也可明確核准目前 candidate。

Updater 不根據 mutable ref 直接安裝內容。它先解析完整 commit，使用 GitHub compare 證明 candidate 是 installed commit 的 descendant，再取得該 commit 的 archive；behind 或 diverged candidate 只寫 stale receipt，永不降級。Archive 驗證後再次解析 ref；第二次 commit 或 lineage 結果不同即視為 TOCTOU drift。最小檢查間隔內回傳的 `rate-limit` 是不落盤的 workflow 結果，既有有效 receipt 會保留。`current` receipt 由 `currentCommit` 唯一記錄已解析版本，`candidateCommit` 固定為 `null`。

## Transaction 與 rollback

Installer 在 Codex Home 建立同磁碟 staging/backup：

1. Stable installer 先以內建 verifier 驗證 canonical identity；codeload 由同一個 exclusive file handle 完成 archive hash 與安全解壓，git-checkout 則由完整 commit SHA 的 Git objects 產生 installer-owned snapshot，不讀取 mutable worktree bytes。通過後才 import candidate contract，接著取得 per-Codex-Home install lock。Updater 安裝另在鎖內確認 installed commit 與 mode/channel/ref 仍等於 candidate selection 時的狀態，核准撤銷或 policy drift 時在 mutation 前停止。
2. 組合 launcher、updater、Agent environment updater、cleanup、完整 runtime 與 config。
3. 產生 runtime bundle v2。
4. Parse 所有 PowerShell，驗證 bundle/config inventory 與 Catalog/Lock。
5. 驗證所有 stable file/runtime mutation paths 的類型、reparse-point boundary 與 stable-file single-link ownership，並持有本次 staging／backup roots 的 non-delete-sharing directory handles，再備份現有 stable commands、runtime、config、個人 `AGENTS.md` 與 `hooks.json`。
6. 全程持有 Codex Home／`hooks` 的可阻擋 rename directory handles，以 handle-bound create/write 替換 stable commands；每個 stable file 都在同一 mutation handle 內比較 backup snapshot 的 original bytes，再記錄 transaction-applied bytes，之後才 swap runtime、寫入 config 並更新個人文件/hooks。
7. 任一步失敗即恢復所有備份；stable-file rollback 只在 current bytes 仍等於 transaction-applied bytes 時還原或刪除，並會繼續恢復其他未 drift 檔案。Transaction runtime 先原子移入 recovery backup，再以 staged configuration 與 candidate identity 重驗 exact bundle/inventory；只有驗證成功才可遞迴刪除，外部新增、替換或 hash drift 一律保留。外部並行修改會升級為 rollback failure，recovery backup 也會保留；包含 staging validation failure 在內，rollback 成功後都刪除 transaction directories。

若 rollback 本身失敗，backup 保留並在例外中回報。Launcher 的 identity/inventory validation 可阻止被中斷的混合版本繼續執行；驗證完成後，launcher／updater snapshot／Agent environment updater／cleanup 會持有 shared runtime read lock 到 runtime 使用結束，installer 的 exclusive lock 因此不能在執行中 swap bundle。Agent environment `-Apply` 僅在執行 runtime updater 時釋放 read lock，之後重新取得鎖才能 import 與 reconcile。Updater 另從 active runtime preflight、remote resolution、archive acquisition 到 non-install receipt 落盤持有 install-state lock，只在把 immutable candidate 交給 installer transaction 前釋放；若安裝失敗，必須重新取得鎖並確認 active identity 未變，才可寫入 failure receipt。

既有受管檔案的 write/delete handle 會以 target-root directory handle 的 final path 加上安全 relative path 核對實際 final path，並拒絕 reparse file 與 `NumberOfLinks != 1` 的 hard-link alias，使 path precheck 與 native open 間的 alias／parent-junction swap 不能把 mutation 導向 root 外。新檔建立從 target root 起逐層建立或開啟 parent directory，並持有帶讀取存取權且不分享 delete 的 handles 到 file handle 驗證完成；Windows 因此會阻擋途中 rename。移除會以同一個 deny-write/delete handle 讀取與驗證 bytes，再設定 delete disposition，直到關閉 handle 才完成刪除，避免最後一次驗證與 `Remove-Item` 間的 TOCTOU。Exact-hash read-only 檔案會在 handle-bound transaction 暫時清除 attribute；guard handle 保持開啟，重開的 write handle 必須具有相同 volume/file ID，寫入後恢復 attribute，delete disposition 失敗時也先恢復再回報。

Target mutation 也有獨立 snapshot：desired paths、歷史 managed paths 與 manifest 都先備份；每次 target／manifest 寫入在同一 exclusive handle 內先驗證 original bytes，再寫入並保存 transaction-applied bytes。Rollback 只處理本交易確實變更的路徑，且只在 current state 仍等於 applied state 時還原或刪除；parent directory 只有在本交易建立時記錄其 volume/file ID，rollback 再以相同 identity 的 directory handle 刪除，因此 snapshot 後由外部建立的同名空目錄不會被誤刪。外部 drift 原樣保留，其他未 drift 路徑仍各自復原，並升級為需要人工處理的 rollback failure。`.git/info/exclude` 的 original/applied bytes 同樣在實際 mutation 的 exclusive handle 內擷取。整段 remediation、target mutation、stash 與 cleanup 由 common Git directory 的 repository operation lock 序列化；bootstrap 另從 tracked/staged preflight 到 target、exclude、evidence finalization 結束持有 active worktree 原生 `index.lock`，已存在或中途嘗試的外部 staging 因而 fail closed。Shared exclude 的完整 parent chain 必須位於 common Git metadata 且全為 non-reparse directory，正常更新在單一 read-modify-write handle 內完成；rollback 只有在 current bytes 仍等於 applied bytes 時才還原。Manifest/config 固定以 UTF-8 讀取，Git C-quoted path 則依 octal bytes strict UTF-8 解碼，使 Unicode Skill resources 不依賴 Windows code page。Reserved Agent path 的 staged change 會先納入隔離 remediation：HEAD／index 中的 tracked entry 解除追蹤，無關 staged state 由原始 index snapshot 精確保留；remediation 完成後若仍出現 managed staged path，視為並行或無法隔離的 drift 並停止。Runtime evidence subject 包含 hashed worktree identity 與 exact managed Git-blob fingerprint；evidence 透過 private temporary index、`commit-tree` 與 `stash store` 建立三親 stash commit，不執行會修改產品 working tree/index 的 stash push/apply round-trip。驗證 stash 的 untracked tree 確實包含同一組 path/blob，並對所有 canonical live paths（包含 manifest）比較 raw SHA-256 後，才清理同一 worktree、且本次呼叫前已證明為 runtime-owned 的舊 evidence；legacy 或同名 user stash 不會被認領。清理舊 evidence 時會依 hash 重新解析目前 reference 並在 drop 前再次驗證；若不受 repository lock 約束的外部 Git 行程仍在最後時點移動 stash index，runtime 會核對 Git 實際刪除的 commit hash、還原非預期刪除的 stash 並保留舊 evidence。Fan-out、byte verification 或唯一識別失敗時依上述 CAS 邊界復原 target transaction，其他 user stash 或外部 target edits 不會靜默遺失。

## Branch 與 linked worktree

一般 branch 共用同一 working directory，ignored artifacts 不受 checkout 影響，因此不需在每個 branch 建立或套用不同 stash。每個 worktree 的 fingerprinted `PersonalAgent` evidence 都是 branch-neutral。

Linked worktree 有獨立 working directory。第一次在該 worktree 啟動 production change 時執行 bootstrap，即會建立同一契約的本機 artifacts；共同 Git metadata 中會各自保留 hashed worktree identity 對應的 PersonalAgent evidence，更新其中一份不會刪除其他 worktree 的復原證據。`.git/info/exclude` 只採所有 live worktree 通過完整 manifest v2 parser（或合法 v1 migration shape）的路徑聯集，因此不同 worktree 的 customized/unmanaged 狀態不會互相移除 ignore。一般同步不改變任何 worktree 的 HEAD/index；tracked reserved artifact remediation 只更新偵測到污染的 active worktree，其他 linked worktree 的 HEAD/index 保持不變。

## Config migration

Installer 接受 schema v1–v4：

- v1/v2：保留可辨識 exclusions，初始化 `core` selection 與 notify-only update policy。
- v3：保留 exclusions 與 Skill selections，捨棄所有 auto-commit 欄位，新增 update policy。
- v4：保留 exclusions、selections 與合法 update policy，將 bundle pin 前進到本次安裝 commit。
- Unknown schema、其他 Repository、mutable ref、非法 ID、include/exclude conflict 或非法 channel/ref：fail closed。

Migration 結果永遠是 strict v4 object，不保留未知或 legacy auto-commit properties。

## Tracked Agent artifact 自癒

1. 以 Git toplevel、common directory、worktree root 與 branch identity 去重，並取得 Repository operation lock 與 active worktree index lock。
2. 從 HEAD 與 index 聯集找出 tracked reserved paths；舊 manifest 只能擴充到可驗證的 Agent／Skill runtime targets，若指向 production path 則停止。
3. 在系統暫存目錄備份 HEAD、branch、完整 index、index SHA-256、porcelain-v2 status、staged／unstaged diff、精確檔案 bytes 與 SHA-256 inventory；取得原生 `index.lock` 後重驗 backup hash，避免覆寫備份後新增的 staged state。
4. 加入獨立且精確的 `.git/info/exclude` remediation block，以 private index 從原 HEAD 建立只含 reserved deletions 的 `chore: stop tracking local AI instructions` commit；無關 staged、unstaged、untracked 與 ignored files 保持原狀。
5. Retired artifacts 只移除已知檔案；仍受中央管理的 artifacts 由 immutable source 重建。無 permanent Git identity、無 remote 或 detached HEAD 都不阻塞；detached HEAD 使用安全本機 branch。
6. 任一後續步驟失敗即以 applied-state CAS 還原原 ref／HEAD、完整 index、精確檔案與 exclude snapshot；已發生外部 drift 的狀態原樣保留並連同 backup 回報，讓 rollout 繼續處理下一個 Repository。

相同狀態重跑不得再次產生 commit。`cleanup-ai-instructions-pollution.ps1` 只保留為舊 runtime 的明確授權診斷工具，不再是新版 bootstrap 的前置條件。

## Failure policy

| Failure | 行為 |
| --- | --- |
| Network unavailable 或 GitHub API rate limit | 寫 offline receipt，保留已驗證 runtime；不降級、不安裝。 |
| Candidate behind/diverged | 寫 stale receipt，不下載、不降級、不安裝。 |
| GitHub candidate drift | 寫 drift receipt，刪除暫存下載，不安裝。 |
| Verified bundle/config pin mismatch | Launcher fail closed；同一 stable updater 以 `-RecoverInterruptedInstall` 驗證兩份 strict identity、exact runtime inventory 與 stable entry-point references，然後只將 config pin 對齊 active verified runtime commit 並立即返回，不會接續 network check 或 install workflow。 |
| Runtime inventory drift | Stable launcher／manual updater／Agent environment updater／cleanup 在載入 runtime code 前 fail closed，重新執行可信 installer。 |
| Candidate parse/Catalog/Lock failure | 不進入 active swap。 |
| Installer mutation failure | Transactional rollback；若 rollback 也失敗則保留 backup。 |
| Malformed update receipt | Quarantine 損壞檔案，從已驗證 runtime 繼續並原子寫入新 receipt。 |
| Concurrent updater/installer | 回傳不落盤的 concurrent 結果；manual command／launcher fail closed，不與 runtime swap 交錯。 |
| Target customized file | 保留檔案與歷史 manifest entry，繼續安全更新其他檔案。 |
| Tracked reserved Agent artifact | Repository 外完整備份，建立隔離本機 untracking commit，重建 runtime 並繼續；ignore-case Repository 的 case variant 使用 index 實際 spelling，且不 push。 |
| Manifest 宣告範圍外 tracked production file | 在任何 mutation 前 fail closed，不擴大 remediation scope。 |
| Stable/exclude mutation path 或 exclude parent chain 是目錄類型不符或 reparse point | 在寫入前 fail closed，保留原 filesystem entry 與外部 target。 |
| Concurrent target bootstrap/cleanup | Repository operation lock fail closed，不交錯 stash、exclude 或 index transaction。 |
| Concurrent product index mutation | Bootstrap/cleanup 取得 active worktree 原生 `index.lock`；既有或中途 staging fail closed，不得產生成功但已 staged 的 managed artifact。 |
| External Git process shifts stash indices | 新 evidence 以 immutable hash 套用；舊 evidence cleanup 重新解析 reference，drop hash 不符時還原實際刪除的 stash 並保留舊 evidence。 |
| Target fan-out/stash verification failure | 只恢復 current==transaction-applied 的 target、manifest、index、exclude；外部 drift 原樣保留並回報人工處理，保留 recovery backup/evidence。 |

## 驗證矩陣

- Config v1/v2/v3/v4 migration、unknown schema、identity/ref rejection。
- Runtime inventory exact match、缺檔、額外檔案、byte drift、codeload archive hash requirement。
- Update current/available/installed/offline/failed/stale/rate-limit/drift、update/install lock concurrent 與 malformed receipt self-healing。
- Installer staging validation cleanup、expected-current revalidation、late failure rollback、launcher identity/inventory rejection。
- Bootstrap branch switch、linked worktree divergent managed sets、`git clean -fdx` 後完整 re-materialization、manifest/file/exclude self-healing 與 repository lock。
- Reserved customized/unmanaged backup migration、case-variant／Unicode、legacy-v1 tracked remediation、unrelated index preservation、worktree isolation、detached HEAD、no-remote／no-identity、idempotence、atomic rollback 與 scope escape refusal。
- PowerShell 5.1 與 7 完整 Pester；real immutable archive production smoke。
