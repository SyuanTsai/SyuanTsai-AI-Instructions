# 計畫：讓 canonical Static profile 支援 SkillSpector 2.13.0

## 1. 目標與範圍

- 預期結果：latest-stable resolver 解析到官方 SkillSpector 2.13.0 時，Stage 4 能以受中央 authority 綁定的 PowerShell ownership profile 執行，而不會因 profile 仍固定在 2.12.0 而 fail closed。
- 驗收條件：profile 同時綁定官方 release commit `091a509b3d6ba8ff5be528966e1f43c2e68cf214`、release wheel SHA-256 `41e097b4127c0aa0732ad31cc909f8aee0b907d97816c866a55b8e782a6ca6dc`、wheel 內 analyzer SHA-256 `c799169f9ad716f8dbbbec5892ef76affd0f9974433709ed0c1cfc3bcd0b66a4` 與 PowerShell 7.6.6 grammar；未知版本或任一 bytes 漂移仍拒絕。
- 交付內容：更新 normative Standard、profile policy/schema、profile execution schema、PowerShell wrapper、Python bridge，以及三個 authority regression suites 與直接 parser coverage tests。
- 範圍外：不改寫 PR12、SYP-171、SYP-314 的歷史 SkillSpector 2.12.0 evidence／decision；不改 severity、semantic scan、internal-use authorization、release/install 或 Catalog 邊界；不處理 PR #18 既有產品 findings。
- 相依條件：consumer 必須在中央修正合併後重新 pin 新 authority archive／成員 hashes，才能執行正式 SYP-304 acceptance。

## 2. 預定修改

### 2.1 更新 normative profile identity

- 目標檔案：`docs/standards/skill-repository-standard.md`、`docs/standards/static-parser-host-ownership.json`、`docs/standards/schemas/static-parser-host-ownership-v1.schema.json`、`docs/standards/schemas/static-parser-profile-execution-v1.schema.json`。
- 目前行為：profile 僅接受 2.12.0 與舊 analyzer hash；policy 未把 release commit／wheel digest 納入自己的 exact identity。
- 修改：升級到 2.13.0，加入並固定 release commit 與 release asset SHA-256，保留現有 budgets、無授權欄位與 fail-closed 規則。
- 理由：2.13.0 已是 resolver 的 latest stable；只綁 analyzer file 不足以識別其餘 scanner graph bytes。
- 風險：schema 變更會使舊 profile record 無法通過新 authority；舊 evidence 仍由產生它的 immutable authority revision 驗證，不重寫歷史資料。

### 2.2 更新 runtime profile gate

- 目標檔案／symbol：`scripts/Invoke-StandardStaticScan.ps1` 的 frozen receipt gate；`scripts/standard_static_powershell.py` 的 `OFFICIAL_*` constants、`install_bridge` 與 profile execution record。
- 目前行為：latest-stable receipt 解析到 2.13.0 後，在執行 scanner 前因版本不符失敗。
- 修改：要求 exact 2.13.0 release identity、asset hash、analyzer bytes 與既有 frozen receipt／closure invariants；實際 scanner graph、原始報告、finding preservation 與 no-authorization 行為維持原契約。
- 理由：讓新 stable release 可用，同時防止同版本 tag／asset／graph 替換被誤認為 reviewed profile。
- 風險：上游 analyzer API 已保留 `has_bounded_parse_exhaustion`、`_has_shell_command_word_exhaustion` 與 `analyze`，但 2.13.0 大幅修改 scanner graph；必須以真實 2.13.0 wheel 的正式 Stage 4 run 驗證，單元測試不能取代此證據。

### 2.3 更新回歸測試

- 目標檔案：`tests/static-parser-coverage.Tests.ps1`、`tests/test_static_powershell_parser.py`、`tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1`、`tests/standard-validation-resolver-hardening.Tests.ps1`。
- 修改：加入 profile 跨 policy/schema/wrapper/Python 的 exact identity 一致性測試、wrong version/hash/release identity negative cases，並確認 Windows Core 仍 discovery 真實 native parser regression。
- 理由：避免只更新單一常數、遺漏 schema 或降低 release identity 綁定。

## 3. 測試情境

### 3.1 新版 exact profile

- 層級：unit／contract。
- Given：2.13.0 的固定 release commit、wheel digest 與 analyzer digest。
- When：讀取 policy、schemas、wrapper 與 Python bridge。
- Then：所有 identity 一致，2.12.0、未知版本、錯誤 module hash、錯誤 release commit／asset 均 fail closed。
- TDD：Red 先把 tests 改成要求 2.13.0 exact identity → Green 更新最小 production surfaces → Refactor 合併重複 assertion，測試保持通過。

### 3.2 Native PowerShell ownership invariants

- 層級：Python integration／Pester contract。
- Given：既有 benign、dynamic shell、ProcessStartInfo 與 malformed source fixtures。
- When：bridge 在 2.13.0 profile identity 下安裝並執行 native parser contract。
- Then：安全 argv 保持可分析，command string／跨 interpreter／未知 proof 保持 partial 或拒絕，finding analyzer object 不被替換。
- TDD：更新 version gate 後先觀察舊 production constant 造成失敗，再更新 bridge；不改變 grammar 判斷本身。

### 3.3 真實 latest-stable Stage 4

- 層級：端到端 acceptance。
- Given：正式 resolver receipt 指向已驗證的 2.13.0 wheel／dependency closure，consumer candidate 為 immutable revision。
- When：執行 canonical source validation。
- Then：Stage 4 產生 original report、corrected report、profile record 與 preserved-findings evidence；未知 finding 或未完成 coverage 仍阻擋；總 acceptance 在 20 分鐘上限內完成。
- TDD：此情境需要合併後的 immutable authority 與 consumer pin，因此在中央與 consumer commits 獲授權並合併後執行；本地先以 authority suites 與 exact wheel evidence驗證。

## 4. 交付與驗證

- 直接驗證：Python parser contracts、`tests/static-parser-coverage.Tests.ps1`。
- authority regression：`tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1`、`tests/standard-validation-resolver-hardening.Tests.ps1`，以及 repository 規定的 Standard authority gate。
- 靜態檢查：PowerShell parse、JSON schema validation、Python compile、`git diff --check`、變更範圍與歷史 2.12.0 evidence 掃描。
- rollout：先合併中央 authority；consumer 再更新 exact archive／34-file pins 與 runner hash，建立新的 immutable candidate，最後執行 timed SourceValidation。
- rollback：中央變更可由正常 revert 恢復 fail-closed；consumer 在新 authority acceptance 前不推送，因此不會把未驗證 profile 發佈到 main。

## 5. 風險與未解決事項

- 2.13.0 新增與大幅修改多個 analyzers；profile 只修正 PowerShell ownership completeness，不宣稱整體 scanner 行為與 2.12.0 等價。正式 run 出現的新 findings 必須依原 severity policy 處理。
- 若真實 2.13.0 graph 不再允許現有 in-memory bridge 或報告 shape 不相容，維持 fail closed，另行調整 profile；不得用 pin 舊版或改寫 report 假裝通過。
- 中央與 consumer 的 commit、push、PR／merge 仍需依 repository Git 授權邊界辦理。
