# SYP-351 [S1] 盤點報告｜三平台化範圍、Linux 實跑結果與工作量估算

- 日期：2026-11-02
- 基準：6 個 repository 的 `origin/main`，SHA 與 SYP-351 描述一致（General `ef50133`、Atlassian `901c001`、Code-Collaboration `54383dd`、Knowledge-Content `e752098`、Darktide `0704433`、AI-Instructions `5183945`）。
- 執行：主控 Claude Opus 5.5（本機 Claude Code）；執行端 Codex CLI 0.154.0。逐檔分類與條文盤點由 Codex 唯讀完成，主控抽查行號與內容後採用。
- 範圍調整：依 SYP-351 留言「範圍調整」（以本留言為準），本次只在 Linux 實跑；macOS 實跑與 macOS 上的 SkillSpector 結果改由 SYP-353（S3）交付。
- 未修改任何 repository 的 main。Linux 實跑使用拋棄式分支 `probe/SYP-351-linux`（使用者已授權 push），完成後刪除。

## 0. 需要使用者決策的事項

| # | 事項 | 影響 | 建議 |
| --- | --- | --- | --- |
| D1 | 本報告的正式存放位置（repo 內文件或 Confluence） | SYP-351 驗收條件「連結貼回本單」 | 放 `SyuanTsai-AI-Instructions/docs/`（與 Standard 同處，S2 會引用）；需 commit／PR 授權 |
| D2 | macOS 程序隔離的安全等級：要求與 Windows Job Object／Linux PID namespace 等價的不可逃逸隔離，或接受 process group／session 加 PID 與啟動時間身分驗證 | S2 條文、S3 CI、S4 | 接受 process group 等級，並在證據中標明實際使用的隔離能力；需要強隔離時改用外部 sandbox |
| D3 | Unix 上的 symlink 與 hard link 政策：全部拒絕，或允許經 `lstat`／descriptor 驗證的特定 symlink；受管檔案是否一律要求 `st_nlink == 1` | S2、S4、S8 | 受管與安全相關路徑全部拒絕 symlink，受管一般檔案要求 `st_nlink == 1`（與現行 Windows 語意一致） |
| D4 | Atlassian 三個 `configure-*-api-access` 在 Linux／macOS 的環境變數持久化方式：shell profile、OS 祕密儲存，或只支援 process 範圍 | S6 | 只保證 process 範圍並提供明確的手動持久化指引；不自動改寫 shell profile |
| D5 | 跨 repository 共用模組（路徑安全、程序隔離、鎖、PowerShell runtime 取得、Pester 準備）放在哪裡、如何分發 | S2、S3、S5–S8 工作量 | 由 AI-Instructions 提供並以 authority pin 分發；先在 S3 試行 repo 驗證 |
| D6 | Skill-Code-Collaboration 的 authority pin 不一致（見 §7 後續項目）在哪張單處理 | S3、S7 | 併入 S3（試行 repo 本來就要改驗證流程） |

## 1. 摘要

1. **所有 repository 的驗證流程在 Linux 上都無法通過**，原因幾乎都是「刻意設計的 Windows 閘門」或「Windows 執行檔與 runtime 身分檢查」，不是 PowerShell 本身無法執行。runner 內建的 PowerShell 7 可以直接跑起各 repo 的 Pester。
2. **Pester 在 Linux 上的通過率**：Knowledge-Content 98%、Atlassian 97%（另略過 6）、Darktide 96%、General 87%、Code-Collaboration 77%、AI-Instructions 64%。技能 repo 的失敗集中且有限；AI-Instructions（installer 與 Standard 工具鏈）失敗 333 個，是最大工作量來源。
3. **非測試腳本逐檔分類（130 支）**：

| 範圍 | 檔案數 | 僅 Windows | 三平台行為不同 | 已跨平台 | 靜態估計工時 |
| --- | ---: | ---: | ---: | ---: | ---: |
| AI-Instructions | 51 | 3 | 28 | 20 | 219.5h |
| 5 個 Skill repo | 79 | 6 | 27 | 46 | 262h |
| 合計 | 130 | 9 | 55 | 66 | 481.5h |

4. **最大風險（S4）**：installer 的 handle-bound mutation（`installer-safe-mutation.psm1`、`bootstrap-ai-instructions.ps1`、`repo-shared-skills-migration.psm1`）在非 Windows 上明確 fail closed；`FileShare` 型的鎖在 Unix 上只是 advisory。需要以 `openat`／`O_NOFOLLOW`／`lstat`／`st_nlink`／`flock` 重新設計等效保護。
5. **新發現的風險**：Standard 工具鏈的程序隔離 Unix 分支其實是 Linux 專用（`prctl`、`/proc`、`unshare --pid`），macOS 沒有對應實作，會影響 S2 條文與 S3 的 macOS matrix leg。
6. **Standard 條文**：需處理 19 處（Jira 已知 7 處之外，另有單一 AI 安裝路徑、`agents/openai.yaml` 必填、`$skill-id` 呼叫語法、Windows parser 語意、Windows gate 唯一性、Windows byte tests 等）。Standard 未要求 SKILL.md 內文放 SPDX，frontmatter 只允許 `license`。
7. **CI 現況**與 Jira 一致：22 個 job，19 個 `windows-latest`、3 個 `ubuntu-latest`，沒有 macOS。

## 2. Linux 實跑結果（ubuntu-latest，GitHub Actions）

方法：每個 repository 新增一個只在 `probe/SYP-351-linux` 觸發的 workflow，照原樣鏡像 canonical 驗證 job（只把 runner 改成 `ubuntu-latest`，每步 `continue-on-error`），另加「直接以 runner 內建 pwsh 執行驗證腳本」與「獨立執行 Pester」兩個 step。共跑兩輪；第一輪發現 probe 自身的 Pester 與傳參缺陷，修正後第二輪取得完整結果。

| Repository | canonical 流程最先失敗的 step | 錯誤訊息 | Pester（Linux） |
| --- | --- | --- | --- |
| Skill-General | Install and verify Microsoft's latest stable PowerShell | `Validation requires Windows.` | 330：287 通過、43 失敗 |
| Skill-Atlassian-Ecosystem | Require reviewed PowerShell parser runtime；Run canonical Standard v1 validation | `The canonical workflow did not select the reviewed PowerShell parser runtime.`；`Validate.ps1:49` `Standard v1 canonical validation requires Windows with PowerShell 7.` | 519：501 通過、12 失敗、6 略過 |
| Skill-Code-Collaboration | Capture resolved stable Go runtime | 找不到 Windows 執行檔（`go.exe`）；後續 Node／source tools 連鎖失敗 | 159：122 通過、37 失敗 |
| Skill-Knowledge-Content | Capture and verify Node runtime before source setup | 找不到 Windows 執行檔（`node.exe`）；後續 PowerShell 安裝與 source evidence 連鎖失敗 | 106：104 通過、2 失敗 |
| Skill-Darktide-Translate | Create run-owned validation directory | `Standard v1 CI requires a Windows runner.`；`Validate.ps1:44` 同樣拒絕 | 301：289 通過、12 失敗 |
| SyuanTsai-AI-Instructions | Install verified latest stable PowerShell（5 個 job 皆同） | `Verified archive launched unexpected PowerShell version ''.`；`The actual GitHub step shell is not the verified portable PowerShell`；`Pester shard executor requires Windows PowerShell 7.` | 924：591 通過、333 失敗（Pester 4.10.1）；authority 子集 289：195 通過、94 失敗 |

補充：
- `SyuanTsai-AI-Instructions/scripts/update-skills-catalog-lock.ps1 -Check` 在 Linux 上**通過**。
- SYP101 install smoke 在 Linux 上於 `installer-safe-mutation.psm1` 的 Windows handle 層失敗（`OpenDirectoryGuard`），與靜態分類一致。
- 直接執行驗證腳本時，General、Knowledge-Content、Code-Collaboration 停在 authority 合約的模式要求（例如 `Core Run requires -AuthorityRepositoryRoot`、`Active 8e62 authority requires explicit -PrepareSourceTools or -SourceValidation`），這是驗證腳本設計，不是平台限制；這三個 repo 在 Linux 上的實際阻礙以上表 canonical 流程為準。
- 每個 step 的完整成敗表見各 run 的 Step Summary（run 記錄於附錄 A）。

## 3. Linux Pester 失敗原因分類

由 351-P 依實際 log 歸類（類別：1 平台閘門、2 Windows 原生 API、3 執行檔與 runtime 身分、4 路徑語意、5 檔案鎖、6 換行與位元組、7 程序行為、8 測試本身的 Windows 假設、9 其他／無法判斷）。

**限制**：AI-Instructions 使用 Pester 4.10.1，log 只列出失敗測試名稱，有 241 個無法對應到錯誤訊息，歸為類別 9。S4 重跑時需讓 probe 逐筆輸出錯誤內容。


| Repository | `PESTER-FAILED` 去重數 | 類別分布 |
|---|---:|---|
| Skill-General | 43 | 3=32、4=7、6=1、8=2、9=1 |
| Skill-Atlassian-Ecosystem | 12 | 8=10、9=2 |
| Skill-Code-Collaboration | 30 | 3=29、8=1 |
| Skill-Knowledge-Content | 2 | 8=1、9=1 |
| Skill-Darktide-Translate | 12 | 1=5、2=1、3=3、4=2、8=1 |
| SyuanTsai-AI-Instructions | 333 | 1=5、3=80、4=7、9=241 |
| **合計** | **432** | **1=10、2=1、3=144、4=16、6=1、8=15、9=245** |

量最多的三項為：

1. **9 其他／無法判斷（245）**：其中 AI-Instructions 有 239 個 `PESTER-FAILED` 僅有名稱，log 未提供可與該名稱逐一對應的 Pester 錯誤段或產品位置；依限制不猜測。
2. **3 執行檔與 runtime 身分（144）**：`pwsh.exe`、verified runtime、launcher kind 與實際 Linux `pwsh` 的契約不一致。
3. **4 路徑語意（16）**：junction/reparse fixture、大小寫／長路徑／create-only 根目錄預期差異。

### 各 repository 分類明細

#### Skill-General

| 類別 | 測試數 | 代表測試名稱 | 代表錯誤訊息 | 涉及的產品檔案 |
|---|---:|---|---|---|
| 3 執行檔與 runtime 身分 | 32 | `UnitT20_builds_the_minimal_core_v2_adapter_for_repository_validation`；`InterT05_returns_exact_hash_for_successful_blob`；`UnitT70_registers_the_verified_module_after_checkout_line_ending_conversion` | trusted／verified `pwsh.exe` 不存在或非 regular file | `Skill-General/scripts/CorePesterIntegrity.psm1`；`Skill-General/scripts/Invoke-CorePester.ps1`；`Skill-General/scripts/Prepare-PesterRuntime.ps1` |
| 4 路徑語意 | 7 | `UnitT45_binds_prepared_tool_root_to_exact_host_temp_and_run_identity`；`UnitT25_rejects_escaped_paths_and_reparse_point_ancestors`；`UnitT06_rejects_junctioned_legacy_skill_locations_before_enumerating_skills-root` | run-owned root 不同；junction 目錄不存在 | `Skill-General/scripts/Invoke-CorePester.ps1`；`Skill-General/scripts/CorePesterIntegrity.psm1` |
| 6 換行與位元組 | 1 | `UnitT70_registers_the_verified_module_after_checkout_line_ending_conversion` | checkout line-ending 後的 runtime 子程序失敗 | `Skill-General/scripts/CorePesterIntegrity.psm1` |
| 8 測試本身 Windows 假設 | 2 | `UnitT06_rejects_junctioned_legacy_skill_locations_before_enumerating_skills-root`；`...agents-ancestor` | 建立／存取 junction fixture 時目錄不存在 | 無可確認產品檔案；位置為 `tests/StandardV1Conformance.Tests.ps1` |
| 9 其他／無法判斷 | 1 | `UnitT50_accepts_exact_package_inventory_and_rejects_unclassified_archive_entries` | Int32 轉 UInt32 溢位；log 未足以判定平台根因 | `Skill-General/scripts/CorePesterIntegrity.psm1` |

#### Skill-Atlassian-Ecosystem

| 類別 | 測試數 | 代表測試名稱 | 代表錯誤訊息 | 涉及的產品檔案 |
|---|---:|---|---|---|
| 8 測試本身 Windows 假設 | 10 | `InterT150_rejects_a_dangling_capture_target_junction_before_remote_io`；`InterT152_rechecks_the_raw_file_ancestors_before_opening_and_writing`；`InterT81_rejects_broken_plan_output_junction_before_remote_io` | junction／broken-link fixture 路徑不存在 | 無可確認產品檔案；位置為 Capture／Create-preview 測試 fixture |
| 9 其他／無法判斷 | 2 | `InterT25_InitializesTheSharedPesterParentBeforeTheReadOnlySourceWorkflow`；`InterT10_UsesTheCentralWrapperForSupportedStaticParseLimit` | null-valued expression；central report JSON 截斷 | 無法由 log 指向單一產品檔案 |

#### Skill-Code-Collaboration

| 類別 | 測試數 | 代表測試名稱 | 代表錯誤訊息 | 涉及的產品檔案 |
|---|---:|---|---|---|
| 3 執行檔與 runtime 身分 | 29 | `InterT10_rejects_string_error_count_from_the_real_Code_child`；`UnitT65_uses_the_verified_runtime_modules_directory_for_module_search`；`UnitT83_preserves_resident_state_when_raw_timing_flush_fails` | actual CLI `-ToolchainPath` binding 非唯一／runtime module search 不符 | `Skill-Code-Collaboration/scripts/CorePesterIntegrity.psm1`；`Skill-Code-Collaboration/scripts/Invoke-CorePester.ps1`；`Skill-Code-Collaboration/scripts/Prepare-PesterRuntime.ps1` |
| 8 測試本身 Windows 假設 | 1 | `InterT64_rejects_unsafe_diagnostic_writer_destinations` | junction fixture 路徑不存在 | 無可確認產品檔案；位置為 `tests/SourceValidationAdoption.Tests.ps1` |

