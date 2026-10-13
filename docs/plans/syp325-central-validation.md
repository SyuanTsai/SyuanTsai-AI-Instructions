# SYP-325 中央驗證最小實作計畫

## 1. 目標與邊界

在正常 main af9c672e964c1ea41a75f46d14ebc65566dc865f 上，以獨立分支調整來源工具 dispatch 的重複完整性核對。setup 與 final 維持全量；dispatch 前後核對目前工具的依賴 closure、launcher/payload/runtime 及共同控制輸入。可寫工作目錄仍可變，不能聲稱 immutable。

交付中央程式、保護行為測試、沿既有格式的 phase 診斷、正常 CI 與獨立 review／PR。完整 Windows SourceValidation 的 20 分鐘目標由後續試點驗收，本票不宣稱達成。來源 repo、Catalog、Lock、USER、後續入口採用不在此範圍；既有安全 severity、LP3 及 analyzer findings 保留。

## 2. 核實證據及改動

- Invoke-StandardValidation.ps1：Assert-StandardCoreFrozenFiles、Assert-StandardCoreSourceToolReceipts、Assert-StandardCoreNativeReports、Invoke-StandardCoreSourceTools 及 final report reader 的直接關係。
- 現有 setup 與每 dispatch 前後均掃全量 frozen／三工具 closure。來源命令 DevelopmentHarness=true，legacy child toolReceipt 為 null，所以來源自己的前後核對不能移除。
- setup 認證 receipt 的同一次 JSON snapshot hash 與 frozen binding，建立內部 retained map。後續先重新核對 live bytes 再重用解析內容；final 自行重新認證。不得信任 stale receipt 或 mtime。
- 依 installRoot 與 frozen launcher/executable/payload/runtime 建立每工具群組，外部共用 runtime 及重疊 root 納入實際依賴，未歸屬 frozen 保守留共同控制集合。祖先 canonical／reparse 拒絕保持；closure root-only 不替代祖先保護。
- 沿既有 stderr timing 記錄 frozen、ancestor/path、closure、report binding、cleanup；nested spans 為包含關係，不重複加總。frozen 外層 calls 表示 guard invocation；path／hash calls 表示實際逐檔操作。report binding wall time 涵蓋完整 reader，但 files／bytes／calls 只觀測成功的 SHA 與 JSON snapshot 讀取，排除直接 ReadAllText 等未經 hook 的讀取；不得當成完整 IO total。診斷不改 canonical evidence schema。
- 保留 final source/candidate/authority/adapter/run、native/raw output、coverage、exit、取消、timeout 及 cleanup binding。
- 外部 adapter/evidence v2 與 testOwnership 暫不變：現有完整 candidate tests tree 語意保留，中央正常 CI 已有框架測試入口。Source tests 副本移轉由後續採用依逐項責任矩陣完成，不能先刪有效功能測試。
- 文件定位為 docs/standards/skill-repository-standard.md；必要時說明完整性與測試責任邊界，不新增 schema 欄位。Invoke-ThirdPartySourceChecks.ps1 的 raw caller 屬後續入口採用，不提前修改。

## 3. 測試與 TDD

先建立最小失敗 behavior tests，記錄 Red → 最小 Green → Refactor。新增測試依 Testing 規則命名並附 Scenario/Purpose。

1. 真實 frozen／closure hashing，僅 stub child transport，證明當前 A 前後不讀無直接依賴 B；setup/final 維持全量。
2. executable、payload、dependency 修改、新檔注入、reparse 或 root／ancestor 替換均拒絕。A 污染 B 時 B child 使用前拒絕；當前工具自改在後檢拒絕。
3. retained snapshot hash mismatch、receipt 換檔、共用控制與外部 runtime 修改仍拒絕。
4. 既有 standard tests 完整保留 wrong run/candidate/authority/adapter、receipt、raw/native mismatch、coverage 缺漏/重複、timeout/cancel/cleanup/exit/security 行為。
5. 兩種 closure 大小，各必要 phase 至少三樣本，記錄 mean/min/max、實際檔案 paths/count/bytes；無資料庫，query count 不適用。CI 以範圍與行為驗證，不設毫秒硬門檻。

## 4. 交付與驗證

先執行 targeted Pester runner／resolver hardening／source reader 保護；正常 Windows CI 的 authority gate 加完整 non-authority discovered suite 會含新增測試，不新增 caller filter。檢查語法、git diff --check、差異與可達新增歷史去識別化。LUNA 是唯一 production writer，Review 由獨立 SOL 唯讀執行。

PR 必須綁定 exact head、正常 base、實際執行 authority、archive hash、CI 與 review。未取得正常 merge 授權前保持可審 PR，不能以候選代替正式 authority 供來源採用。回復透過正常 revert 還原上一整組 authority/adapter/reader；保存新舊證據，舊 PASS 不代表新候選。

## 5. 殘餘風險

可寫目錄的每次使用前後核對保留；若外部共享依賴無法精確辨識，採保守 shared 集合。完整來源端到端時間、protected reader 實際採用及各入口移轉留後續票驗收。若新增資料格式或 testOwnership 意義才需版本化，停止該部分並回報精確契約變更，未知版本維持拒絕。

## 6. Windows 路徑 fixture 可攜性（使用者追加範圍）

既有本機完整回歸保留四個失敗的原始證據；其中 UnitT26h 在測試進入實際 resolver 前，因以 Repository parent 建立固定 84 字元 fixture 而算出負數 padding。短 checkout 的同一 Describe 69/69 通過，顯示測試幾何依賴所在環境。使用者要求在 SYP-325 內解決此反覆出現的問題。

由同一 LUNA writer 增加測試專用、create-only 的唯一短根目錄配置與受邊界保護的清理，讓 fixture 幾何獨立於 checkout 與 TEMP 的外層長度。驗證正常／深層 Repository 與正常／長 TEMP 的代表矩陣，直接呼叫 New-AuthorityRunOwnedToolRoot，保留 current root <128 而 deepest path >=248、可用 fallback <248、所有候選超出預算時寫入前拒絕，以及 collision/run-owned/reparse 語意。UnitT26i/v/q 的 wheel member、tail deadline 與順序行為保留。

不放寬 production 路徑預算、不跳過測試、不將負數截斷、不改全域設定。既有 resolver production bytes 保持不變；新測試 delta 必須經獨立 Review，以及正常 Windows CI 的完整 discovered suite。原先失敗與短 checkout 對照證據均保留，最終候選另外綁定 hashes 與實際回歸結果。