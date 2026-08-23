# SYP-101：自主更新、Repository 自癒與污染清理

## 決策摘要

目標 Repository 內的 Instructions、Agent Skills 與 manifest 是「個人、Repository-local、branch-independent」runtime artifacts，不是產品原始碼。它們存在於 working tree，透過 `.git/info/exclude` 的精確 managed block 隱藏，並以 manifest v2 與 `PersonalAgent` stash 作為 provenance／recovery evidence。

Runtime 不會執行 `git add`、`git commit` 或 `git push`。任何已由 manifest 證明的 tracked artifact 都視為 Repository pollution；bootstrap fail closed，只有使用者明確授權的 cleanup command 能修改 index。

## 狀態與信任邊界

### Installed runtime

可信狀態由三份文件共同決定：

1. `ai-instructions-sync.json` schema v4：canonical Repository、immutable commit、selection、exclusions 與 update policy。
2. `runtime-bundle.json` schema v2：同一 Repository/commit、acquisition、archive hash、exact file inventory 與 inventory hash。
3. Checked-in Catalog/Lock：external Skills 的 immutable commits、archive hashes 與 content inventories。

Stable launcher 先以自身內建、未載入 runtime code 的 preflight 驗證 config strict schema、canonical identity、config/bundle pin、完整 non-reparse runtime inventory，以及自身 bytes 與 inventory 內的 reference copy；manual updater 與 cleanup 也必須先通過這個 preflight，之後才能載入 installed contract modules。Runtime 接著驗證 Catalog/Lock，installer 則驗證實際 codeload archive hash。任何一項不成立都不得執行下載、fan-out、cleanup 或更新。

### Target Repository

Manifest v2 是 ownership 證據。每個 entry 記錄 artifact identity、來源 Repository/ref/commit/version、source/target path 與 content hash；bootstrap 與 cleanup 在採信前都會執行同一份完整 parser，schema-invalid 或破壞 flat Skill path 的文件不能證明 ownership。

- Manifest entry + exact current hash：可更新、移除或重建。
- Manifest entry + 不同 current hash：視為 customized，保留。
- 無 manifest entry + target 不存在：可建立。
- 無 manifest entry + target 未追蹤且 exact source hash：可安全接管，用於 manifest 自癒。
- 無 manifest entry + tracked 或不同 hash：視為 Repository-owned/unmanaged，保留。
- Manifest-proven path 已 tracked：污染，整次 bootstrap 停止。

這個判定避免把 Repository 自己追蹤的 `.agents/skills/<id>/**` 誤當成個人污染。

## Update state machine

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
   | offline/error -----------------> offline receipt; keep current runtime
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

1. Stable installer 先以內建 verifier 驗證 canonical identity、archive hash 或 git HEAD exact sources，通過後才 import candidate contract；接著取得 per-Codex-Home install lock。Updater 安裝另在鎖內確認 installed commit 與 mode/channel/ref 仍等於 candidate selection 時的狀態，核准撤銷或 policy drift 時在 mutation 前停止。
2. 組合 launcher、updater、cleanup、完整 runtime 與 config。
3. 產生 runtime bundle v2。
4. Parse 所有 PowerShell，驗證 bundle/config inventory 與 Catalog/Lock。
5. 驗證所有 stable file/runtime mutation paths 的類型與 reparse-point boundary，再備份現有 stable commands、runtime、config、個人 `AGENTS.md` 與 `hooks.json`。
6. 替換 stable commands，swap runtime，寫入 config，再更新個人文件/hooks。
7. 任一步失敗即恢復所有備份；包含 staging validation failure 在內，rollback 成功後都刪除 transaction directories。

若 rollback 本身失敗，backup 保留並在例外中回報。Launcher 的 identity/inventory validation 可阻止被中斷的混合版本繼續執行。

Target mutation 也有獨立 snapshot：desired paths、歷史 managed paths、manifest 與 `.git/info/exclude` 都先備份。整段 mutation、stash 與 cleanup 由 common Git directory 的 repository operation lock 序列化；新 stash 以建立前後的 PersonalAgent hash multiset 唯一識別並以 immutable hash reapply，再對所有 canonical paths（包含 manifest）比較 raw SHA-256。清理舊 evidence 時會依 hash 重新解析目前 reference 並在 drop 前再次驗證；若不受 repository lock 約束的外部 Git 行程仍在最後時點移動 index，runtime 會核對 Git 實際刪除的 commit hash、還原非預期刪除的 stash 並保留舊 evidence。Fan-out、byte verification 或唯一識別失敗時則全部恢復 target transaction，其他 user stash 不會靜默遺失。

## Branch 與 linked worktree

一般 branch 共用同一 working directory，ignored artifacts 不受 checkout 影響，因此不需在每個 branch 建立或套用不同 stash。`PersonalAgent` 只是一份 branch-neutral recovery evidence。