#### Skill-Knowledge-Content

| 類別 | 測試數 | 代表測試名稱 | 代表錯誤訊息 | 涉及的產品檔案 |
|---|---:|---|---|---|
| 8 測試本身 Windows 假設 | 1 | `UnitT70_runs_all_required_status_mirrors_on_Windows_and_rejects_non_success_results` | `pwsh.exe` command not found | 無可確認產品檔案；位置為 `tests/StandardV1Conformance.Tests.ps1` |
| 9 其他／無法判斷 | 1 | `UnitT56_rejects_ordinary_validation_while_scoped_source_pin_is_active` | 預期 regex 與跨行診斷文字不符；非明確平台錯誤 | `Skill-Knowledge-Content/scripts/Validate.ps1` |

#### Skill-Darktide-Translate

| 類別 | 測試數 | 代表測試名稱 | 代表錯誤訊息 | 涉及的產品檔案 |
|---|---:|---|---|---|
| 1 平台閘門 | 5 | `UnitT05_RemovesApiCredentialsBeforePreflightNativeChildren`；`UnitT10_AuthenticatesOnlyTheTrustedSkillSpectorResolver`；`UnitT40_PreservesAnonymousResolutionWhenTheTokenIsAbsent` | `Standard v1 validation requires Windows with PowerShell 7` | `Skill-Darktide-Translate/scripts/Validate.ps1` |
| 2 Windows 原生 API | 1 | `UnitT109_PreservesNativePathSemanticsWhileExtendingCanonicalLongPaths` | `SyuanTsai.PathSafetyNative` 型別不存在 | `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/PathSafety.psm1` |
| 3 執行檔與 runtime 身分 | 3 | `InterT45_BoundsRealTrustedPesterChildOutputAndPreservesExitStatus`；`UnitT10_ConfinesWorkflowCredentialsToTheTrustedValidator_Exit0` | bounded child／trusted executable `pwsh.exe` 不存在 | `Skill-Darktide-Translate/scripts/PowerShellRelease.psm1`；`Skill-Darktide-Translate/scripts/Validate.ps1` |
| 4 路徑語意 | 2 | `InterT30_RejectsUnsafeRunRoots_rootReparse`；`InterT109_QueriesRealLongPathCaseSemanticsAndPhysicalIdentity` | reparse 未被拒絕；Windows 長路徑長度預期不成立 | `Skill-Darktide-Translate/scripts/Validate.ps1`；`Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/PathSafety.psm1` |
| 8 測試本身 Windows 假設 | 1 | `InterT80_RejectsWindowsReparsePointsInInstalledClosures` | 預期 Windows reparse 例外，但 Linux fixture 未觸發 | 無可確認產品檔案；位置為 `tests/RepositoryContract.Tests.ps1` |

#### SyuanTsai-AI-Instructions

| 類別 | 測試數 | 代表測試名稱 | 代表錯誤訊息 | 涉及的產品檔案 |
|---|---:|---|---|---|
| 1 平台閘門 | 5 | `InterT10_executes_only_selected_files_and_writes_typed_summary`；`InterT20_rejects_failed_and_empty_runs_without_completed_summary`；`InterT50_partition_summary_lists_only_executed_files` | `Pester adapter contract tests require Windows PowerShell 7` | `SyuanTsai-AI-Instructions/scripts/Invoke-PesterShardProcess.ps1` |
| 3 執行檔與 runtime 身分 | 80 | `UnitT10_rejects_Core_only_PASS_as_source_validation_success`；`UnitT30_rejects_wrong_candidate_SHA_from_source_required_contexts`；`UnitT67_times_real_owned_process_cleanup_and_preserves_results`；`UnitT62_keeps_native_entrypoint_and_node_extras_in_shared_controls`；`UnitT68_times_full_report_reads_and_restores_observer_on_success_and_failure` | receipt launcher kind 與平台不符；`pwsh.exe` 不存在 | `SyuanTsai-AI-Instructions/scripts/Resolve-StandardValidationTool.ps1`；`SyuanTsai-AI-Instructions/scripts/Invoke-StandardValidation.ps1`；`SyuanTsai-AI-Instructions/scripts/StandardSemanticBridge.psm1` |
| 4 路徑語意 | 7 | `UnitT26h_allocates_authority_tool_root_with_windows_path_length_headroom_normal-repository_normal-temp`；`UnitT26ha_fails_before_creation_when_all_authority_tool_candidates_exceed_the_windows_path_budget`；`UnitT65_rejects_root_and_ancestor_reparse_substitution` | Windows path budget／create-only root／reparse 預期不成立 | `SyuanTsai-AI-Instructions/scripts/Resolve-StandardValidationTool.ps1`；`SyuanTsai-AI-Instructions/scripts/Invoke-StandardValidation.ps1` |
| 9 其他／無法判斷 | 241 | `bootstrap-ai-instructions.InterT04_manages_instruction_license_delivery_without_touching_product_licenses`；`tracked AI instructions pollution cleanup.InterT20_stages_precise_deletions_and_preserves_local_materialization`；`SYP214 USER migration serialization.InterT20_holds_the_USER_lock_through_apply_and_releases_it_afterward` | 239 筆沒有可對應的 Pester 錯誤段；另 2 筆為 workflow count／immutable-input 預期差異 | 無法由 log 建立測試名稱到產品位置的一對一對應 |

### 與靜態分類的差異

其餘有明確產品位置的結果，均與 351-A／351-B 的「僅 Windows」或「三平台行為不同」分類一致。差異如下：

| 檔案 | 351-A/B 的分類 | 實測結果 | 說明 |
|---|---|---|---|
| `Skill-Code-Collaboration/scripts/Validate.ps1` | 已跨平台 | 29 項 runtime 身分連鎖失敗 | 實測仍受 CLI `-ToolchainPath`／verified runtime 契約阻斷；靜態分類低估 Linux runtime 整合風險。 |
| `Skill-Knowledge-Content/scripts/Validate.ps1` | 已跨平台 | 診斷文字預期不符 | 非明確產品平台失敗；測試對跨行訊息處理不穩定。 |
| `Skill-Knowledge-Content/tests/StandardV1Conformance.Tests.ps1` | 靜態表標示產品檔已跨平台 | `pwsh.exe` command not found | 測試 fixture 硬編 Windows 執行檔名稱，非產品程式跨平台能力本身。 |
| `Skill-Atlassian-Ecosystem` Capture／Preview 測試 fixture | 相關產品檔多為已跨平台 | 10 項 junction fixture 失敗 | log 指向 fixture 建立／存取 junction 失敗，不能據此判定產品路徑處理失敗。 |
| `SyuanTsai-AI-Instructions/scripts/Invoke-PesterShardProcess.ps1` | 靜態指出含 Unix fallback | 5 項直接要求 Windows PowerShell 7 | 實測顯示 Pester adapter contract 仍有明確平台閘門。 |

### 對工作量估算的影響

| Repository | 難度 | 理由 |
|---|---|---|
| Skill-General | 高 | `CorePesterIntegrity`、runtime closure、child process 與路徑／reparse 檢查相互連鎖；先修 runtime 身分可解除約 32 項。 |
| Skill-Atlassian-Ecosystem | 低 | 主要是 Windows junction fixture；先把 fixture 抽象為 symlink／平台能力測試。兩項其餘問題須補足診斷。 |
| Skill-Code-Collaboration | 中 | 約 29 項集中於同一 runtime／toolchain binding 契約，適合修共用 Pester runtime 模組。 |
| Skill-Knowledge-Content | 低 | 一項 Windows-only test fixture、一項訊息斷言；產品跨平台修改證據不足。 |
| Skill-Darktide-Translate | 高 | `Validate.ps1` 為直接 Windows gate，另有 native PathSafety 與 long-path／reparse 契約；需架構性 Unix backend。 |
| SyuanTsai-AI-Instructions | 高 | 已知 92 項集中於 runtime launcher、path budget 與 Windows-only shard adapter；但 241 項無可對應錯誤位置，需先改善 probe 的 failure serialization 才能可靠估工。 |

可由一處共用模組大幅解除的項目：

- 類別 3：三個 repository 的 Core Pester／verified runtime 契約，以及 AI-Instructions 的 source-tool launcher。
- 類別 4：平台感知的 path comparer、reparse/symlink 判定與長路徑策略。
- 類別 1：Darktide 與 AI-Instructions 的入口／shard adapter 平台 backend。

偏逐檔修改的是類別 8 的 test fixture，以及 Darktide 的 Windows native PathSafety 實作。

### 核對

| Repository | `PESTER-FAILED` 去重筆數 | 分類總數 | 結果 |
|---|---:|---:|---|
| Skill-General | 43 | 43 | 相符 |
| Skill-Atlassian-Ecosystem | 12 | 12 | 相符 |
| Skill-Code-Collaboration | 30 | 30 | 相符；與背景所述 37 不同，log 中可序列化的唯一 `PESTER-FAILED` 僅 30 筆 |
| Skill-Knowledge-Content | 2 | 2 | 相符 |
| Skill-Darktide-Translate | 12 | 12 | 相符 |
| SyuanTsai-AI-Instructions | 333 | 333 | 相符 |
| **合計** | **432** | **432** | **相符** |

## 4. 工作量估算（S2–S8）

估算依據：351-A／351-B 的逐檔靜態工時、Linux 實測失敗數與根因分布（§3）、Standard 條文數（§5）與 §19 的同 PR 測試要求。單位為含測試的開發工時；**這是主控推估，不是實測值**。若先建立共用模組（D5：路徑安全、程序隔離、鎖、runtime 取得、Pester 準備），S5–S8 估計可再減少約 20–30%。

| Story | 主要內容 | 估計 | 風險 | 主要依據 |
| --- | --- | ---: | --- | --- |
| S2 Standard 改版 | 19 處條文；§19 要求同一 PR 更新 `skill-repository-standard.Tests.ps1`、`skill-repository-workflows.Tests.ps1`、`standard-validation-resolver-hardening.Tests.ps1` 與 machine-readable policy；三 AI 規範、環境區隔、精簡規範成文 | 40–60h | 中 | D2、D3 未決時條文無法定稿；`validation-security-gate.json` 的 role 仍為 Windows 專屬 |
| S3 CI 範本（試行 Code-Collaboration） | 三平台 matrix、Windows `.exe` 與 verified runtime 契約改為平台感知、Pester runtime 共用化、macOS 實跑與 SkillSpector | 50–70h | 中高 | Code-Collaboration 29 項失敗集中於 runtime 契約；macOS 程序隔離無實作；D6 pin 不一致需一併處理 |
| S4 Installer 跨平台與 Claude 輸出 | handle-bound mutation、鎖、symlink／hard-link 保護的 Unix 等效設計；`~/.claude/skills` 與 `CLAUDE.md` 輸出 | 260–340h | 高 | 351-A：18 檔建議「替換」、219.5h；Linux 實測 333 個失敗（其中 241 個需重跑取得錯誤明細）；設計需先經使用者核准 |
| S5 Skill-General | 7 個 SKILL.md 中立化與精簡；`manage-task-handoff`、`operate-environment-authorized-sql` 腳本；Core Pester runtime | 35–50h | 中 | 351-B 24h；43 個失敗中 32 個為 runtime 身分（共用模組可一次解除） |
| S6 Skill-Atlassian-Ecosystem | 34 支腳本中 13 支需改寫／替換；環境區隔（私人 MCP、工作 token）；`configure-*` 共用 reference；Unix 環境變數持久化 | 120–150h | 中高 | 351-B 107h；Linux 只有 12 個失敗且多為 junction fixture，但 `Validate.ps1`、`Invoke-StandardValidation.ps1`、`Invoke-SourceConformance.ps1` 有直接 Windows 閘門；D4 未決 |
| S7 Code-Collaboration 與 Knowledge-Content | SKILL.md 中立化與精簡；KC 6 支腳本；CC 驗證腳本移植若已在 S3 完成則只確認 | 25–40h | 低 | 351-B：CC 18.5h、KC 17h；KC 只有 2 個測試失敗 |
| S8 Skill-Darktide-Translate | `Validate.ps1` Windows 閘門；`PathSafety.psm1` 在 Unix 無實體身分判斷；`SharedCoordinationLock.psm1`；Windows PowerShell 安裝器 | 100–130h | 中高 | 351-B 95.5h、3 支建議「替換」；Linux 12 個失敗含直接閘門與 native path 契約 |
| **合計** | | **630–840h** | | |

關鍵路徑上的主要不確定性：S4 的 Unix 等效保護設計（需 D3），以及 S3 在 macOS 的實跑結果（程序隔離與 SkillSpector）。

## 5. Standard 條文清單

來源：`SyuanTsai-AI-Instructions/docs/standards/skill-repository-standard.md`（`5183945`）。下表由 351-C 盤點，主控以原文核對 L11 與 §19。


