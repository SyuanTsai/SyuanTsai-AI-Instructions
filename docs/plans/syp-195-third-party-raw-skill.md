# 計畫：第三方原始 Skill 接合與 diagram-design 候選交付

## 1. 目標與範圍

- 以中央第三方來源 descriptor 驗證不可由中央維護的原始 Skill，保留原始套件 bytes。中央不保存 Skill、不注入假的 `catalog/source.json` 或 `agents/openai.yaml`。
- 既有來源維持 Standard 的 source-owned inventory 與介面 metadata 要求。新增明確 opt-in 的原始第三方路徑，完整保留固定 SHA、archive／Skill 雜湊、portable package、安全工具與 lifecycle 要求。
- 驗收：descriptor strict schema、完整 package hash 與授權文件 hash 綁定；缺 metadata 明列中央 ownership；candidate 不能冒充 approved；正式來源驗證仍使用 `-SourceValidation`。
- 交付：normative 契約、schema、package adapter、回歸測試、授權交付修正、文件流程與 review PR。正式 Catalog／sources／Lock 啟用與真實 USER scope 由集中部署流程接收。
- 不變更上游 bytes、不建立 wrapper、不採用 Plugin 的 commands/hooks/MCP。既有 dirty checkout 保留。
- 已核實：中央基準 `838ed0619c3703af207b836b74eec5576d738c45`；外部固定候選 `d1376371965f513d99cc9ec388835d255c5c88d5`。ASTRA 的惡意內容結論為未發現；四項使用漏洞與部分圖示授權證據仍需分開處置。
- 依賴／決策：authority regression、required CI 與 human review 通過後才正式採用 descriptor。沒有實際 review 或工具報告不得宣稱完成 source conformance。

## 2. 預計修改

### 2.1 中央 ownership 契約與 adapter

- 目標：`docs/standards/skill-repository-standard.md`、新增 `third-party-raw-skill-sources.md`、schema、`scripts/third-party-skill-source.psm1` 與 `Validate-ThirdPartySkillSource.ps1`。
- 現況：Standard §§4.4／5.1 要求來源擁有 metadata；現有 upstream adapter 只處理 Plugin 等 surface，未涵蓋原始第三方 Skill。
- 改變：以中央 descriptor 記錄 source identity、明確採用套件、完整 content hash、缺 metadata 狀態、中央介面資訊、必要授權文件與 review 狀態。descriptor 僅作驗證／routing metadata，不投影進上游套件。
- 原因：能取得 raw bytes 不等於來源符合 Standard。中央選擇要求外部 owner 未提供的 artifact，必須以明確 alternate contract 處置。
- 風險：放寬治理或偽造來源。採 strict schema、重複 key／未知欄位拒絕、精確 identity、完整 inventory、candidate 與 approved 分離，以及不變的 SourceValidation／安全門檻。

### 2.2 必要授權文件交付

- 目標：`scripts/license-delivery.psm1`、`scripts/skills-catalog-contract.psm1`、兩組直接回歸與 manifest 範例、`docs/license-delivery.md`／Catalog README。
- 現況：`THIRD_PARTY_NOTICES` 會交付，但 `THIRD_PARTY_LICENSES.md` 不會。
- 改變：辨識明確 `THIRD_PARTY_LICENSES` 文件名稱及既有文字副檔名，保留原始 bytes／source path／receipt；不以檔名推論 license grant，不把同名前綴程式當授權文字。
- 影響：所有 consumer 共用授權交付 module；對既有檔案分類維持相容。
- 隔離安裝重現 manifest provenance classifier 仍拒絕 `THIRD_PARTY_LICENSES.md`；同一檔名規則同步修正，保留程式副檔名拒絕。既有 JSON schema 的安全 license source path 已涵蓋此文件，不改 schema shape 或版本；範例與 parser/schema 回歸同 PR 驗證。

### 2.3 文件與候選維護規則

- Mermaid 原稿維持 Source of Truth，HTML／SVG 為呈現；變更先修原稿並保留 revision、來源引用與 fidelity ledger。
- Solution Design、ADR、PR、Notion／Confluence 與簡報依目的端能力使用原稿、靜態圖或附件；發布依既有授權。
- Profile 與原 pin 分離；上游 style-guide 修改視為 customized drift，禁止把改過 bytes 當原 pin。
- 候選 Catalog／sources／Lock 只能準備為部署接收資料。此 PR 不改現行 production pin 或 default core。