Linked worktree 有獨立 working directory。第一次在該 worktree 啟動 production change 時執行 bootstrap，即會建立同一契約的本機 artifacts；共同 Git metadata 中的 PersonalAgent evidence 會在 repository operation lock 內安全刷新，`.git/info/exclude` 則只採所有 live worktree 通過完整 manifest v2 parser（或合法 v1 migration shape）的路徑聯集，因此不同 worktree 的 customized/unmanaged 狀態不會互相移除 ignore。兩個 worktree 的 HEAD/index 都不會改變。

## Config migration

Installer 接受 schema v1–v4：

- v1/v2：保留可辨識 exclusions，初始化 `core` selection 與 notify-only update policy。
- v3：保留 exclusions 與 Skill selections，捨棄所有 auto-commit 欄位，新增 update policy。
- v4：保留 exclusions、selections 與合法 update policy，將 bundle pin 前進到本次安裝 commit。
- Unknown schema、其他 Repository、mutable ref、非法 ID、include/exclude conflict 或非法 channel/ref：fail closed。

Migration 結果永遠是 strict v4 object，不保留未知或 legacy auto-commit properties。

## Pollution cleanup runbook

1. Bootstrap 回報 pollution 後，不要修改 manifest 或執行 hard reset。
2. 檢查列出的 tracked paths、manifest v2（或待清理的精確 legacy v1 manifest）與 working-tree bytes。
3. 執行 installed cleanup command 並傳入 `-Authorize`。
4. Cleanup 以 origin identity 與 Repository 外形驗證 canonical source exclusion，再驗證完整 v2／legacy v1 manifest、safe paths、staged state 與每個檔案 hash。
5. 對已證明且未修改的路徑執行 exact `git rm --cached`，保留 working-tree files。
6. 寫入 `.git/info/exclude` managed block。
7. 使用者檢查 `git diff --cached --name-status`，自行決定何時及如何提交產品 Repository 的污染修復。

任一檔案 customized、staged、unsafe 或無法證明 ownership 時，cleanup 在 index mutation 前停止。若中途失敗，index 與 exclude snapshot 會恢復。Cleanup 本身不 commit 或 push。

## Failure policy

| Failure | 行為 |
| --- | --- |
| Network unavailable 或 GitHub API rate limit | 寫 offline receipt，保留已驗證 runtime；不降級、不安裝。 |
| Candidate behind/diverged | 寫 stale receipt，不下載、不降級、不安裝。 |
| GitHub candidate drift | 寫 drift receipt，刪除暫存下載，不安裝。 |
| Runtime inventory drift | Stable launcher／manual updater／cleanup 在載入 runtime code 前 fail closed，重新執行可信 installer。 |
| Candidate parse/Catalog/Lock failure | 不進入 active swap。 |
| Installer mutation failure | Transactional rollback；若 rollback 也失敗則保留 backup。 |
| Malformed update receipt | Quarantine 損壞檔案，從已驗證 runtime 繼續並原子寫入新 receipt。 |
| Concurrent updater/installer | 回傳不落盤的 concurrent 結果；manual command／launcher fail closed，不與 runtime swap 交錯。 |
| Target customized file | 保留檔案與歷史 manifest entry，繼續安全更新其他檔案。 |
| Manifest-proven tracked file | Bootstrap fail closed，要求明確 cleanup；ignore-case Repository 的 case variant 亦視為 pollution。 |
| Stable/exclude mutation path 是目錄或 reparse point | 在寫入前 fail closed，保留原 filesystem entry。 |
| Concurrent target bootstrap/cleanup | Repository operation lock fail closed，不交錯 stash、exclude 或 index transaction。 |
| External Git process shifts stash indices | 新 evidence 以 immutable hash 套用；舊 evidence cleanup 重新解析 reference，drop hash 不符時還原實際刪除的 stash 並保留舊 evidence。 |
| Target fan-out/stash verification failure | 恢復 target、manifest、index、exclude；保留 recovery evidence。 |

## 驗證矩陣

- Config v1/v2/v3/v4 migration、unknown schema、identity/ref rejection。
- Runtime inventory exact match、缺檔、額外檔案、byte drift、codeload archive hash requirement。
- Update current/available/installed/offline/stale/rate-limit/drift、update/install lock concurrent 與 malformed receipt self-healing。
- Installer staging validation cleanup、expected-current revalidation、late failure rollback、launcher identity/inventory rejection。
- Bootstrap branch switch、linked worktree divergent managed sets、`git clean -fdx` 後完整 re-materialization、manifest/file/exclude self-healing 與 repository lock。
- Customized/unmanaged protection、case-variant 與 legacy-v1 tracked pollution、canonical-origin refusal、cleanup authorization/hash/staged/rollback boundaries。
- PowerShell 5.1 與 7 完整 Pester；real immutable archive production smoke。