| 位置 | 主題 | 原文短句 | 三平台／三 AI 化的處理方向 |
|---|---|---|---|
| `SyuanTsai-AI-Instructions/docs/standards/skill-repository-standard.md:11` | Windows host 限定與 description 宣告 | 「本機…與 CI host 僅支援 Windows；Linux、macOS 與 WSL 為不支援」；「SKILL.md description 均明示 local execution 僅支援 Windows」 | 改為條件式 capability/host 支援宣告；以 `windows`、`linux`、`macos` 明確列舉，將 CI 與 local runtime 分離。 |
| `…/skill-repository-standard.md:87,95-99` | 單一 runtime 路徑 | 「`.agents/skills/<skill-id>`」；「`.claude/skills/<skill-id>`」 | 新增 Codex、Claude、Copilot 的 projection mapping；不得把 `.agents` 當唯一 legacy/consumer 模型。 |
| `…/skill-repository-standard.md:114-121` | OpenAI metadata 必要性 | 「`SKILL.md`」；「`agents/openai.yaml`」 | `SKILL.md` 維持核心必填；將 `agents/openai.yaml` 改為 OpenAI/Codex adapter 的條件必填，新增 Claude/Copilot adapter 契約或通用 metadata。 |
| `…/skill-repository-standard.md:125-137` | `SKILL.md` frontmatter／license | 「只包含 `name`、`description`、`license`、`allowed-tools`、`metadata`」 | 保留可攜 frontmatter；明確定義跨 AI 共通欄位與 host adapter 欄位。此處僅允許 `license` frontmatter，**未要求 SPDX 標註出現在 SKILL.md 內文**。 |
| `…/skill-repository-standard.md:139-158` | `agents/openai.yaml` 與 `$skill-id` | 「`agents/openai.yaml` MUST 不只存在」；「reference exact `$<skill-id>` token」 | 改為 OpenAI adapter 專屬規則；抽出通用 skill identity，分別定義 Claude/Copilot 的 invocation/reference syntax，不以 `$skill-id` 作全域要求。 |
| `…/skill-repository-standard.md:305` | required contexts 前置 | 「Core-only PASS MUST NOT 滿足 `repository-contract`、`skill-validator` 或 `skill-tools`」 | 保留 context 語意，但建立跨 OS 的 canonical-result artifact/attestation；不可讓 Windows-only Core 成為唯一可產出 context 的實作。 |
| `…/skill-repository-standard.md:311` | required contexts 語意 | 「三個 required contexts MUST 共用同一 event/candidate 一次完整 canonical source 結果」 | 維持「單一 canonical 結果、精確 candidate/base/authority/run/inventory」；明確允許各 OS projection job 轉述已驗證結果，禁止各平台重算出不同 gate。 |
| `…/skill-repository-standard.md:313` | Windows child process | 「Windows child processes MUST use hidden windows and `CreateNoWindow`」 | 改為 OS-specific process-launch adapter：Windows 保留該要求，Linux/macOS 定義無終端／process-group／timeout／descendant cleanup 的等價規則。 |
| `…/skill-repository-standard.md:345` | CRLF/LF 固定位元組 | 「Windows CRLF inventory/module digests and Linux LF」；「never a mix」 | 保留 exact-byte 與完整 digest-pair 規則；將 Windows/Linux 特例改成每個受支援 checkout byte form 的 platform matrix，補 macOS checkout evidence。 |
| `…/skill-repository-standard.md:349` | CRLF/LF scanner 證據 | 「fixed Windows CRLF and Linux LF byte digests」 | 改為平台標記的 artifact digest model；不得以文字正規化取代 exact-byte evidence。 |
| `…/skill-repository-standard.md:357` | launcher、symlink、venv | 「Windows `skill-tools.cmd` is accepted only」；「Unix package launcher symlinks MAY be accepted」；「Python venv creation MUST use copy layout」 | 拆成 Windows `.cmd`、Unix symlink、Python venv 三種 adapter 規則；macOS 採 Unix 規則並需明列支援/測試。 |
| `…/skill-repository-standard.md:391` | Windows Core／Install Smoke | 「Windows Core MUST 在 Windows 上使用 SHA-256 驗證的…PowerShell 7」；「Windows Install Smoke MUST 保留…idempotence checks」 | 改為 Windows、Linux、macOS 各一個 required Core lane；保留 Windows SHA-256 PowerShell 規範為 Windows lane 附加條件。 |
| `…/skill-repository-standard.md:424` | OpenAI metadata 驗證 | 「`agents/openai.yaml` 時…`--allow-dirs=agents`」 | 改為只在 OpenAI/Codex adapter 存在時執行；Claude/Copilot adapter 應有各自受限目錄與 validator 契約。 |
| `…/skill-repository-standard.md:451` | Windows PowerShell 5.1 lane | 「Windows PowerShell 5.1、舊 Pester…lane MAY pin 舊版」 | 保留 Windows compatibility lane，但新增 Bash/Python/host-shell compatibility lane 的通用 schema；全部不得成為唯一 canonical release/security gate。 |
| `…/skill-repository-standard.md:675` | Windows parser 假設 | 「與受支援 Windows PowerShell parser 一致的 `OrdinalIgnoreCase`」 | 改為明示 parser semantics profile；Windows PowerShell profile 與 Linux/macOS runtime profile 都應有可驗證行為。 |
| `…/skill-repository-standard.md:739,750,756` | Windows gate 唯一性 | 「一般或手動 CI 均不得取代 required Windows gate」；「Windows Core job」 | 改為 required platform-gate matrix；保留 authority job 的唯一 canonical 身分，但不限定其 runner 為 Windows。 |
| `…/skill-repository-standard.md:858` | Windows byte tests | 「Windows byte-preservation tests」 | 擴成平台 byte-preservation tests；把 CRLF/LF 和 filesystem-sensitive cases 納入 matrix。 |
| `…/skill-repository-standard.md:929,933` | legacy `.agents` source path | 「不得讓既有只接受 `.agents/skills/<id>` 的 executable contract」 | 將 legacy path 視為一種 adapter/migration source；不得把 `.agents` 視為 AI 共通唯一位置。 |
| `…/skill-repository-standard.md:942` | 另行授權 | 「remote ruleset 的 required-context 對齊須另行授權」 | 保留外部 ruleset 寫入的明確授權邊界；三平台 rollout 與 ruleset changes 應以獨立 approval/change contract 實施。 |

補充：`…/skill-repository-standard.md:508,518` 也使用「另行授權」描述 deferred integration／consumer migration；它們不是 platform contract，但限制不能由 evaluator 或單一 repository 自行擴權。


### §19 Standard change contract 七步（原文核對）

1. 修改本 normative document。
2. 同一 PR 更新 `tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1`、`tests/standard-validation-resolver-hardening.Tests.ps1` 中受影響的 regression 與 machine-readable policy。
3. tool source／resolver behavior 變更時，同一 PR 更新 `scripts/Resolve-StandardValidationTool.ps1` trust anchor／adapter 與負向 regression。
4. workflow authority／merge enforcement 變更時，同一 PR 更新 workflow regression 與自動 authority job 契約；remote ruleset 的 required-context 對齊須另行授權並完成，在此之前不得宣稱 remote merge enforcement 已生效。
5. 說明對 reference implementation 與已 conformant repositories 的影響。
6. 重新執行 authority-level conformance regression。
7. 經 Human Release/Policy Review 後才可 merge／fan out。

## 6. 工具鏈、設定與 CI 現況


#### validation-toolchain.json

來源：`SyuanTsai-AI-Instructions/docs/standards/validation-toolchain.json`。

| 工具 | 版本／channel | 取得方式 | 完整性／平台相關欄位 |
|---|---|---|---|
| `skillspector` | `latest-stable`、`v-semver-release-only` | `NVIDIA/SkillSpector`；PyPI Simple index；verified wheelhouse、isolated venv | `pythonPackageIndex`、`onlyBinary`、`requireHashes`、closure hashes；未列 Windows-only 路徑。 |
| `skill-validator` | `latest-stable`、release semver | Go module `github.com/agent-ecosystem/skill-validator/cmd/skill-validator`；Go proxy/checksum DB | `goRuntimeVersion: latest-stable`、isolated module/build/temp cache、binary hash；未列 Windows-only 路徑。 |
| `skill-tools` | `latest-stable` | npm registry `https://registry.npmjs.org/`、isolated prefix、package lock | closure integrity、empty npm config/workdir；未列 Windows-only 路徑。 |
| `pester` | approved payload `6.2.0` | PowerShell Gallery | SHA-256 `0182e2…75229`；非 JSON 內 Windows-only，但實際 Standard/CI 對 Windows PowerShell 有硬性依賴。 |

toolchain 的 `compatibilityLane` 允許舊版 pin，但要求 explicit purpose，且 `mayBeCanonicalReleaseGate: false`。JSON 本身沒有 `windows`、`linux`、`macos` enum 或 Windows absolute path。

#### 其他 standards JSON/schema 的平台欄位

| 檔案 | 欄位／值 | 結論 |
|---|---|---|
| `…/docs/standards/schemas/standard-entry-binding-v1.schema.json:32-34` | `os` required；enum `windows`, `linux`, `macos` | 已有三平台 enum。 |
| `…/docs/standards/schemas/standard-entry-result-v1.schema.json:49-51` | `os` required；同一 enum | 已有三平台 enum。 |
| `…/docs/standards/standard-validation-contract-v1.json:50,94,119` | `platformArtifactTrustBoundary`、`in-root-unix-symlink-target-identities`、approved `os` runtime allowlist | 有 platform-aware 語意，但非 CI matrix。 |
| `…/docs/standards/validation-security-gate.json:159,283,293` | `approved-os-runtime`；roles `windows-core-authority`、`windows-install-smoke` | policy role 仍 Windows-specific。 |
| `…/docs/standards/schemas/validation-security-gate-v1.schema.json:350` | allowlist 固定 `approved-os-runtime`、`STANDARD_VALIDATION_*` | OS runtime 是抽象欄位，未列三平台 role。 |

其餘 `docs/standards/**/*.json` 未見真正 platform/OS/Windows 欄位或列舉；文字中出現 `repository`、`purpose` 等字串者不列為平台欄位。

#### 各 repository 的 standard-v1 pin

所有 source repository authority repository 均為 `https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git`；`standard-v1.json` 本身沒有平台欄位。

| Repository | authority commit | archive SHA-256 | authority files |
|---|---|---|---:|
| Skill-General | `8e627baf54bd6e47862e6291b25e71cc45a2f2b7` | `9aa4a7fc…ff99989` | 32 |
| Skill-Atlassian-Ecosystem | `098e40d26de585e5565a031d9b826454e6a34720` | `de7b7ca6…790a8e8` | 34 |
| Skill-Code-Collaboration | `8e627baf54bd6e47862e6291b25e71cc45a2f2b7` | `9aa4a7fc…ff99989` | 32 |
| Skill-Knowledge-Content | `8e627baf54bd6e47862e6291b25e71cc45a2f2b7` | `9aa4a7fc…ff99989` | 32 |
| Skill-Darktide-Translate | `a403abdf038a3346d775431a6908a71cc3d35a5b` | `17154929…411b2d3` | 14 |

`SyuanTsai-AI-Instructions` 是 authority repository，沒有 `config/standard-v1.json` 或 `scripts/Validate.ps1`。

#### Validate.ps1 內硬編 authority pins

| Repository | 位置 | 值 |
|---|---|---|
| Skill-General | `scripts/Validate.ps1:46,76,106,137,170,207` | `AuthorityCommit=513996…43583`；`Next=ea1d36…12930`；`Merged=053b80…49df8`；`Source=d54ef2…5d03e`；`Prepared=ff85d5…04ecd`；`Scoped=8e627b…2f2b7` |
| Skill-Atlassian-Ecosystem | `scripts/Validate.ps1:4655` | `approvedAuthorityCommit=098e40…34720` |
| Skill-Code-Collaboration | `scripts/Validate.ps1:35` | `AuthorityCommit=8aabd2…eb94b` |
| Skill-Knowledge-Content | `scripts/Validate.ps1:29` | `AuthorityCommit=8e627b…2f2b7` |
| Skill-Darktide-Translate | `scripts/Validate.ps1:4102` | `approvedAuthorityCommit=a403ab…35a5b` |

#### catalog 平台欄位

| Repository | 檔案 | 現值 |
|---|---|---|
| Skill-Code-Collaboration | `catalog/profiles.json:32-35` | `compatibility.platforms: ["windows"]` |
| Skill-Darktide-Translate | `catalog/profiles.json:32-35` | `compatibility.platforms: ["windows"]` |
| Skill-General | `catalog/*.json` | 無平台欄位 |
| Skill-Atlassian-Ecosystem | `catalog/*.json` | 無平台欄位 |
| Skill-Knowledge-Content | `catalog/*.json` | 無平台欄位 |

### CI 現況

Actions SHA 縮寫說明：checkout `3d3c42e…ba90b1`；setup-go `b7ad1da…54303e`；setup-node `49933ea…20020` 或 `949feb2…15c1`；upload-artifact `043fb46…c6a0a` 或 `cf430e0…46cd9`。皆為 full commit SHA pin。所有 checkout 均關閉 persisted credentials。

#### Skill-General

| workflow | job id | name | runs-on | 觸發 | needs/if | 主要腳本 | secrets | 快取 |
|---|---|---|---|---|---|---|---|---|
| `validate.yml` | `canonical-validation` | Skill-General Standard v1 | windows-latest | push/main、PR/main、dispatch | — | `scripts/Validate.ps1`、Pester、source tool resolution；upload artifact | `github.token` 用於 PowerShell download；後續清除 token | Go `false`；無其他 cache |
| 同上 | `repository-contract` | repository-contract | windows-latest | 同上 | needs canonical；`always()` | 轉述 canonical result | 無 | 無 |
| 同上 | `skill-validator` | skill-validator | windows-latest | 同上 | needs canonical；`always()` | 轉述 canonical result | 無 | 無 |
| 同上 | `skill-tools` | skill-tools | windows-latest | 同上 | needs canonical；`always()` | 轉述 canonical result | 無 | 無 |

#### Skill-Atlassian-Ecosystem

| workflow | job id | name | runs-on | 觸發 | needs/if | 主要腳本 | secrets | 快取 |
|---|---|---|---|---|---|---|---|---|
| `validate.yml` | `canonical-validation` | Atlassian Ecosystem Standard v1 | windows-latest | push/main、PR/main、dispatch | — | `scripts/Validate.ps1 -SourceConformance`；scanner evidence diagnostic | `GITHUB_TOKEN: github.token` | Go `false` |
| 同上 | `repository-contract` | repository-contract | ubuntu-latest | 同上 | needs canonical；`always()` | mirror source conformance | 無 | 無 |
| 同上 | `skill-validator` | skill-validator | ubuntu-latest | 同上 | needs canonical；`always()` | mirror source conformance | 無 | 無 |
| 同上 | `skill-tools` | skill-tools | ubuntu-latest | 同上 | needs canonical；`always()` | mirror source conformance | 無 | 無 |