## 3. 測試情境與 TDD

### 3.1 授權文件

- 單元：Given root／ancestor 第三方授權文字與同名前綴 Python；When 選取單一 Skill；Then 精確交付文字、排除程式與其他 Skill，原始 bytes 與 receipt 一致。
- Red：新情境因 `THIRD_PARTY_LICENSES.md` 未辨識而失敗；Green：最小檔名 pattern 修正；Refactor：既有 license tests 保護分類、reparse、冪等與 scope。

### 3.2 第三方原始來源

- 單元／整合：有效 candidate、錯 SHA／archive／content hash、未知或重複 JSON key、unsafe path、隱藏額外 package bytes、缺／改授權文件、假 approved、metadata 來源 ownership 衝突、reparse，以及原稿完整 inventory。
- Red：新 adapter 不存在／缺少行為而失敗；Green：共用 acquisition 的 inventory 與 portable frontmatter validator，加 strict descriptor 驗證；Refactor：保留正負 fixture 與既有 modules 的安全限制。
- authority 三組受影響 regression 同 PR 驗證新契約仍要求真實 source 工具且 `releaseEligible=false` 的 package-only 報告不能代替 SourceValidation。

### 3.3 來源驗證與採用批准分離（2026-10-08 修正）

- 已核實：使用者改以 2026-10-08 當前最新版本為目標；即時 Git 遠端 HEAD 與 GitHub commits/main API 都解析為 `d1376371965f513d99cc9ec388835d255c5c88d5`、manifest `2.6.64`。重新下載的 archive SHA-256 與既有固定候選相同。新增查詢與 bytes 綁定紀錄，目標仍是完整原始 Skill。
- 問題：`Validate-ThirdPartySkillSource.ps1 -SourceValidationEnvelope` 強制 `RequireApproved`，在 package stage 前要求 descriptor 已有人工與授權批准。這將來源檢查與正式採用批准混為同一門檻，違反既有 Standard §8.1.2 的 source-only／`releaseEligible=false` 界線。
- 目標檔案：`docs/standards/third-party-raw-skill-sources.md`、`scripts/Validate-ThirdPartySkillSource.ps1`、`tests/third-party-source-envelope.Tests.ps1`、三組 authority regression 與交付 README。descriptor schema 與上游 bytes／hash 不變。
- 改變：SourceValidation package envelope 接受完整且有效的 candidate/pending descriptor；保留實際 supervisor context、同候選 inventory、archive／Skill／legal bytes 綁定及所有原有工具／Static／repository checks。source report 必須保留 `adoptionApproved=false` 與 `releaseEligible=false`；正式採用入口的明確 `RequireApproved` 仍拒絕 pending，假 approved claim 仍拒絕。
- TDD：先改為 pending 可接受來源檢查、顯式採用批准仍拒絕 pending、假批准仍拒絕的行為測試，觀察現有強制前置產生的 Red；再以移除 envelope 的隱含 `RequireApproved` 作最小 Green。同步 normative boundary 與 authority regression，防止錯誤門檻復原。
- 相容性／回復：既有已批准 descriptor 仍可檢查，`RequireApproved` 介面不變；變更不啟用正式 Catalog 或 USER scope。回復使用正常修正／revert PR，保留 source-only 與正式採用批准的分離。
- 驗證：目標 envelope／raw-source suite、三組 authority regression、licensing inventory 與最新 HEAD CI；正式 raw source tools 在中央契約正常 review／merge 後執行，不以本次 package check 或 fixtures 冒充實際 SourceValidation。
- 授權查證與來源工具證據各自保留；證據不足不自動等同必須換版或 Fork。只有證據確認原路徑無法滿足採用條件時，才提出來源變更決策。

### 3.4 原始第三方來源的中央測試 ownership（2026-10-08）

