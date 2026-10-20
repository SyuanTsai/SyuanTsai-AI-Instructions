# 計畫：acquisition closure content hashing 固定四路並行

- 目標／範圍：只加速 SkillSpector acquisition 的完整 installed closure content hashing。同程序最多四個 hashing tasks；其他 resolver、Static、Pester、scheduler、worker 與 sharding 不變。
- 已知證據：10,928 files 首次循序讀取約 325–346 秒；canonical digest 必須完全一致。來源身分、完整檔案 inventory、隔離、fail-closed 與 timeout 契約不變。
- 修改：`scripts/Resolve-StandardValidationTool.ps1` 先完成既有 root/reparse/regular-file/path/NFC/ASCII collision 驗證，再把一般檔案交給同程序 .NET `Parallel.For`，固定 `MaxDegreeOfParallelism = 4`。依原 inventory index 接回 raw SHA-256，沿用 ordinal ordering 與 canonical digest。僅 bounded installed SkillSpector acquisition verification 啟用；不增加外部 binary 或程序。
- Red／Green：先新增 opt-in canonical digest parity、一般檔案完整性及讀取失敗必須 throw 的測試，觀察舊版因缺少 switch/helper 失敗；再實作最小修正。鄰近 regression 保護 Unicode/ASCII collision、unsafe/reparse 路徑與 ordinal bytes。檔案開啟或 hashing 失敗必須使整體 acquisition 失敗，不能回傳部分 digest。
- 分段驗收：fresh run-owned install root 與正式相同 Python/Go；完整四工具 acquisition 必須有四份同 run receipt、stderr 空白，且時間可合理支持正式總 wall <=1200 秒。先以 closure fresh-tree <=90 秒判斷單項收益，再以 acquisition <=325 秒判斷是否進完整 preflight。
- 回歸／交付：三個 authority Pester suites、同一 authority gate、parse 與 diff checks；authority review/正常 PR 合併後 consumer exact repin，完整 preflight 全綠，再建立 immutable candidate，正式 Stages 1–5、全部 repository tests、預期 semantic-consent block 與 wall <=1200 秒通過後，才依授權繼續 consumer commit/push/PR/CI/review/normal merge。
- 風險：並行可能增加 I/O contention；以 fresh-tree 與 acquisition 的實測決定，不調整四路上限、不試其他 concurrency 變體。排序前所有安全驗證保留，hashing tasks 不執行 PowerShell scriptblock，不接受 caller-supplied callbacks。既有 bounded process deadline 仍能終止整個 acquisition worker。
- 回復：修正未達分段收益則保留 evidence 並還原；合併後需回復時採正常 revert，consumer 不發佈未通過的 pin。

## 2026-10-20 實測與目前判定

- Red：新增 canonical parity 與 read-failure tests，舊版因缺少並行 switch/helper 失敗；先保護 failure test 不得因 API 缺失而誤判通過。
- 精準 Green：canonical bytes、內容變更、locked/missing file、Unicode collision、ordinal ordering、四路 cap 與唯一 acquisition opt-in 通過。
- Fresh Temp tree：10,928 files，完整 closure 112.939 秒，digest 與既有 receipt 精確相同。相對循序 325.508 秒縮短約 65%，但未達預定單項 90 秒目標。
- 四工具 acquisition 的首次嘗試因官方 Go stable 從 1.27.2 更新為 1.27.3 而 fail closed，未產生 receipt。官方 archive SHA-256 與執行版本驗證後，使用 fresh run 重跑。
- 正確 runtime 的完整 acquisition：381.661 秒、四份同 run receipt、stderr 空白、resolver exit 0。相對前次正式 Temp 路徑 642.525 秒縮短約 41%，但超過 325 秒分段門檻。
- 既有 helper diagnostics：candidate discovery／verification 在第一輪 offline pip 前已耗約 92 秒；12 輪 offline pip 後，helper 合計 165.056 秒。這是 hashing 之前的流程，不在本次並行例外範圍。
- 目前尚不具備正式總 wall <=1200 秒的合理時間證據，故未執行 consumer 完整 preflight／正式驗證，亦未提交或發佈本次修改。保留本地 candidate 供完整 authority regression 與 review；是否保留需同時依正確性及分段收益判定，不能以局部 Green 當作 consumer acceptance。
- 正確性驗證完成：沿用 canonical `Invoke-StandardAuthorityGate.ps1`、Pester 4.10.1 與 development-content binding，289/289 通過；完整 resolver hardening suite 50/50 通過，0 failed/skipped/pending；parse 與 whitespace checks 通過。Review 未發現改變 raw digest、安全檢查、來源／隔離或失敗傳遞的缺陷；效能驗收仍是未通過的項目。
- 僅補足當前分段證據：對既有 immutable consumer、既有 scheduler 與完整 519-test inventory 跑一次 repository regression，門檻 519/519 且 <=510 秒；不修改 Pester 設定、不作為正式 source acceptance，不跨 run 重用 receipt 作為正式證據。
- 上述單次 repository regression 已完成：519/519、0 failed/skipped/failed containers、stderr 空白，耗時 612.082 秒，超過 510 秒分段門檻。以既有 package/static/其他階段資料組合，正式總時間推估約 1,301.6 秒；未啟動完整 preflight／正式 run，未 commit/push/merge。
- 本次四路 hashing 的 correctness 與實際收益已獨立證實，作為 bytes 固定的本地 Green 基線保留。狹窄例外只允許 closure content hashing 並行；後續不得擴充並行、改變 Pester 或放寬時間／安全門檻。同一 acquisition 路徑中的下一個循序修正仍須先定位單一根因、Red/Green 與分段驗證，不能同時嘗試多個候選。

- 組合驗證：循序 candidate priority 與同主機 HTTPS reuse 各自 Red/Green 並實測收益後，完整 acquisition 為 241.986 秒；selected closure 與前一個候選完全相同。組合 canonical authority development gate 289/289、完整 resolver 52/52，0 failed/skipped/pending，parse 與 diff checks 通過。後續採中央 PR／CI／code-security review／normal merge，再由 consumer 以新 immutable pin 完成 preflight 與正式 <=1200 秒驗收；本地 authority regression 不替代 consumer 正式結果。