#### Skill-Code-Collaboration

| workflow | job id | name | runs-on | 觸發 | needs/if | 主要腳本 | secrets | 快取 |
|---|---|---|---|---|---|---|---|---|
| `validate.yml` | `canonical-validation` | Code Collaboration Standard v1 | windows-latest | push/main、PR/main、dispatch | — | protected driver、`scripts/Validate.ps1`、artifact upload | `GITHUB_TOKEN: github.token` | Go `false`；Node package-manager `false` |
| 同上 | `repository-contract` | repository-contract | windows-latest | 同上 | needs canonical；`always()` | mirror canonical result | 無 | 無 |
| 同上 | `skill-validator` | skill-validator | windows-latest | 同上 | needs canonical；`always()` | mirror canonical result | 無 | 無 |
| 同上 | `skill-tools` | skill-tools | windows-latest | 同上 | needs canonical；`always()` | mirror canonical result | 無 | 無 |

#### Skill-Knowledge-Content

| workflow | job id | name | runs-on | 觸發 | needs/if | 主要腳本 | secrets | 快取 |
|---|---|---|---|---|---|---|---|---|
| `validate.yml` | `canonical-validation` | Knowledge & Content Standard v1 | windows-latest | push/main、PR/main、dispatch | — | protected driver、`scripts/Validate.ps1`、evidence upload | 無顯式 secret | Go `false` |
| 同上 | `repository-contract` | repository-contract | windows-latest | 同上 | needs canonical；`always()` | mirror canonical result | 無 | 無 |
| 同上 | `skill-validator` | skill-validator | windows-latest | 同上 | needs canonical；`always()` | mirror canonical result | 無 | 無 |
| 同上 | `skill-tools` | skill-tools | windows-latest | 同上 | needs canonical；`always()` | mirror canonical result | 無 | 無 |

#### Skill-Darktide-Translate

| workflow | job id | name | runs-on | 觸發 | needs/if | 主要腳本 | secrets | 快取 |
|---|---|---|---|---|---|---|---|---|
| `standard-v1-candidate-windows.yml` | `windows-latest-stable` | Darktide Translate Windows Latest Stable PowerShell | windows-latest | PR、push main、dispatch | — | `scripts/Validate.ps1`；run-owned directory cleanup | `GITHUB_TOKEN: github.token`，解析期暫存後清除 | Go `false` |

#### SyuanTsai-AI-Instructions

| workflow | job id | name | runs-on | 觸發 | needs/if | 主要腳本 | secrets | 快取 |
|---|---|---|---|---|---|---|---|---|
| `pr8-powershell-validation.yml` | `windows-core` | Windows Core | windows-latest | push main、PR main、dispatch | — | authority gate、Pester、PowerShell syntax/whitespace、fixture evidence | 無 | 無 |
| `standards-conformance.yml` | `standards-conformance` | Standard v1 authority gate (manual) | windows-latest | dispatch | — | authority gate、Pester、whitespace | 無 | 無 |
| `syp101-production-smoke.yml` | `production-install-smoke` | Windows Install Smoke | windows-latest | push main、PR main、dispatch | — | production lock、`test-syp101-production-smoke.ps1`、artifact upload | 無 | 無 |
| `syp86-production-lock.yml` | `validate-lock` | Production lock check | windows-latest | path-filtered push main/syp-86/syp-101、dispatch | — | `update-skills-catalog-lock.ps1 -Check` | 無 | 無 |
| `validator-maintenance-producer.yml` | `diagnostic-producer` | Manual untrusted validator diagnostic | windows-latest | dispatch | — | `Invoke-StandardValidatorMaintenanceProducer.ps1`、artifact upload | 無 | 無 |

#### Runner 彙總

| runner | job 數 |
|---|---:|
| windows-latest | 19 |
| ubuntu-latest | 3 |
| macOS | 0 |
| 合計 | 22 |

#### Required context 分析

| Repository | `repository-contract`／`skill-validator`／`skill-tools` | 是否只轉述 canonical 結果 | 是否依賴 Windows |
|---|---|---|---|
| Skill-General | 三個 projection jobs | 是 | 是；canonical 與 projection 都 Windows |
| Skill-Atlassian-Ecosystem | 三個 Ubuntu projection jobs | 是 | 是；projection 為 Ubuntu，但唯一 canonical validator 是 Windows |
| Skill-Code-Collaboration | 三個 Windows projection jobs | 是 | 是 |
| Skill-Knowledge-Content | 三個 Windows projection jobs | 是 | 是 |
| Skill-Darktide-Translate | 未建立這三個 job/context | 不適用 | 唯一 job 為 Windows |
| SyuanTsai-AI-Instructions | 未建立這三個 job/context | 不適用 | Windows Core 為 authority gate |


## 7. 與 Jira 記錄不一致、後續項目

### 與 Jira 記錄不一致
| 位置 | Jira 記載 | 實際（origin/main） |
| --- | --- | --- |
| SYP-356 | `manage-confluence-docs-as-code` 的 description 宣告 Windows-only | `901c001` 已無此宣告；Atlassian 的 SKILL.md 與 README 都沒有 Windows-only 宣告（README:122 只描述 CI 在 Windows 執行） |
| SYP-350 留言「待決定事項的決議」第 2 項 | 「另行授權」只出現在 CI 章節與 §19 第 4 項 | Standard L508、L518 也使用「另行授權」，用於 deferred integration／consumer migration，不是平台條文 |
| SYP-352 注意事項 | Skill-General 的 authority 由 `scripts/Validate.ps1` 的 `AuthorityCommit` 決定 | `config/standard-v1.json` 綁定 `8e627baf…`；Atlassian 綁定 `098e40d2…`、Darktide 綁定 `a403abdf…`，各 repo pin 不同（詳見 §6） |

### 後續項目（不屬於 S1 範圍，未處理）
1. **Skill-Code-Collaboration authority pin 不一致**：`config/standard-v1.json` 綁定 `8e627baf…`，但 `scripts/Validate.ps1:35` 的 ordinary run 常數是 `8aabd226…`。`Assert-AuthorityConfig`（`Validate.ps1:364–381`）會拒絕任何平台上的本機 ordinary run；CI 走 source-validation 路徑所以沒有發現。建議併入 S3（D6）。
2. **AI-Instructions 的 Pester 失敗明細**：241 個失敗沒有錯誤內容，S4 開始前應以能逐筆輸出錯誤的方式重跑。
3. **Skill-Darktide-Translate 本機 git 設定**：`remote.origin.fetch` 含已不存在的 `codex/syp-112-115` refspec，導致 `git fetch` 失敗（本機設定，需使用者同意才修改）。

## 8. 未驗證事項

- macOS：本次未實跑（依範圍調整移到 S3），包含 SkillSpector、程序隔離、APFS 大小寫行為。
- `FileShare`、原子 rename、開啟中檔案刪除在 Linux／macOS 的實際互斥效果，需在 S4 以多程序競爭測試確認。
- `[Environment]::SetEnvironmentVariable(..., 'User')` 在 Unix 的實際行為仍未實測（S6）。
- 各 repo 遠端 ruleset 實際設定了哪些 required checks，未讀取（S3）。
- §4 工時是推估，不是實測。

## 附錄 A：Linux 實跑紀錄

| Repository | 第 1 輪 run | 第 2 輪 run |
| --- | --- | --- |
| Skill-General | 41399729293 | 41401645015 |
| Skill-Atlassian-Ecosystem | 41399715493 | 41401630934 |
| Skill-Code-Collaboration | 41399719813 | 41401635349 |
| Skill-Knowledge-Content | 41399730800 | 41401648980 |
| Skill-Darktide-Translate | 41399723475 | 41401640070 |
| SyuanTsai-AI-Instructions | 41399736577 | 41401654384 |

run 位於各 repository 的 Actions 頁面（`https://github.com/SyuanTsai/<Repository>/actions/runs/<run id>`）；拋棄式分支刪除後 run 紀錄仍保留。

## 附錄 B：AI-Instructions 非測試腳本逐檔清單（351-A）

### 摘要

- 盤點範圍：`SyuanTsai-AI-Instructions/` 內 Git 追蹤的 `.ps1`、`.psm1`。
- 非測試檔：**51 個**；均已讀取，無「未讀取」檔案。
- 測試範圍檔：**46 個**，依要求僅彙總。
- 主分類：

  - **僅 Windows：3 個**
  - **三平台行為不同：28 個**
  - **已跨平台：20 個**

- 處理建議：

  - **保留：20 個**
  - **改寫：13 個**
  - **替換：18 個**

- 總估計修改與測試成本：**219.5 小時**。此數字是本次技術盤點要求的成本估算，不是 SYP 工時或 worklog。
- 主要不確定性集中於 Unix 檔案鎖、symlink/hard-link 防護、macOS 程序樹收斂與原子發布安全邊界。

最大風險前 5 名：

1. `scripts/bootstrap-ai-instructions.ps1`：Windows handle-bound rename/delete、DACL 與 `kernel32`／`advapi32` 深度耦合；非 Windows 明確 fail closed。
2. `scripts/installer-safe-mutation.psm1`：安全寫入、刪除、檔案身分及 link-count 驗證全部建立在 Win32 handle 上。
3. `scripts/Invoke-StandardValidation.ps1`：雖已有 Windows/Linux 分支，但 Unix 分支使用 Linux `prctl`、`/proc` 等能力，macOS 不具等效實作。
4. `scripts/install-ai-instructions-bootstrap.ps1`：大量路徑、鎖與交易流程依賴 Windows-only mutation module。
5. `scripts/StandardSemanticBridge.psm1`：Windows Job Object 與 Linux PID namespace 都有設計，macOS 缺少對等的強制程序隔離與後代程序清理。

### 逐檔

