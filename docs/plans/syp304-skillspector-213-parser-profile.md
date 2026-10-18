# 計畫：讓 canonical Static profile 支援 SkillSpector 2.13.0 並重用已驗證的 closure plan

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

### 2.4 移除重複的 offline pip backtracking

- 目標檔案／symbol：`scripts/Resolve-StandardValidationTool.ps1` 的 `Resolve-SkillSpector` 安裝階段；`docs/standards/skill-repository-standard.md` 的 SkillSpector closure 契約；`tests/standard-validation-resolver-hardening.Tests.ps1`。
- 目前行為：受 SHA-256 綁定的 `Resolve-PythonWheelClosure.py` 已在 verified candidate pool 內以 pip `--dry-run --no-index --report` 完成 backtracking，產生 raw plan、normalized plan、candidate inventory 與 selected closure；PowerShell wrapper 重新執行 helper `verify`，交叉核對所有 evidence identities、逐一驗證 candidate bytes，並把 selected entries 與新建的 hash-locked wheelhouse manifest 比對。完成這些檢查後，`Resolve-SkillSpector` 又針對同一 wheelhouse 與 closure 執行第二次 pip dry-run。
- 修改：把 helper 產生且經 wrapper 驗證的 selection plan 定為同一 run 的唯一 authoritative backtracking plan；移除 PowerShell 的第二次 dry-run 與其重複 plan parsing。最終安裝仍從 verified wheelhouse 使用 `--no-index --require-hashes --no-deps --force-reinstall`，安裝後仍執行 static dist-info／entry-point 與完整 installed-closure 驗證。
- 理由：第二次 dry-run 不增加新的來源、candidate 或 bytes 驗證，而且在正式 SkillSpector 2.13 resolver 實測中重複了最昂貴的 dependency solving。重用已驗證 plan 可縮短 acceptance，同時維持 fail-closed trust boundary。
- 風險：若 helper plan、selected closure 或 wheelhouse manifest 的 identity 比對被弱化，`--no-deps` 安裝可能接受未經 backtracking 證明的 closure。測試必須同時保護 helper 唯一 dry-run、helper `verify`、raw plan hash／count、selected-entry-to-manifest 比對，以及最終 hash-locked no-deps install；本次不改這些檢查。

### 2.5 不產生 dependency bytecode cache

- 目標檔案／symbol：`scripts/Resolve-PythonWheelClosure.py` 的 offline pip command、`scripts/Resolve-StandardValidationTool.ps1` 的 final pip install、`docs/standards/skill-repository-standard.md` 與 resolver hardening tests。
- 目前行為：pip 預設在安裝時編譯 dependency `.py`。SkillSpector 2.13 的實際 venv 因此包含 7,338 個派生 `.pyc` files、約 61 MB；resolver post-install 與每個 Static before／after check 都將它們當作 installed closure 重複列舉與雜湊。正式 scanner 本來已以 Python `-B` 執行，不依賴或更新 bytecode cache。
- 修改：helper 啟動 offline pip backtracking 時加入 interpreter `-B`；final hash-locked install 同時使用 interpreter `-B` 與 pip `--no-compile`。原始 `.py`、wheel／manifest hashes、selected closure、static metadata／entry point 及 installed closure 驗證全數保留。
- 理由：`.pyc` 是可由已驗證 source bytes 重建的安裝副產品，且 production scanner 已禁止讀寫 cache；不建立它們可縮小同一受驗證 tree，而非略過 tree 內既有 files。
- 風險：若任何 production invocation 未使用 `-B`，scan 可能在 receipt 之後產生新 `.pyc` 並使 closure 漂移。contract 必須同時保護 helper `-B`、pip `--no-compile` 與 native／bridge scanner 的既有 `-B`；真實 resolver 與 Stage 4 必須證明 before／after closure 不變。

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

### 3.4 單一 verified backtracking plan