- 已核實：中央契約已正常合併，但 `Assert-StandardCoreSourceCheckReport` 仍將所有 Pester case 與完整 test inventory 綁在 candidate 的 `tests/`。未修改的外部來源沒有中央 Pester suite，因此該實作無法履行本案已核准的中央測試 ownership。
- 目標：`Invoke-StandardValidation.ps1`、Core adapter／evidence schema、Core machine-readable contract、raw normative 文件、三組 authority regression；新增中央 raw-source Pester 執行入口，輸出真實 discovery／execution sidecar。
- 改變：以可省略的固定 `sourceValidation.testOwnership=central-third-party-raw-skill-v1` 明確選取中央擁有的兩組完整 raw contract suite。測試路徑由 authority 定義，caller 不能自訂清單或 root。核對同一 authority Git revision、實際 bytes 與 frozen files；sidecar 保留 candidate snapshot 綁定，另外記錄 test-source identity。僅 package stage 實際成功回報 raw contract 時可使用。
- TDD：Given 無上游 Pester suite 的完整 raw candidate 與凍結中央 suite；When strict source-report gate 核對；Then 完整 case union 可通過。先觀察原 gate 拒絕的 Red，再修正 inventory ownership。加入錯 authority、變更測試 bytes、缺 frozen file、錯 test root、遺漏 suite／case、普通 source 冒充 raw 及未知 ownership 的拒絕情境。
- 安全／相容：既有省略欄位的來源仍要求完整未篩選 candidate `tests/`，不得改成中央 suite。保留所有三個實際工具、完整 Static、severity、非空 counts、零失敗／零跳過、timeout、cleanup 與 candidate hash；不注入上游檔案。Source-only 仍 `releaseEligible=false`。
- 執行入口以核實的 Pester module 路徑執行固定完整 suite，從實際 Pester result 取得 discovery／execution、block／container failure、case identity 與 counts；不能使用固定數字或合成 sidecar。工具 setup 與 source execution 分離，執行期間不下載。
- approved-source resolver 已取得核實的 Pester 6.2.0；實跑兩組 suite 的 15 cases 都因舊 `Should Be/Throw` 呼叫失敗。改用兩個 framework-independent assertion helpers，保留相同正負 assertions，兼容既有 Pester 4 authority lane 與正式 Pester 6；兩個版本都必須實跑驗證。
- 交付／回復：同一 authority PR 完成三組 regression 與 CI，再由 human review 正常合併；之後才套用正式來源。回復以正常 revert PR 恢復舊行為，production pin／USER scope 均不變。成功以實際 native SourceValidation 證據為準。

## 4. 交付與驗證

- 本機目標測試：license、third-party adapter、三組 authority regression；必要 catalog 與 source acquisition regression；`git diff --check`。
- PR 的既有 WindowsCore／authority gate 使用最新正式 resolver 工具與相同候選／authority identity。記錄實際工具 receipt、CI 連結、執行與未執行项。
- 先交 reviewable authority PR；human review 通過並正常 merge 後，再依核准契約對 raw candidate 執行正式 SourceValidation。任何工具或 gate 失敗保留原始報告、阻止正式採用，不降級為 ordinary Core PASS。
- 正式功能驗收：三種 Mermaid 圖、中文、HTML／SVG、fidelity 與有界執行。受審程式只在無秘密且限制檔案讀取的環境執行；同帳號子程序不宣稱 read isolation。PNG 依賴另列。
- 受管安裝使用隔離 user root，驗證精確 279 檔與必要授權文件、provenance、customized／unmanaged 保護、缺依賴、冪等、移除及失敗回復。正式主機保留原狀。
- 回復：中央正常 revert PR；候選使用前一個核實 pin；host 僅回復 manifest 受管且 hash 未被後續個人修改的檔案，保留 profile。
- 成功訊號：所有實際要求的 CI／review／SourceValidation 与驗收索引齊全，接收者可只靠雲端資料重現候選。

## 5. 風險與未完成項

- Python import、HTML 主動內容、self_check 漏檢與 draw.io 累積解壓限制是使用漏洞；對預定 Mermaid／靜態輸出路徑逐項驗證處置，不把未使用能力默認為已安全。
- 部分 icon 精確來源／license 未確認；在完成必要授權 review 前，descriptor 保持 candidate／pending，未證實圖示不進入正式可用呈現。
- ASTRA 證據不是 SkillSpector。未 merge 的 authority proposal 不是正式來源豁免；human review、source tools 或正式功能驗證未完成时，SYP-195 保持進行中。