| 檔案 | 分類 | 具體寫法（行號） | 建議 | 工時(h) | 不確定性 | Linux/macOS 最可能失敗方式 |
|---|---|---|---|---:|---|---|
| `delivery/SYP-216/test-candidate-user-lifecycle.ps1` | 三平台行為不同 | 檔案系統路徑固定用 `OrdinalIgnoreCase`：81、111–112、246 | 改寫 | 1.5 | 低 | 大小寫不同的 Unix 路徑可能被錯認為同一路徑或錯誤落入 repository 邊界。 |
| `docs/delivery/syp-195/verify-managed-candidate.ps1` | 已跨平台 | `GetFullPath`、`Join-Path`：10–20；換行正規化：108 | 保留 | 0.5 | 低 | 本檔沒有直接平台失敗；若匯入的下游 module 不支援 Unix，才會在下游失敗。 |
| `scripts/agent-artifact-remediation.psm1` | 三平台行為不同 | 已有平台 comparer：154–159；但硬編碼 `.codex\...`：187，無條件忽略大小寫：217 | 改寫 | 3 | 中 | 反斜線可能成為檔名字元，造成 manifest 找不到；大小寫邊界判斷亦可能錯誤。 |
| `scripts/agent-environment-reconciler.psm1` | 三平台行為不同 | 平台 comparer：21–26；`ReparsePoint`：126、252；以 `FileShare.None` 作 install lock：738、743–744 | 替換 | 8 | 高 | Unix `FileShare.None` 不提供相同強制鎖，兩個更新程序可能同時修改 user Skills。 |
| `scripts/ai-instructions-rollout.psm1` | 三平台行為不同 | 路徑一律忽略大小寫：18、81–83；硬編碼反斜線：264、288、355 | 改寫 | 4 | 中 | repository、manifest 與 user Skill 路徑可能指向含反斜線的錯誤名稱。 |
| `scripts/ai-instructions-runtime-contract.psm1` | 三平台行為不同 | 已有 separator comparer：46；`ReparsePoint`：52、67；暫存輸出使用 `FileShare.None`：673 | 改寫 | 3 | 中 | Unix 讀者可能在 JSON 暫存檔尚未寫完時開啟檔案，Windows 上的排他保證不存在。 |
| `scripts/ai-instructions-updater.psm1` | 三平台行為不同 | 硬編碼 runtime 路徑：258–262、274–277、298、358；多個 `FileShare.None` install lock：381、388、499、533 | 替換 | 8 | 高 | 先因反斜線路徑找不到 module，或在並行更新時因 advisory lock 失去互斥。 |
| `scripts/Assert-StandardValidatorMaintenanceInputs.ps1` | 已跨平台 | `Add-Type -AssemblyName System.IO.Compression.FileSystem`：138，並非 P/Invoke；無 Windows-only API | 保留 | 0.5 | 低 | 未見直接平台失敗。 |
| `scripts/Assert-StandardValidatorMaintenanceReport.ps1` | 已跨平台 | 純物件／JSON schema 驗證：23–37、87–105；無檔案系統平台假設 | 保留 | 0.5 | 低 | 未見直接平台失敗。 |
| `scripts/bootstrap-ai-instructions.ps1` | 僅 Windows | `kernel32` P/Invoke：202–250；`advapi32`：261–266；非 Windows 原子發布明確拋錯：2511；Windows 原子刪除明確拋錯：2835–2837 | 替換 | 24 | 高 | 首次進入 managed-file 發布或刪除即因要求 Windows handle-bound mutation 而終止。 |
| `scripts/bootstrap-ai-instructions-installed.ps1` | 三平台行為不同 | 硬編碼 `catalog\...`：65–66；`FileShare.None`：363；選擇 `powershell.exe`／`pwsh.exe`：387–390 | 改寫 | 4 | 中 | Unix 上可能找不到以反斜線組成的 catalog 路徑，或找不到 `$PSHOME/pwsh.exe`。 |
| `scripts/bootstrap-ai-instructions-multisource.ps1` | 三平台行為不同 | UserProfile 預設：10；暫存目錄 containment 固定 `OrdinalIgnoreCase`：351–352 | 改寫 | 1.5 | 低 | 大小寫不同的暫存路徑可能通過或未通過錯誤的 containment 判斷。 |
| `scripts/cleanup-ai-instructions-pollution.ps1` | 三平台行為不同 | runtime 路徑含反斜線：52、61；Git index／operation locks 用 `FileShare.None`：179、248、333；無條件忽略大小寫：459–475 | 替換 | 10 | 高 | 可能找不到 runtime module，或多個 cleanup 同時操作 Git index，破壞交易隔離。 |
| `scripts/Get-StandardPowerShellSyntaxProof.ps1` | 已跨平台 | UTF-8 console：8–9；PowerShell AST／文字分析：25、56–84；沒有啟動 Windows executable | 保留 | 0.5 | 低 | 未見直接平台失敗。 |
| `scripts/Get-StandardValidatorMaintenanceEvidence.ps1` | 三平台行為不同 | `ReparsePoint` ancestor 檢查：57；終止條件固定忽略大小寫：62；create-only 檔案使用 `FileShare.None`：74 | 替換 | 4 | 中 | Unix symlink/race 防護沒有 handle-bound 保證，證據根目錄可能在檢查後被替換。 |
| `scripts/install-ai-instructions-bootstrap.ps1` | 三平台行為不同 | 多處無條件 `OrdinalIgnoreCase`：50、96、148；`FileShare.None`：243、280、447、530；反斜線路徑：484、490–495 | 替換 | 12 | 高 | 前段可能找不到檔案；即使找到，安全 mutation module 仍會在非 Windows 明確拒絕。 |
| `scripts/installer-safe-mutation.psm1` | 僅 Windows | `kernel32` P/Invoke：142–182；C# 路徑 `TrimEnd('\\')`：191；非 Windows 明確拋錯：737–739；路徑轉成反斜線：744 | 替換 | 16 | 高 | `Set-InstallerSafeFileBytes` 一進入即拋出「requires Windows」。 |
| `scripts/invoke-ai-instructions-rollout.ps1` | 已跨平台 | 純 wrapper，參數與 module 路徑透過 `Join-Path`；無平台 API | 保留 | 0.5 | 低 | 本檔本身無直接失敗；rollout module 的路徑假設會在下游暴露。 |
| `scripts/Invoke-FocusedLinuxContainment.ps1` | 已跨平台 | 路徑均以 `Join-Path`：6–12；install-root prefix 使用 `DirectorySeparatorChar`：50 | 保留 | 1 | 中 | 本檔可啟動；非 Linux 平台最可能由被測 capability 回報不適用或不可用。 |
| `scripts/Invoke-PesterShardProcess.ps1` | 已跨平台 | Win32 P/Invoke 僅在 Windows 載入：59–60、107–124；平台分支：441、457、510；Unix 使用 identity-checked fallback：550–552 | 保留 | 2 | 中 | 最可能是 Unix fallback 無法完整收斂已脫離父程序的後代程序，而不是載入 `kernel32` 失敗。 |
| `scripts/Invoke-RoutineSemanticScan.ps1` | 三平台行為不同 | key 檔拒絕 `ReparsePoint`：107；輸出使用 `FileShare.None`：132 | 改寫 | 2 | 中 | 輸出檔在 Unix 沒有 Windows 等級的排他分享保證，可能被並行讀取或開啟。 |
| `scripts/Invoke-StandardAuthorityGate.ps1` | 三平台行為不同 | 平台 comparer：61–62、216–217；Linux `/proc`：1518；Linux `stat/chmod`：1654、1684；`unshare`：1779 | 替換 | 10 | 高 | macOS 被視為 Unix，但沒有 `/proc`、Linux cgroup 與 `unshare --pid`，containment gate 會 fail closed。 |
| `scripts/Invoke-StandardStaticScan.ps1` | 三平台行為不同 | `ReparsePoint`：26；路徑 containment 固定忽略大小寫：51–52、149、186、201；輸出 `FileShare.None`：260 | 改寫 | 3 | 中 | case-sensitive volume 上可能把不同路徑錯認為 scanner、working directory 或 candidate 內路徑。 |
| `scripts/Invoke-StandardValidation.ps1` | 三平台行為不同 | Windows Job Object：129、177–194；Linux `prctl/waitpid`：259–275；`/proc`：3092–3098；Unix `kill` 路徑：3137–3157；FileShare 差異已局部分支：4237–4243 | 替換 | 16 | 高 | macOS 進入 `PlatformID.Unix` 分支後呼叫 Linux-only `prctl` 或依賴 `/proc`，導致 supervisor 初始化失敗。 |
| `scripts/Invoke-StandardValidatorMaintenanceProducer.ps1` | 已跨平台 | 純參數、JSON 與 report 產生；無平台檔案鎖或 executable 假設 | 保留 | 0.5 | 低 | 未見直接平台失敗。 |
| `scripts/Invoke-StandardValidatorMaintenanceProtectedConsumer.ps1` | 已跨平台 | 純 protected-caller orchestration；無 Windows-only API | 保留 | 0.5 | 低 | 未見直接平台失敗；下游 evidence acquisition 仍有 Unix 檔案安全差異。 |
| `scripts/Invoke-ThirdPartySourceChecks.ps1` | 已跨平台 | 平台式路徑比較：20；根路徑使用 `DirectorySeparatorChar`：18 | 保留 | 1 | 低 | 未見直接平台失敗。 |
| `scripts/license-delivery.psm1` | 已跨平台 | repository-relative 路徑刻意拒絕反斜線：5；`ReparsePoint` 拒絕：55；處理目的在拒絕 linked input | 保留 | 1 | 低 | Unix symlink 會被拒絕，符合此檔目前的安全策略。 |
| `scripts/Prepare-StandardSemanticScanEvidence.ps1` | 三平台行為不同 | 平台 comparer：36–38；`ReparsePoint`：46、54；來源檔以 `FileShare.None` 開啟：207；輸出同樣排他：352 | 替換 | 5 | 高 | Unix advisory sharing 無法證明掃描輸入在讀取期間未被另一程序開啟修改。 |
| `scripts/repo-shared-skills-migration.psm1` | 僅 Windows | `CreateFileW`：38；`GetFileInformationByHandle`：43；非 Windows 明確 fail closed：103–105；路徑固定忽略大小寫：124 | 替換 | 8 | 高 | repository/user root 身分檢查直接以「cannot be verified」終止。 |
| `scripts/Resolve-StandardValidationTool.ps1` | 三平台行為不同 | Unix 被合併成單一值：38–40；`/proc`：534–538、555；Linux `setsid`：600；`/bin/sh`：604–613；`CreateNoWindow`：563、619 | 替換 | 12 | 高 | macOS 沒有 `/proc`，且通常沒有 Linux `setsid` 路徑與相同 process-group 掃描方式。 |
| `scripts/RoutineSemanticScan.psm1` | 三平台行為不同 | `ReparsePoint`：132；`ProcessStartInfo.CreateNoWindow`：321 | 改寫 | 1.5 | 低 | macOS/Linux 通常忽略 hidden-window 設定；失敗多半表現為該設定無效果而非例外。 |
| `scripts/safe-zip.psm1` | 三平台行為不同 | ZIP collision 固定大小寫不敏感：156–158；destination containment 固定忽略大小寫：186；輸出 `FileShare.None`：205 | 改寫 | 2 | 中 | case-sensitive volume 上 containment 比較可能接受錯誤大小寫路徑；寫入期間亦無強制 share lock。 |
| `scripts/skills-catalog-contract.psm1` | 已跨平台 | repository path 刻意要求 `/`：113–114；URI host/repository 比較：148–150，非本機檔案系統比較 | 保留 | 1 | 低 | 未見直接平台失敗。 |
| `scripts/skills-selection.psm1` | 已跨平台 | Windows 偵測：20；macOS 明確以 `OSPlatform.OSX` 偵測：25；平台能力集中處理 | 保留 | 1 | 低 | 未見直接平台失敗。 |
| `scripts/skills-source-acquisition.psm1` | 三平台行為不同 | Windows-specific regular-file 分支：131–134；平台 comparer：172–173；但另有固定 ignore-case containment：562、705；`FileShare.None`：640 | 替換 | 6 | 高 | Unix 上 archive staging containment 可能受大小寫判斷影響，且 extract lock 不具強制性。 |
| `scripts/skills-source-composition.psm1` | 三平台行為不同 | source/destination containment 固定忽略大小寫：37–38；archive output `FileShare.None`：53 | 改寫 | 2 | 中 | 大小寫不同的 source/destination 可能被誤判為巢狀，或 archive 在寫入中被讀取。 |
| `scripts/skills-source-retrieval.psm1` | 已跨平台 | URI host 與 `.git` 比較：13、21；不涉及本機 path case | 保留 | 0.5 | 低 | 未見直接平台失敗。 |
| `scripts/skills-source-routing.psm1` | 已跨平台 | 純 repository-relative path 與 stable ID 驗證；無平台 API | 保留 | 0.5 | 低 | 未見直接平台失敗。 |
| `scripts/StandardEntryPointContract.psm1` | 已跨平台 | 明確讀取 `$IsWindows/$IsLinux/$IsMacOS`：20–25；separator 與 comparer 分支：359–360；`ReparsePoint`：245–259 | 保留 | 2 | 低 | PowerShell 7 三平台可正確識別；只有缺少 `$IsMacOS` 的非標準舊 host 才可能把 macOS fallback 成 Linux。 |
| `scripts/StandardSemanticBridge.psm1` | 三平台行為不同 | Windows P/Invoke 有 guard：29–30、77–94；Linux `/proc` namespace：1058–1088；Windows Job Object：1734–1748；Unix namespace 流程：1762–1765 | 替換 | 12 | 高 | macOS 無 Linux PID namespace；若要求強隔離，bridge 最可能回報 capability unavailable 或 fail closed。 |
| `scripts/syp101-production-smoke-contract.psm1` | 已跨平台 | Git 呼叫使用參數陣列與 repository 參數；無路徑分隔或 executable 假設 | 保留 | 0.5 | 低 | 本檔本身無直接平台失敗。 |
| `scripts/test-production-cutover.ps1` | 已跨平台 | 以 `Join-Path` 呼叫 smoke script：9 | 保留 | 0.5 | 低 | wrapper 本身可執行；下游 smoke script 的 Windows 路徑假設仍會使整體測試失敗。 |
| `scripts/Test-StandardEntryPointResult.ps1` | 已跨平台 | module 路徑以 `Join-Path`：9；無平台 API | 保留 | 0.5 | 低 | 未見直接平台失敗。 |
| `scripts/test-syp101-production-smoke.ps1` | 三平台行為不同 | 硬編碼 `scripts\...`、`hooks\...`、`.codex\...`：87–88、117；證據固定 `$PSHOME/pwsh.exe`：202；cleanup 固定 ignore-case：212 | 改寫 | 2 | 低 | 最早可能因含反斜線的 script 路徑不存在而停止。 |
| `scripts/third-party-skill-source.psm1` | 三平台行為不同 | `ReparsePoint`：30、73、93、102；暫存 containment 固定忽略大小寫：70；cleanup 依屬性檢查 | 替換 | 4 | 高 | symlink 檢查與後續刪除之間存在 Unix TOCTOU 空窗，可能 fail closed 或清理失敗。 |
| `scripts/update-agent-environment.ps1` | 三平台行為不同 | runtime read lock `FileShare.Read`：109；cleanup prefix 固定忽略大小寫：179；`ReparsePoint`：181 | 替換 | 5 | 高 | update/cleanup 可能與另一程序並行，或因大小寫不同而拒絕清除合法暫存目錄。 |
| `scripts/update-ai-instructions.ps1` | 三平台行為不同 | runtime module 路徑含反斜線：49；read lock `FileShare.Read`：88；temp containment 固定忽略大小寫：136；`ReparsePoint`：140 | 替換 | 6 | 高 | Unix 最可能先找不到 runtime module，或在 update/install 競爭時失去 Windows lock 保證。 |
| `scripts/update-skills-catalog-lock.ps1` | 已跨平台 | 預設路徑雖含反斜線：17–19，但 PowerShell `Join-Path` 可接受；實際 source path 轉為 `DirectorySeparatorChar`：101；換行正規化：128 | 保留 | 1 | 中 | 需實跑確認 PowerShell 7 對這些 `Join-Path` child 字串的 Unix 正規化；未見必然失敗。 |
| `scripts/Validate-ThirdPartySkillSource.ps1` | 三平台行為不同 | 平台 comparer：20；create-only output 使用 `FileShare.None`：33 | 改寫 | 2 | 中 | Unix 上輸出建立仍具 `CreateNew`，但寫入期間沒有 Windows 強制排他分享保證。 |
| `scripts/Validate-UpstreamAdapter.ps1` | 三平台行為不同 | output reservation `FileShare.None`：32；`ReparsePoint`：155、442；已有平台 comparer：459–460；physical path 檢查：481–484 | 替換 | 6 | 高 | Unix symlink/hard-link substitution 無 handle-bound 驗證，檢查後路徑可能被替換。 |

**核對結果：清單檔數 51 = `git ls-files` 過濾後非測試 PowerShell 檔數 51。**

### 測試檔彙總

- 測試範圍 PowerShell 檔：**46 個**。
- 含僅 Windows 寫法或 Windows-only fixture 內容：**8 個**。
- 代表例子：

  - `tests/bootstrap-ai-instructions.Tests.ps1`：`powershell.exe`（4、2303、2377）、`Get-Acl`／`Set-Acl`（2823–2825）。
  - `tests/standard-validation-resolver-hardening.Tests.ps1`：`kernel32.dll` P/Invoke fixture（654）。
  - `tests/syp214-user-only.Tests.ps1`：`GetFileInformationByHandle`／`GetFileType` P/Invoke（189–198）、ACL 操作（2224–2226）。
  - `tests/update-ai-instructions.Tests.ps1`：直接呼叫 `powershell.exe`（604）。
  - `tests/install-ai-instructions-bootstrap.Tests.ps1`：多個 Windows command/path fixture（269–342）。