- 層級：source contract／真實 resolver performance acceptance。
- Given：helper 以 isolated Python 在 verified local pool 完成一次 pip dry-run，wrapper 已重新驗證 helper identity、candidate inventory、raw／normalized plans、selected closure 與每個 selected wheel bytes。
- When：`Resolve-SkillSpector` 建立 hash-locked manifest 並安裝 closure。
- Then：`Resolve-SkillSpector` 不再呼叫第二次 pip dry-run；helper 仍恰有一次 offline dry-run；selected entries 必須逐一等同 manifest；安裝仍使用 `--no-index --require-hashes --no-deps`，後續 installed metadata／closure 驗證維持不變。
- TDD：Red 先加入 source contract，證明現有 wrapper 仍含第二次 dry-run；Green 只刪除該重複區段；Refactor 後執行三個 authority suites、Standard authority gate，以及 exact SkillSpector 2.13 resolver benchmark，並將 closure／executable identities 與既有正式 receipt 比對。

### 3.5 無 dependency bytecode cache 的 closure

- 層級：source contract／真實 resolver 與 Static integration。
- Given：helper 在 verified local pool backtrack、final pip 從 hash-locked wheelhouse 安裝，且 native／bridge scanner 均以 `-B` 啟動。
- When：建立並重驗 SkillSpector installed closure。
- Then：helper pip interpreter 含 `-B`、final pip 含 `-B --no-compile`；選定 distributions 不產生 `.pyc`；receipt 仍綁定完整實存 tree，scan 前後 digest 相同。
- TDD：Red 先證明 helper／install 尚未禁止 bytecode；Green 只加入 flags；以 fresh run-owned resolver 記錄 file count／bytes／elapsed，並執行真實 Static before／after closure acceptance。

## 4. 交付與驗證

- 直接驗證：Python parser contracts、`tests/static-parser-coverage.Tests.ps1`。
- authority regression：`tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1`、`tests/standard-validation-resolver-hardening.Tests.ps1`，以及 repository 規定的 Standard authority gate。
- 靜態檢查：PowerShell parse、JSON schema validation、Python compile、`git diff --check`、變更範圍與歷史 2.12.0 evidence 掃描。
- rollout：先合併中央 authority；consumer 再更新 exact archive／34-file pins 與 runner hash，建立新的 immutable candidate，最後執行 timed SourceValidation。
- rollback：中央變更可由正常 revert 恢復 fail-closed；consumer 在新 authority acceptance 前不推送，因此不會把未驗證 profile 發佈到 main。
- performance acceptance：以新的 run-owned roots 執行 exact latest-stable SkillSpector resolver，記錄 wall time、receipt 與 closure identities；只有中央變更合併、consumer exact repin、完整 immutable tests 通過，且正式 SourceValidation 在 1,200 秒內完成，才推送 consumer branch。
- 2026-10-18 實測：只移除第二次 dry-run 的 fresh resolver 為 517.951 秒；再加入 `-B --no-compile` 後為 343.280 秒。installed tree 從 17,862 files／196,077,969 bytes／7,338 `.pyc` 降到 10,928 files／139,315,812 bytes／404 個僅屬 venv bootstrap pip 的 `.pyc`；66-wheel dependency closure、candidate inventory、normalized selection plan 與 selected closure identities 全數相同。以新 receipt 執行真實 manage-confluence-docs-as-code Static 為 120.315 秒，scan 前後 `.pyc` 均為 404，installed closure `2d43c65541846e60b50cf7a428bbe74272f74b2fdfcdacfc357240f7e1e414c9` 不變。相對既有 formal v10，搭配已驗證 parallel resolution／Static／sharded Pester 的保守總估算約 1,147 秒；仍須以合併後 immutable authority 的正式 run 判定 1,200 秒門檻。

## 5. 風險與未解決事項

- 2.13.0 新增與大幅修改多個 analyzers；profile 只修正 PowerShell ownership completeness，不宣稱整體 scanner 行為與 2.12.0 等價。正式 run 出現的新 findings 必須依原 severity policy 處理。
- 若真實 2.13.0 graph 不再允許現有 in-memory bridge 或報告 shape 不相容，維持 fail closed，另行調整 profile；不得用 pin 舊版或改寫 report 假裝通過。
- 單一 authoritative plan 僅限同一次 run-owned acquisition 與已驗證 wheelhouse；不得跨 run 快取或重用，也不得省略 helper cross-file verification、manifest binding、hash-locked install 或 post-install verification。
- 中央與 consumer 的 commit、push、PR／merge 仍需依 repository Git 授權邊界辦理。
