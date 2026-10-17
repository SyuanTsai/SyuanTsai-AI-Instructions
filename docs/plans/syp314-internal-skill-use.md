# SYP314：內部 Skill 准用與 consumer 讀取

## 1. 目標與範圍

使用者要求把已檢查且經該用途人類處置的自有內部 Skill 登錄為可採用，而非只產生沒有操作效力的一致性 assessment。第一個實際 case 是 PR18 merge `7e8228c393579d5d21ac9c0ad729c7b5d219bab6` 的 `review-bitbucket-pull-request`，限定內部本機 review／草稿準備。中央單一 writer 使用 `codex/syp314-internal-admission-20261017`，基準 `e510ca1`；304 單獨持有 consumer gate/config/workflow/runner 接入，317 不平行改這些路徑。

驗收：完整 package 的 exact bytes、repository/Skill/content identity、審查與當前 immutable revisions、用途、必要工具、人類處置與原始 finding 可核對；正常 consumer reader 回傳該用途准用。未登錄、package 來源漂移、用途不符、缺工具、過期／撤銷、authority 成員漂移必須拒絕。既有 canonical report/finding/severity 不改寫。

## 2. 最小變更

- 在既有 `internal-source-continuation.json` 增加獨立 `internalUseApprovals` 區段及相同 schema 的可選欄位；保留既有 review-only entries 與舊 assessment 行為。不是把 review-only consistent 升級為准用。
- 在既有中央 runner 加入 `Resolve-StandardValidationInternalSkillUse`。輸入 `SkillRoot`、`SourceRepository`、`SourceRevision`、`SkillId`、`Purpose`、`ExpectedAuthorityFiles`、`ToolInventory`。固定從該 authority runner 所在 root 讀 registry/schema，重用既有 inventory/hash/path 檢查；要求 trusted consumer 的 pinned authority inventory 包含 runner、registry、schema 三者 exact hash。工具 inventory 由 trusted consumer 實際驗證並凍結 id/version/path/hash；reader 再核對必要版本及檔案 bytes。不能由 candidate 提供另一份 registry 或自行宣告 internal。
- 准用資料記錄完整 package content hash、必要 PowerShell/Git 版本、限定用途、人類決定／檢查 evidence、保留的 LP3 MEDIUM 原報告與條件；漂移即不適用。
- 正常 reader 只輸出內部用途 decision，不執行 Skill、不授予 API mutation／工具預授權，不改 Catalog/Lock、不安裝、不發布、不觸發語意掃描。
- normative Standard 明確區分內部准用和外部 release lifecycle；304 使用新 API 實際讀取及拒絕，保持 full authority tuple 與其既有 source report。

## 3. 測試／TDD

沿用 Pester4.10.1，新的直接案例放在 `tests/internal-skill-use.Tests.ps1`，由既有 Windows Core 的普通完整測試 discovery 執行；先完成 baseline 缺少 API 的最小 RED，再實作 GREEN。舊 internal-source suite 保持 regression。

- UnitT：已登錄 exact package/用途可准用，原 MEDIUM 留在 decision，releaseEligible=false。
- UnitT：未登錄 repository/Skill/content、非 immutable 當前 revision、未核准用途、改動／新增／移除 package bytes 拒絕。只改 consumer reader 的新 immutable revision 可沿用完全相同的 Skill content，輸出另保留原 reviewedSourceRevision，避免中央與 consumer pin 循環。
- UnitT：trusted authority inventory 缺件、重複、hash mismatch、revoked/expired review、缺少必要工具拒絕。
- InterT：實際 PR18 五檔 package 從已驗證 merge ZIP 讀取，不做文字正規化；正常 reader 准用 local-pr-review，拒絕 API mutation 用途與漂移 package。原 raw LP3 digest 重新比對並記錄其歷史來源資格。
- 舊 internal assessment suite 保持不授權；執行 repository 規定的三個 authority regression files，schema/syntax、diff check。新差異驗證不重跑過期完整 Skill 掃描。

## 4. 信任與相容性

`ExpectedAuthorityFiles` 是受保護 consumer reader 取得並驗證 immutable authority archive 後的固定 member pins，不是簽章／人類批准，也不能直接轉交 candidate 自算 pins。中央 receiver 自身亦須在正常 PR/CI/review 後交付；本機新候選不得冒充已合併 authority。304 可先以明確開發候選做本機整合，正式 pin 待正常交付。

舊 schemaVersion1／review-only API 保持相容；無 `internalUseApprovals` 時拒絕新准用要求。准用無 wildcard repository、latest ref、通用 caller approval 或 runtime policy input。

## 5. 交付／恢復

先完成可審 diff、直接正反例與實際 reader smoke，提供304固定 API/資料/必要 authority 成員。正式 commit/push/PR/merge 依精確授權處理，不擴用舊 PR89／171 授權。回復至前一 immutable authority tuple 即撤回此新入口；舊 review-only assessment 與原始 scan 不變。任何 package、authority、工具需求或允許用途改變須重新審查；本次不取得 Bitbucket Create/Reply/Resolve、live、USER、release 或 Catalog/Lock 權限。

## 6. 已知限制

舊 LP3 report 綁歷史 candidate；登錄會明確標示為 historical-context，不能冒充 PR18 新掃描。PR18 Stage1–5／482 tests 與人類對現行 Skill/helper 的來源處置是另外的 current-source evidence。准用不聲稱 scanner 已無 finding，也不消除 PR18 延期未修風險。工具名稱/minimum version 只是本內部用途依賴，不是 host 的預授權宣告。

## 7. PR92 Review 修正候選

對 `9b1fa41` 的 Code Review 指出：回傳前只重驗 authority，未偵測本次 evaluation 期間 package／工具的替換；實際 PR18 archive smoke 也只存在交付證據，未被 committed suite 保護。修正只涉及本 API 與直接測試，不改准用資料、用途或 finding。

- 先加入確定性的 late-mutation 案例：在最終 authority 驗證階段才變更／新增／刪除 package 檔案，或替換必要工具 bytes；舊 reader 必須顯示 expected-throw RED，再於回傳前重建完整 inventory 並重驗必要工具，得到 GREEN。
- committed integration case 由固定公開 PR18 commit archive URL 取得 bytes，驗證固定 archive SHA256 後只解出該 Skill 五檔；實際 registry 的 file hashes/content digest 不改寫。驗證正常用途、package drift，以及保留的 LP3 report digest／severity／historical qualification。只在 TestDrive 暫存來源，不把外部 Skill source 追蹤到中央 repo；網路／digest 失敗不能靜默 skip。
- 直接新案例與規定的 authority regressions 重新驗證。原315結果仍只屬 `9b1fa41`；修正候選另記結果。consumer 在採用／執行時仍須保持或重新驗證該 snapshot／工具 bytes，reader 的末次核對不宣稱能消除回傳後的外部競態。
- `9b1fa41` 的直接發布與條件式合併授權不自動擴張到改變後的候選。先完成新 diff 與必要驗證，再取得精確後續 Git 授權；兩個 review threads 在修正正式交付與複審前保持未解決，不合併舊候選。
- 同一候選的正式 CI 已證實原始六檔漏登新增 plan／test 的 licensing inventory。依既有自行撰寫維護文件／測試分類，只在 `licensing-scope.json` 新增這兩條 Apache-2.0 entries；不改 LICENSE、既有 exclusions 或外部 Skill source 的授權。先保留 CI 的 RED，再執行既有 licensing scope／delivery tests；修正交付範圍增為五個既有檔案，另附新的完整 patch 與 hash。