- 上述 8 個並不全是無條件執行：部分是平台 guard、fixture 字串或專門驗證 Windows contract。
- 另有 **22 個**測試檔包含 `FileShare`、`ReparsePoint`、Windows 環境變數、大小寫比較、`.exe`、`/proc` 等三平台差異候選。
- 對三平台測試的主要影響：

  - Linux/macOS 應將真正的 Windows ACL、P/Invoke、Windows PowerShell 測試明確標記為 Windows-only，而不是靠 command-not-found 間接跳過。
  - `FileShare.None` 的 lock 測試不能在 Unix 上視為同等安全證據；需另有跨程序競爭測試。
  - Linux containment 測試不可直接代表 macOS；`/proc`、cgroup、PID namespace 與 `prctl` 都缺少 macOS 對等能力。
  - symlink 與 hard-link 安全測試需在真實 Linux、macOS 檔案系統執行，不能只用 mock 的 `FileAttributes` 或 `LinkType`。

### 跨檔共通模式

##### Windows handle-bound mutation

受影響核心：

- `scripts/bootstrap-ai-instructions.ps1`
- `scripts/installer-safe-mutation.psm1`
- `scripts/repo-shared-skills-migration.psm1`
- 間接影響 `scripts/install-ai-instructions-bootstrap.ps1`

目前設計使用 Win32 handle、`CreateFileW`、`SetFileInformationByHandle`、DACL 與 file identity/link-count。方向上需建立平台 abstraction：

- Windows 保留現有 handle-bound 實作。
- Unix 使用 `openat`/`renameat`/`unlinkat`、`O_NOFOLLOW`、`fstat`/`lstat`、device/inode、`st_nlink` 與 `UnixFileMode`。
- 所有 mutation 應以已開啟的 parent directory/file descriptor 為權威，避免「先檢查 path、再操作 path」的 TOCTOU。

##### `FileShare` 當作鎖或穩定性證據

主要受影響：

- `agent-environment-reconciler.psm1`
- `ai-instructions-updater.psm1`
- `ai-instructions-runtime-contract.psm1`
- `cleanup-ai-instructions-pollution.ps1`
- `install-ai-instructions-bootstrap.ps1`
- `Get-StandardValidatorMaintenanceEvidence.ps1`
- `Invoke-RoutineSemanticScan.ps1`
- `Invoke-StandardStaticScan.ps1`
- `Prepare-StandardSemanticScanEvidence.ps1`
- `safe-zip.psm1`
- `skills-source-acquisition.psm1`
- `skills-source-composition.psm1`
- `update-agent-environment.ps1`
- `update-ai-instructions.ps1`
- `Validate-ThirdPartySkillSource.ps1`
- `Validate-UpstreamAdapter.ps1`

方向：

- `CreateNew` 可繼續作名稱保留，但不能等同跨平台 exclusive lock。
- 需要真正互斥時，Linux/macOS 使用 advisory `flock`/`fcntl`，並要求所有參與者遵守同一協定。
- 安全證據不能只記錄「成功以 `FileShare.None` 開啟」；應記錄平台、lock primitive、鎖定檔身分與競爭測試結果。

##### `ReparsePoint`、symlink 與 hard link

主要受影響：

- agent environment、bootstrap、cleanup、source acquisition、third-party source、validator、adapter、ZIP extraction 等檔案。
- `Invoke-PesterShardProcess.ps1` 與 `Invoke-StandardValidation.ps1` 已另外檢查 `LinkType`，但 Unix 上的 provider 資訊仍不足以構成原子安全邊界。

方向：

- 將「拒絕 `ReparsePoint`」抽象成「拒絕任何 symlink/junction/reparse-backed component」。
- Unix 使用 `lstat` 與 `O_NOFOLLOW`；需要防 hard link 時驗證 `st_nlink`、device/inode。
- 目錄 traversal 應逐層由 directory descriptor 開啟，不依賴一次性的字串路徑檢查。

##### 路徑分隔與大小寫

高密度出現在：

- `agent-artifact-remediation.psm1`
- `ai-instructions-rollout.psm1`
- `ai-instructions-updater.psm1`
- `bootstrap-ai-instructions-installed.ps1`
- `cleanup-ai-instructions-pollution.ps1`
- `install-ai-instructions-bootstrap.ps1`
- `test-syp101-production-smoke.ps1`
- 多個 source staging／validation 檔

方向：

- 本機實體路徑一律使用 `Join-Path`、`DirectorySeparatorChar` 與平台 comparer。
- Git、ZIP、manifest 等邏輯相對路徑維持 `/`，但在接觸本機檔案系統的單一邊界轉換。
- 不可用 `OrdinalIgnoreCase` 作所有本機 path containment；Windows 與 case-insensitive volume 才使用對應 comparer。

##### 程序樹 containment

受影響：

- `Invoke-PesterShardProcess.ps1`
- `Invoke-StandardAuthorityGate.ps1`
- `Invoke-StandardValidation.ps1`
- `Resolve-StandardValidationTool.ps1`
- `StandardSemanticBridge.psm1`

方向：

- Windows：Job Object。
- Linux：process group、subreaper、cgroup 或 PID namespace。
- macOS：process group/session 加上保守的 PID/start-time identity 驗證；若需求是不可逃逸的強隔離，應改由外部 sandbox/container，而非把 Linux `/proc` 設計直接套到 macOS。
- capability receipt 必須區分 `windows-job-object`、`linux-namespace/cgroup`、`macos-process-group`，不能只用 `Unix`。


## 附錄 C：5 個 Skill repository 非測試腳本逐檔清單（351-B）

### 摘要

本盤點全程唯讀、未連網、未執行測試或 Git 寫入。清單來源為各 repository 的 `git ls-files`；79 個範圍內檔案均已讀取，沒有「未讀取」項目。

分類欄順序為「僅 Windows／三平台行為不同／已跨平台」。

| Repository | 檔案數 | 分類數（1／2／3） | 建議數（保留／改寫／替換） | 估計工時(h) |
|---|---:|---:|---:|---:|
| Skill-General | 9 | 0／5／4 | 4／5／0 | 24 |
| Skill-Atlassian-Ecosystem | 34 | 2／11／21 | 21／10／3 | 107 |
| Skill-Code-Collaboration | 8 | 0／3／5 | 5／3／0 | 18.5 |
| Skill-Knowledge-Content | 6 | 0／3／3 | 3／3／0 | 17 |
| Skill-Darktide-Translate | 22 | 4／5／13 | 13／6／3 | 95.5 |
| **全體** | **79** | **6／27／46** | **46／27／6** | **262** |

> 工時是修改與 Windows、Linux、macOS 測試的粗估，不是 SYP 工時紀錄或 worklog。

最大風險前 5 名：

1. `Skill-Atlassian-Ecosystem/scripts/Validate.ps1`：入口第 49 行直接拒絕非 Windows，且核心隔離仍依賴 Windows token、Job Object、ACL；Linux/macOS CI 無法進入驗證。
2. `Skill-Darktide-Translate/scripts/Validate.ps1`：第 43–44 行直接拒絕非 Windows，並大量依賴 `kernel32`、`advapi32`、ACL 與 `pwsh.exe`。
3. `Skill-Atlassian-Ecosystem/scripts/Invoke-StandardValidation.ps1`：把所有 `PlatformID.Unix` 視為 Linux，使用 `prctl`、`/proc`、PID namespace；macOS 最可能在 process containment 階段失敗。
4. `Skill-Atlassian-Ecosystem/scripts/Invoke-SourceConformance.ps1`：第 34 行直接拒絕非 Windows，使原本已有平台比較分支的來源驗證完全無法在 Linux/macOS 啟動。
5. `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/PathSafety.psm1`：Unix 的實體檔案 identity 分支直接回傳 `false`，無法辨認 hard link／同 inode 別名，會削弱來源與目的地同檔保護。

### 逐檔

##### Skill-General

| 檔案 | 分類 | 具體寫法（行號） | 建議 | 工時(h) | 不確定性 | Linux/macOS 最可能失敗方式 |
|---|---|---|---|---:|---|---|
| `Skill-General/scripts/CorePesterIntegrity.psm1` | 2 三平台行為不同 | 固定要求 `pwsh.exe`（138–139）；路徑一律 `OrdinalIgnoreCase`（161–162、231、303） | 改寫 | 8 | 高 | 找不到名為 `pwsh.exe` 的 runtime，或把 Unix 上大小寫不同的路徑誤認為同一路徑。 |
| `Skill-General/scripts/Invoke-CorePester.ps1` | 2 三平台行為不同 | 路徑 containment 固定 `OrdinalIgnoreCase`（209、340）；`FileShare.Read`（459） | 改寫 | 4 | 中 | 大小寫不同的測試或 ledger 路徑可能錯誤通過 containment。 |
| `Skill-General/scripts/Prepare-PesterRuntime.ps1` | 2 三平台行為不同 | runtime／owned root 固定 `OrdinalIgnoreCase`（20、29）；staging containment 同樣忽略大小寫（84） | 改寫 | 3 | 中 | 大小寫不同的 runtime 或 staging 路徑可能被誤認為相同。 |
| `Skill-General/scripts/SourceToolRoots.psm1` | 2 三平台行為不同 | 額外使用 `LOCALAPPDATA`（22）；允許根路徑固定忽略大小寫（34） | 改寫 | 2 | 中 | Unix 上主要退回 temp，但大小寫不同的工具根可能被錯誤授權。 |
| `Skill-General/scripts/Test-SkillGeneral.ps1` | 3 已跨平台 | `GetRelativePath` 後以平台 separator 正規化（366）；拒絕 symlink/reparse（349、354） | 保留 | 1 | 低 | 最可能是特定 Unix provider 未回報 link metadata 而保守拒絕。 |
| `Skill-General/scripts/Validate.ps1` | 2 三平台行為不同 | `CreateNoWindow`（319、367）；路徑比較已有 `$IsWindows` 分支（474、481） | 改寫 | 3 | 低 | 驗證可執行，但子程序隱藏視窗語意在 Unix 無效或不同。 |
| `Skill-General/skills/manage-task-handoff/scripts/HandoffRecordCore.psm1` | 3 已跨平台 | 未見 Windows API、環境目錄或 Windows 路徑假設 | 保留 | 1 | 低 | 未見明確平台失敗點；主要風險是尚未實跑的日期／編碼差異。 |
| `Skill-General/skills/manage-task-handoff/scripts/LegacyNotionHandoffReplay.psm1` | 3 已跨平台 | 未見 Windows 專屬寫法；RFC3339 處理為純資料邏輯（145） | 保留 | 1 | 低 | 未見明確平台失敗點。 |
| `Skill-General/skills/operate-environment-authorized-sql/scripts/Test-Contract.ps1` | 3 已跨平台 | `Join-Path`（108）；`ReparsePoint` 用於拒絕 symlink 輸入（104） | 保留 | 1 | 低 | Unix provider 若無法可靠回報 symlink，可能保守判定輸入無效。 |

核對：**清單檔數 9 = `git ls-files` 範圍內檔數 9**。

##### Skill-Atlassian-Ecosystem

| 檔案 | 分類 | 具體寫法（行號） | 建議 | 工時(h) | 不確定性 | Linux/macOS 最可能失敗方式 |
|---|---|---|---|---:|---|---|
| `Skill-Atlassian-Ecosystem/scripts/Invoke-ParallelSkillSpector.ps1` | 2 三平台行為不同 | 平台化路徑比較（70），但無條件 `CreateNoWindow`（85） | 改寫 | 2 | 低 | 子程序可啟動，但無視窗語意與 Windows 不一致。 |
| `Skill-Atlassian-Ecosystem/scripts/Invoke-ParallelToolResolution.ps1` | 2 三平台行為不同 | 無條件 `CreateNoWindow`（76）；`FileShare.None`（151） | 改寫 | 2 | 中 | Unix 上隱藏視窗無效；輸出檔共享／刪除語意可能不同。 |
| `Skill-Atlassian-Ecosystem/scripts/Invoke-ShardedPester.ps1` | 3 已跨平台 | `$IsWindows` comparer（128）；平台 separator 正規化（133） | 保留 | 1 | 低 | 最可能只剩不同 filesystem 對開啟中檔案的共享語意差異。 |
| `Skill-Atlassian-Ecosystem/scripts/Invoke-SourceConformance.ps1` | 1 僅 Windows | 入口直接 `if (-not $IsWindows) { throw ... }`（34）；後續雖有平台 comparer（158、165）但不可達 | 替換 | 12 | 高 | 啟動後立即丟出「requires Windows」錯誤。 |
| `Skill-Atlassian-Ecosystem/scripts/Invoke-StandardAuthorityGate.ps1` | 2 三平台行為不同 | `CreateNoWindow`（2735）；路徑以 `DirectorySeparatorChar` 建構（314–315） | 改寫 | 2 | 中 | gate 子程序顯示／隔離行為不同，可能影響 timeout 或清理證據。 |
| `Skill-Atlassian-Ecosystem/scripts/Invoke-StandardValidation.ps1` | 2 三平台行為不同 | Windows Job Object 與 `kernel32`（129、177–194）；所有 Unix 載入 Linux `prctl`（259、271–275）；使用 `/proc`（3540）；呼叫 subreaper（3806） | 替換 | 20 | 高 | Linux 可走 Unix 分支；macOS 最可能因 `prctl`、`/proc` 或 namespace 不存在而中止。 |
| `Skill-Atlassian-Ecosystem/scripts/Resolve-StandardValidationTool.ps1` | 3 已跨平台 | 明確辨識 Windows／Unix／macOS（37–39）；同時接受 bare name 與 `.exe`（474） | 保留 | 2 | 中 | 最可能是某平台套件 launcher 結構未涵蓋，而非 Windows 語法直接失敗。 |
| `Skill-Atlassian-Ecosystem/scripts/Test-Repository.ps1` | 2 三平台行為不同 | 平台 comparer（215），但 git reader 無條件 `CreateNoWindow`（561） | 改寫 | 2 | 低 | Git reader 可執行，但視窗／程序建立選項在 Unix 上不同。 |
| `Skill-Atlassian-Ecosystem/scripts/Validate-UpstreamAdapter.ps1` | 3 已跨平台 | 非 Windows 使用 Unix regular-file 檢查（158–179）；平台化 containment（464–466） | 保留 | 2 | 中 | macOS `lstat` 結構或反射簽章若與假設不同，可能判定檔案不安全。 |
| `Skill-Atlassian-Ecosystem/scripts/Validate.ps1` | 1 僅 Windows | 入口直接拒絕非 Windows（49）；另含 native/ACL/process boundary 實作（912 起、2790 起） | 替換 | 24 | 高 | 啟動即丟出 canonical validation requires Windows。 |
| `Skill-Atlassian-Ecosystem/skills/configure-bitbucket-api-access/scripts/Configure-BitbucketApiAccess.ps1` | 2 三平台行為不同 | `EnvironmentVariableTarget.User`（31–36）；非 Windows `TargetScope User` 明確拋錯（72–74） | 改寫 | 5 | 中 | Process scope 可用，但要求 User persistence 時立即失敗。 |
| `Skill-Atlassian-Ecosystem/skills/configure-bitbucket-api-access/scripts/Test-BitbucketApiAccess.ps1` | 3 已跨平台 | 非 Windows 只檢查 Process scope（27 起） | 保留 | 0.5 | 低 | 不會看見 shell profile 中尚未匯入目前 process 的設定。 |
| `Skill-Atlassian-Ecosystem/skills/configure-confluence-api-access/scripts/Configure-ConfluenceApiAccess.ps1` | 2 三平台行為不同 | `EnvironmentVariableTarget.User`（30–35）；非 Windows User scope 拋錯（73–75） | 改寫 | 5 | 中 | 要求持久化時立即失敗；Process scope 仍可使用。 |
| `Skill-Atlassian-Ecosystem/skills/configure-confluence-api-access/scripts/Test-ConfluenceApiAccess.ps1` | 3 已跨平台 | 非 Windows 只讀 Process scope（27 起） | 保留 | 0.5 | 低 | 尚未匯入 process 的 Unix shell 設定會被報成缺少。 |
| `Skill-Atlassian-Ecosystem/skills/configure-jira-api-access/scripts/Configure-JiraApiAccess.ps1` | 2 三平台行為不同 | `EnvironmentVariableTarget.User`（29–34）；非 Windows User scope 拋錯（71–73） | 改寫 | 5 | 中 | User persistence 要求會立即失敗。 |
| `Skill-Atlassian-Ecosystem/skills/configure-jira-api-access/scripts/Test-JiraApiAccess.ps1` | 3 已跨平台 | 非 Windows 對 User／Machine scope 回傳空值（52–60） | 保留 | 0.5 | 低 | 只存在於 shell profile 的設定可能被判為尚未載入。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceAssets.psm1` | 3 已跨平台 | `GetRelativePath` 與 separator containment（34–36）；拒絕 symlink（42） | 保留 | 1 | 低 | provider link metadata 不完整時可能保守拒絕資產。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceCodeBinding.psm1` | 2 三平台行為不同 | 祖先走訪用 PowerShell 大小寫不敏感 `-ne`（90、131），未依 filesystem 分支 | 改寫 | 3 | 中 | Unix 上大小寫不同的 repository root 可能提早終止祖先檢查。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceDocs.psm1` | 3 已跨平台 | Windows ACL 分支（85–150、220、253）；Unix 使用 `UnixFileMode`（113–124、163–171、223–227、256–265） | 保留 | 2 | 中 | 不支援 `UnixFileMode` 的舊 runtime／filesystem 會回報 private permissions unavailable。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceMapping.psm1` | 2 三平台行為不同 | Git blob reader 無條件 `CreateNoWindow`（38）；路徑本身使用 portable API（65–67） | 改寫 | 2 | 低 | Git 可執行，但程序建立／顯示語意與 Windows 不同。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceMarkdownWorkflow.psm1` | 3 已跨平台 | `GetRelativePath` 並使用平台 separator（33） | 保留 | 1 | 低 | 最可能是被呼叫的 mapping 模組之程序選項差異，而非本檔直接失敗。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluencePlan.psm1` | 3 已跨平台 | 專門檢查 link/reparse（15、30、386–388）；以 `Join-Path` 組合 | 保留 | 1 | 低 | symlink metadata 不完整時可能保守拒絕計畫路徑。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluencePublish.psm1` | 3 已跨平台 | portable module imports（5–9）；輸出採 `FileShare`（1059）但非 OS API | 保留 | 1 | 低 | 開啟中檔案的刪除／取代語意可能與 Windows 不同。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceStorage.psm1` | 3 已跨平台 | 未見 Windows 專屬寫法 | 保留 | 0.5 | 低 | 未見明確平台失敗點。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceTransport.psm1` | 3 已跨平台 | 未見 Windows API；路徑比對採明確 case-sensitive `-ceq`（151） | 保留 | 1 | 低 | 未見明確平台失敗點。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ConfluenceValidation.psm1` | 3 已跨平台 | `Join-Path` imports（5–8）；reparse 檢查（65、98、358） | 保留 | 1 | 低 | symlink 輸入最可能被設計性拒絕。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/ImportReview.psm1` | 2 三平台行為不同 | containment 固定 `OrdinalIgnoreCase`（23）；reparse 祖先檢查（27、31） | 改寫 | 2 | 中 | Unix 大小寫不同路徑可能被錯誤視為位於 root 內。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/MarkdownProjection.psm1` | 3 已跨平台 | `GetRelativePath`＋平台 separator（72–74）；拒絕 symlink（79） | 保留 | 1 | 低 | symlink Markdown 資源會被設計性拒絕。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/Pull-ConfluenceDocs.ps1` | 3 已跨平台 | `GetRelativePath` 與平台 separator（30–31）；`Join-Path` imports（63、72） | 保留 | 1 | 低 | 未見明確平台失敗點。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/Push-ConfluenceDocs.ps1` | 3 已跨平台 | `Join-Path` 建構所有模組／Skill 路徑（29–33） | 保留 | 1 | 低 | 最可能受下游 API access persistence 差異影響。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/StorageProjection.psm1` | 3 已跨平台 | `Join-Path` 匯入（5）；未見 Windows API | 保留 | 0.5 | 低 | 未見明確平台失敗點。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/StrictJson.psm1` | 3 已跨平台 | 純 JSON／字串處理，未見平台專屬寫法 | 保留 | 0.5 | 低 | 未見明確平台失敗點。 |
| `Skill-Atlassian-Ecosystem/skills/manage-confluence-docs-as-code/scripts/Test-ConfluenceDocs.ps1` | 3 已跨平台 | `Join-Path` 匯入（16）；未見 Windows API | 保留 | 1 | 低 | 最可能由下游 private-permission capability 檢查回報不可用。 |
| `Skill-Atlassian-Ecosystem/skills/review-bitbucket-pull-request/scripts/Invoke-BitbucketReviewActions.ps1` | 3 已跨平台 | `FileMode.CreateNew` 原子 lock（352）；拒絕 reparse data path（161） | 保留 | 1 | 中 | 網路 filesystem 若不保證原子 create，可能出現 lock 競爭。 |

核對：**清單檔數 34 = `git ls-files` 範圍內檔數 34**。

##### Skill-Code-Collaboration

| 檔案 | 分類 | 具體寫法（行號） | 建議 | 工時(h) | 不確定性 | Linux/macOS 最可能失敗方式 |
|---|---|---|---|---:|---|---|
| `Skill-Code-Collaboration/scripts/CorePesterIntegrity.psm1` | 2 三平台行為不同 | executable 已分支 `pwsh.exe`／`pwsh`（138–140），但多處路徑仍固定 `OrdinalIgnoreCase`（207–208、277、349、369） | 改寫 | 4 | 中 | 大小寫不同的 runtime／manifest 路徑可能被誤認為相同或在 root 內。 |
| `Skill-Code-Collaboration/scripts/Get-SourcePin.ps1` | 3 已跨平台 | `Join-Path`（46）；未見 Windows API | 保留 | 0.5 | 低 | 未見明確平台失敗點。 |
| `Skill-Code-Collaboration/scripts/Invoke-CorePester.ps1` | 2 三平台行為不同 | executable name 有 `$IsWindows` 分支（16、160），但 Pester root／container path 固定忽略大小寫（277、286、501、632） | 改寫 | 4 | 中 | Unix 上 case-variant module 或測試路徑可能通過錯誤的 identity／containment。 |
| `Skill-Code-Collaboration/scripts/Invoke-RepositoryCheck.ps1` | 3 已跨平台 | `$IsWindows` comparer（29、83、88、93）；`Join-Path`（59–60） | 保留 | 1 | 低 | 未見明確平台失敗點。 |
| `Skill-Code-Collaboration/scripts/Prepare-PesterRuntime.ps1` | 2 三平台行為不同 | runtime、staging、receipt containment 固定 `OrdinalIgnoreCase`（27、82、132） | 改寫 | 3 | 中 | Unix case-sensitive 路徑可能被錯誤接受。 |
| `Skill-Code-Collaboration/scripts/StandardSourceDriver.psm1` | 3 已跨平台 | `$IsWindows` comparer（225、264、318、373）；runtime name 分支（378–380） | 保留 | 2 | 低 | 未見直接 Windows 失敗點；主要風險是尚未實跑的 Unix runtime closure。 |
| `Skill-Code-Collaboration/scripts/Test-Repository.ps1` | 3 已跨平台 | `GetRelativePath`＋平台 separator（411）；reparse 檢查（394、399） | 保留 | 1 | 低 | symlink Skill root／檔案會被設計性拒絕。 |
| `Skill-Code-Collaboration/scripts/Validate.ps1` | 3 已跨平台 | 多處 `$IsWindows` path comparer（263、272、680、1948）；runtime name 分支（1229–1233、3471） | 保留 | 3 | 中 | 最可能是 Linux/macOS runtime 複製後 executable mode 未被保留。 |

核對：**清單檔數 8 = `git ls-files` 範圍內檔數 8**。

##### Skill-Knowledge-Content

| 檔案 | 分類 | 具體寫法（行號） | 建議 | 工時(h) | 不確定性 | Linux/macOS 最可能失敗方式 |
|---|---|---|---|---:|---|---|
| `Skill-Knowledge-Content/scripts/CorePesterIntegrity.psm1` | 2 三平台行為不同 | 固定要求 `pwsh.exe`（138–139）；路徑固定忽略大小寫（207–208、277、349、369） | 改寫 | 6 | 高 | 找不到 `pwsh.exe`，即使改名後仍可能誤判 case-variant 路徑。 |
| `Skill-Knowledge-Content/scripts/Invoke-CorePester.ps1` | 2 三平台行為不同 | 測試與 container containment 固定 `OrdinalIgnoreCase`（163、294）；`FileShare.Read`（413） | 改寫 | 3 | 中 | Unix case-sensitive 測試路徑可能錯誤通過 containment。 |
| `Skill-Knowledge-Content/scripts/Prepare-PesterRuntime.ps1` | 2 三平台行為不同 | runtime／owned root／staging 固定 `OrdinalIgnoreCase`（20、29、84） | 改寫 | 3 | 中 | case-variant runtime 或 package path 可能被誤認為相同。 |
| `Skill-Knowledge-Content/scripts/StandardCoreSourceValidation.ps1` | 3 已跨平台 | 平台 separator（236）；`$IsWindows` comparer（414、571、771） | 保留 | 2 | 低 | 未見直接平台失敗點。 |
| `Skill-Knowledge-Content/scripts/Test-Repository.ps1` | 3 已跨平台 | `GetRelativePath`＋平台 separator（366）；reparse 檢查（349、354） | 保留 | 1 | 低 | symlink package 會被設計性拒絕。 |
| `Skill-Knowledge-Content/scripts/Validate.ps1` | 3 已跨平台 | `$IsWindows` comparer（135、335、342）；reparse 祖先檢查（165） | 保留 | 2 | 低 | 最可能是 Unix provider link metadata 差異造成保守拒絕。 |

核對：**清單檔數 6 = `git ls-files` 範圍內檔數 6**。

##### Skill-Darktide-Translate

| 檔案 | 分類 | 具體寫法（行號） | 建議 | 工時(h) | 不確定性 | Linux/macOS 最可能失敗方式 |
|---|---|---|---|---:|---|---|
| `Skill-Darktide-Translate/scripts/Get-SourcePin.ps1` | 3 已跨平台 | 純 Git／版本／雜湊處理，未見 Windows API | 保留 | 0.5 | 低 | 未見明確平台失敗點。 |
| `Skill-Darktide-Translate/scripts/Install-LatestPowerShell.ps1` | 1 僅 Windows | 明確拒絕非 Windows（12）；`CreateNoWindow`（24）；固定 `pwsh.exe`（95–99） | 改寫 | 8 | 高 | 啟動立即丟出 requires Windows。 |
| `Skill-Darktide-Translate/scripts/Invoke-PrePushValidation.ps1` | 1 僅 Windows | 第 58 行直接呼叫僅 Windows 的 `scripts/Validate.ps1` | 改寫 | 2 | 中 | pre-push 進入 validator 後立即被非 Windows guard 終止。 |
| `Skill-Darktide-Translate/scripts/PowerShellRelease.psm1` | 1 僅 Windows | 固定選取 `PowerShell-<version>-win-x64.zip`（78、94、99、127） | 改寫 | 8 | 高 | Linux/macOS 找不到唯一符合的 Windows ZIP，或下載錯誤平台 runtime。 |
| `Skill-Darktide-Translate/scripts/Test-CleanRepositoryHead.ps1` | 2 三平台行為不同 | Git root 路徑固定 `OrdinalIgnoreCase`（26） | 改寫 | 1 | 低 | 大小寫不同的 Unix repository 路徑可能被誤認為相同。 |
| `Skill-Darktide-Translate/scripts/Test-Repository.ps1` | 3 已跨平台 | `FileShare.Read`（312）；reparse／symlink 防護（328、382、388） | 保留 | 1 | 中 | symlink checkout 或 provider metadata 差異可能造成保守拒絕。 |
| `Skill-Darktide-Translate/scripts/Validate.ps1` | 1 僅 Windows | 入口拒絕非 Windows（42–44）；`kernel32`／`advapi32`（344 起）；ACL（2342 起）；固定 `pwsh.exe`（2741、3218、3727） | 替換 | 24 | 高 | 啟動後立即丟出 Standard v1 validation requires Windows。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1` | 3 已跨平台 | 匯入 portable path safety（16）；`Join-Path` 與原子 temp file（120、130） | 保留 | 2 | 中 | 最可能受共享 PathSafety 的 Unix physical-identity 限制影響，而非本檔直接失敗。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1` | 3 已跨平台 | OS-aware comparer（34–39）；平台 separator（25–30） | 保留 | 1 | 低 | 網路 filesystem 的 `CreateNew` 原子性若不足，可能產生競爭。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1` | 3 已跨平台 | portable comparer／reparse helper（15、39–42、54–81） | 保留 | 2 | 中 | helper 無法可靠判斷 Unix symlink 時可能保守中止。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1` | 3 已跨平台 | 同時正規化 `\`、`/`（58）；使用 portable path/reparse helper（4、74–77、138） | 保留 | 2 | 中 | Windows reserved-name 規則會在 Unix 上額外拒絕部分本來合法的檔名。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Invoke-ModUpdateQueue.ps1` | 2 三平台行為不同 | 使用 `SharedCoordinationLock.psm1`（22、42）；queue receipt 以 `Join-Path`（41） | 改寫 | 2 | 中 | Unix lock 語意未驗證時，兩個 queue runner 可能同時認為自己取得協調權。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/LuaLocalizationScanner.psm1` | 3 已跨平台 | `FileShare.Read`（37）；反斜線用途為 Lua escape parser（106、241、269），不是檔案路徑 | 保留 | 1 | 低 | 未見明確平台失敗點。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1` | 3 已跨平台 | 匯入 portable PathSafety（21）；輸入路徑正規化（277） | 保留 | 2 | 中 | 最可能受共享 PathSafety 的 Unix identity 限制影響。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/PathSafety.psm1` | 2 三平台行為不同 | Windows native API 僅於 Windows 建立（8、65–91）；非 Windows comparer 為 Ordinal（241–243）；但 physical identity 在非 Windows 直接回 `false`（341–344） | 替換 | 10 | 高 | hard link／同 inode 的不同路徑無法辨認為同一實體檔案。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1` | 3 已跨平台 | portable PathSafety（39）；platform-aware containment（157–197）；`CreateNew` temp files（411、589） | 保留 | 3 | 中 | 網路 filesystem 或 unusual mount 上的 atomic create／rename 語意可能不同。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1` | 2 三平台行為不同 | owner guard 依賴 `FileShare.None`（168）；主鎖另以原子 directory move（341、352） | 替換 | 8 | 高 | Unix 對開啟中檔案的共享、rename、delete 語意不同，owner update guard 可能無法提供與 Windows 相同的互斥保證。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1` | 3 已跨平台 | portable PathSafety（22）；platform-aware containment（96–116） | 保留 | 2 | 中 | symlink metadata 不完整時可能保守判定 receipt 不安全。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1` | 3 已跨平台 | portable PathSafety（20、241–280）；危險副檔名同時涵蓋 Windows、Linux、macOS（324） | 保留 | 4 | 中 | 平台特有 binary／archive metadata 若未涵蓋，可能漏判或保守拒絕。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1` | 3 已跨平台 | portable PathSafety（13、59–83）；`GetRelativePath` 正規化（322） | 保留 | 2 | 中 | symlinked Skill 安裝會被設計性拒絕。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1` | 3 已跨平台 | portable PathSafety（27、159–179）；平台-aware containment（402） | 保留 | 2 | 中 | provider 無法可靠判定 symlink 時可能拒絕有效 receipt。 |
| `Skill-Darktide-Translate/skills/auto-update-darktide-mod/scripts/mod-update.ps1` | 2 三平台行為不同 | guard 使用 `FileShare.None`（778、2032）；呼叫 Unix 不完整的 physical identity（1385–1388）；部分 Git 路徑契約固定忽略大小寫（3737、3748、3985） | 改寫 | 8 | 高 | 可能無法辨認 hard-link 同檔，或在並行更新時失去與 Windows 等效的互斥／路徑 casing 保護。 |

核對：**清單檔數 22 = `git ls-files` 範圍內檔數 22**。

### 測試檔彙總

「含僅 Windows 寫法」只計實際使用分類 1 寫法的測試，不計單純測試文字、平台 guard 或 portable `ReparsePoint` 檢查。

| Repository | PowerShell 測試檔總數 | 含僅 Windows 寫法 | 代表例子 |
|---|---:|---:|---|
| Skill-General | 22 | 0 | 無 |
| Skill-Atlassian-Ecosystem | 42 | 4 | `tests/BitbucketReviewActions.Tests.ps1:590` 呼叫 `powershell.exe`；`tests/ConfluenceDocs.Capture.Tests.ps1:1494` 使用 `WindowsIdentity`；`tests/StandardV1Conformance.Tests.ps1:178` 存取 Registry；`tests/validate-windows-powershell.ps1:123` 呼叫 `cmd.exe` |
| Skill-Code-Collaboration | 10 | 0 | 無 |
| Skill-Knowledge-Content | 7 | 0 | 無 |
| Skill-Darktide-Translate | 17 | 0 | 無 |
| **合計** | **98** | **4** | — |

### Windows-only 宣告位置

##### Skill-General

- `Skill-General/README.md:52` | “Windows-only local host”
- `Skill-General/skills/investigate-datadog-logs/SKILL.md:3` | “Windows-only Skill.”
- `Skill-General/skills/investigate-datadog-logs/SKILL.md:12` | “Windows is the only supported host”
- `Skill-General/skills/manage-ai-memory/SKILL.md:3` | “Windows-only Skill.”
- `Skill-General/skills/manage-ai-memory/SKILL.md:12` | “Windows is the only supported host”
- `Skill-General/skills/manage-task-handoff/SKILL.md:3` | “Windows-only Skill.”
- `Skill-General/skills/manage-task-handoff/SKILL.md:12` | “Windows is the only supported host”
- `Skill-General/skills/operate-environment-authorized-sql/SKILL.md:3` | “Windows-only Skill.”
- `Skill-General/skills/operate-environment-authorized-sql/SKILL.md:12` | “Windows is the only supported host”
- `Skill-General/skills/plan-production-change/SKILL.md:3` | “Windows-only Skill.”
- `Skill-General/skills/plan-production-change/SKILL.md:12` | “Windows is the only supported host”
- `Skill-General/skills/review-agent-skills/SKILL.md:3` | “Windows-only Skill.”
- `Skill-General/skills/review-agent-skills/SKILL.md:12` | “Windows is the only supported host”
- `Skill-General/skills/verify-data-access-performance/SKILL.md:3` | “Windows-only Skill.”
- `Skill-General/skills/verify-data-access-performance/SKILL.md:12` | “Windows is the only supported host”

##### Skill-Atlassian-Ecosystem

未找到 `README.md` 或 `skills/*/SKILL.md` 的 Windows-only 宣告。

##### Skill-Code-Collaboration

- `Skill-Code-Collaboration/skills/write-copilot-implementation-prompt/SKILL.md:3` | “supported on Windows hosts.”
- `Skill-Code-Collaboration/skills/write-copilot-implementation-prompt/SKILL.md:12` | “supported only on a Windows host.”

##### Skill-Knowledge-Content

- `Skill-Knowledge-Content/README.md:25` | “Windows-only source scope.”
- `Skill-Knowledge-Content/skills/capture-private-course-knowledge/SKILL.md:3` | “Windows-only.”

##### Skill-Darktide-Translate

- `Skill-Darktide-Translate/README.md:7` | “Independent, Windows-only Agent Skill source”
- `Skill-Darktide-Translate/README.md:9` | “require a Windows host; Linux, macOS, and WSL are unsupported.”
- `Skill-Darktide-Translate/skills/auto-update-darktide-mod/SKILL.md:3` | “on Windows only”

### 跨 repository 共通模式

1. **Core Pester runtime／integrity**

   `CorePesterIntegrity.psm1`、`Invoke-CorePester.ps1`、`Prepare-PesterRuntime.ps1` 在 General、Code-Collaboration、Knowledge-Content 有多份近似實作，但跨平台成熟度不同。方向上可共用一套 runtime executable name、filesystem-aware comparer、symlink policy、closure verification 與 archive extraction library。

2. **路徑 containment 與 symlink 防護**

   多個 repository 各自實作 `GetFullPath`、prefix comparison、祖先走訪與 `ReparsePoint` 檢查。方向上可共用一個 platform-aware path safety module，統一 filesystem case behavior、symlink／junction、hard-link identity、missing-child-under-symlink 與 root boundary 規則。

3. **程序樹隔離與 timeout cleanup**

   Atlassian 的 `Validate.ps1`、`Invoke-StandardValidation.ps1` 與 Darktide 的 `Validate.ps1` 都各自處理 Windows Job Object、Linux process group／subreaper。方向上可抽象為 Windows、Linux、macOS 三個 backend，能力不足時輸出明確 capability 結果。

4. **PowerShell runtime 安裝器**

   Darktide 的 installer／release selector 與各 repository 的 Pester runtime 準備都需要辨認 runtime executable 與 archive layout。方向上可共用 OS／architecture asset mapping、ZIP／tar.gz extraction、Unix executable-mode 設定與 digest verification。

5. **檔案鎖與協調鎖**

   `FileShare.None`、`FileMode.CreateNew`、atomic directory rename 分散於 validation、Bitbucket review、Darktide queue。方向上可採 capability-tested lock backend：本機 filesystem 使用原子 create／rename；需要跨 process 或網路 filesystem 時使用具 owner token、heartbeat、stale recovery 的明確協定。

6. **Pester 準備與 CI 入口**

   各 repository 的 `Validate.ps1`、`Test-Repository.ps1`、`Invoke-*Pester.ps1` 決定 Linux CI 是否可啟動。目前有些入口已平台化，有些在第一段就拒絕非 Windows。方向上可先統一最小三平台 smoke gate，再按平台能力啟用強化隔離。

7. **環境設定持久化**

   三個 Atlassian `Configure-*ApiAccess.ps1` 都複製了 Process／User scope 寫入邏輯。方向上可共用 process injection 與持久化 provider，將 Windows User environment、POSIX shell profile、CI secret injection 明確分離。


## 附錄 D：未確認事項（各 Step 原始清單）

### 351-A

1. 需在真實 Linux 與 macOS 各執行一次非破壞性 smoke test，確認 PowerShell 7 對含反斜線 `Join-Path` child path 的實際處理。
2. 需以兩個獨立程序測試 `FileShare.None`／`FileShare.Read` 在目標 .NET runtime 與檔案系統上的實際行為；不能只依 API 名稱推定。
3. macOS 的預期安全等級尚未決定：若要求與 Windows Job Object/Linux PID namespace 相同的不可逃逸隔離，可能必須引入外部 sandbox，而非僅改寫 PowerShell。
4. 需要決定 Unix 上對 symlink 的產品政策：全部拒絕，或允許經過 `lstat`/descriptor-bound 驗證的特定 symlink。
5. 需要決定 hard-link 政策：所有 managed/security-sensitive regular file 是否都要求 `st_nlink == 1`。
6. 需要在 case-sensitive Linux、預設 macOS APFS，以及 case-sensitive APFS 各驗證 path containment 與 collision 規則。
7. Unix 原子發布的 durability 要求尚未明確：是否必須包含 file `fsync`、parent-directory `fsync` 與 crash-recovery journal。
8. 測試檔中的 Windows fixture 應保留作 contract 測試，或拆成平台專屬 suite，仍需使用者決定。
### 351-B

- 未依限制在 Linux 或 macOS 實跑，因此 `FileShare.None`、atomic rename、開啟中檔案刪除與網路 filesystem 的實際互斥保證仍需測試。
- macOS 上 `Invoke-StandardValidation.ps1` 的 `PlatformID.Unix` 分支確定含 Linux-only 設計，但實際最早失敗點需 macOS 實跑確認。
- Unix hard link／inode identity 應採 native `stat`、.NET API 或外部可信工具，需由使用者決定允許的依賴與安全邊界。
- 三個 Atlassian API 設定 Skill 的 Unix 持久化目標尚未決定：shell profile、launch agent、desktop environment、secret store 或只支援 process injection。
- Windows Job Object／restricted token／ACL 對 Linux namespace、cgroup／rlimit，以及 macOS process group／sandbox 的安全等價要求需要產品層決策。
- `CreateNoWindow` 在 Unix 多半被忽略，但是否只需移除、平台 guard，或需改成不同的 detached/headless contract，需依 CI 與互動式使用需求決定。
- 多個 Skill 文件仍明確宣告 Windows-only；即使腳本本身已跨平台，正式支援範圍仍需由使用者決定。
- 工時高度受共用模組策略影響；若先建立共用 path safety、process isolation、runtime installer，後續 repository 的重複修改量可明顯下降。
