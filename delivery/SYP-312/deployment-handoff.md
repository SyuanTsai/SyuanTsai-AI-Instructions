# SYP-312 中央版本交付

本批將四個中央 source pin／immutable Lock 指向 SYP-310 已接收的正式 merge。13 個 active Skill、既有 profiles、memory rename／tombstones 與 Catalog bytes 保持不變。這是中央版本同步；USER、release、install、live 與退役尚未執行。

可跨電腦核對的完整前後 Lock、三份文件 hash、16 個來源套件 hash、source tree／archive 與 rollback 見 [version-transition.json](version-transition.json)。正常中央 PR／merge 與最終 required CI／Review 結果另由 SYP-312 正式 Jira 交付紀錄指向；本文件不將未完成的檢查寫成 PASS。

| source | 更新前 | 本批正式 merge |
| --- | --- | --- |
| general | `0066b8e7f93f7a3654c6232f63a06b277a0d8664` | `5f642e2ebe219cd1c74222a9f4ed88548518efbe` |
| code-collaboration | `0b18e7f02d90e03c3b7b7b3268a5c18a206a761d` | `3af2fbf562120a6098b91197ec17e2607d162896` |
| knowledge-content | `14a667abd9489635d333ab2c18a02ab8f3c274cf` | `645390635c2cead49b79f864031f8b7ee3b6b3d2` |
| atlassian-ecosystem | `22cc97cbbc6c078069516b21acbd33f8cc58eb54` | `a25fd9fe97c35d2a1ee80bf832cae793784c34ce` |

四個 Skill content hash 改變：`write-copilot-implementation-prompt`、`capture-private-course-knowledge`、`configure-confluence-api-access`、`review-bitbucket-pull-request`；其餘九個不變。Catalog SHA256 保持 `1b154ca06c809d3cfae9232badb59bdd67b88e39e1c18020d959d4669a2897c5`。

## 驗證與 hash 用途

310 固定索引的 86 個檔案全部核對，零不符；四份封存 canonical ZIP 與既有 generator 重算的 13 個 Skill hash 一致。三份 JSON Schema／跨文件 parser、51 個既有 Catalog／selection Pester 測試、封存 ZIP 及重新下載 canonical codeload 的 `update-skills-catalog-lock.ps1 -Check`、`git diff --check` 通過。未修改 schema、parser、更新算法或來源工具，也未重跑已接收的慢速 source baseline。

Skill hash 沿用 `Get-SkillInventorySha256`：repository-relative path 按 Ordinal 排序，串接 path＋TAB＋原 bytes SHA256＋LF，再以 UTF-8 無 BOM 做 SHA256。Git/LF、Windows CI CRLF 與原生工具 digest 各保留用途，不能互換。

Catalog source pin 與 validation authority 分開：General／Code／Knowledge 保留 `8e627baf54bd6e47862e6291b25e71cc45a2f2b7`／32 檔；Atlassian 保留 `098e40d26de585e5565a031d9b826454e6a34720`／34 檔。中央 332 的 358 role bindings／179 unique files 是 native CI byte 證據，不是 32／34 transport tuple。Darktide 的獨立 legacy authority／14 檔不納入中央選取。

## 交給 SYP-259

- 目前 Catalog 的 13 個 active Skill 與四來源 16 個實際套件分列；`operate-environment-authorized-sql`、`review-agent-skills` 未因來源 inventory 而自動加入 Catalog。
- `manage-confluence-docs-as-code` 的固定 27 檔／content hash 已交付，仍未加入中央選取。259 的歷史 replacement 意圖與最終來源的 routing 有差異：最終 SKILL 明確將一次性頁面發布留給 `publish-requirements-to-confluence`。259 須先核對這項 lifecycle／activation 處置；本批保留現行 publisher，沒有自動退役或改 profiles。
- 259 承接原 profile／USER 更新、舊 Skill ownership／退役、consumer 與 projectless discovery、install／reload／use／recovery，以及 320／321 主機驗收。323 已由真人接受 no-change，host 未執行；322 維持 N/A。中央同步不代表 USER 已更新，舊 USER 38 檔符合舊 manifest 也不能作 installed/live 證據。
- General PR84 的長路徑 caller／reader／cleanup、195 固定 diagram-design source `d1376371965f513d99cc9ec388835d255c5c88d5`／279 檔的 native 錯誤與未執行 scan／install／live，仍由 259 原範圍接收。
- 維護準則已由中央 PR88 merge `76cee33b5e9b91b8a21f362f2936078c74a68fb7` 正式交付；來源開發入口缺少引用屬 259 收尾，不加入 Skill 安裝包或重開來源功能。

全部來源仍屬 source-only developer harness，不能作獨立不可信 candidate attestation。Atlassian Stages 1–5／519 通過，但 Stage6 為 BLOCKED／exit10、整體 run 為 failure；PR22 producer provenance P2／Medium 實質未修，171 延後 findings 與 314LP3 限制保留。`releaseEligible=false`；耗時目標保留真實數據，為非阻擋追蹤。未恢復排程、未處理 341、未填工時。

## 回復

完整上一組中央版本為 `098e40d26de585e5565a031d9b826454e6a34720`，本批以前的完整 Lock 已保存在 JSON。需要回復時，以正常 reviewed revert／修正 PR 一起還原 `catalog/skills-catalog.json`、`catalog/skills-catalog.sources.json`、`catalog/skills-catalog-lock.json` 至該組相容版本，重新執行既有 Lock Check 與 required CI。不得混用新舊 pin／hash 或重設共享 main。本批沒有修改 source authority；來源自己的完整 rollback tuple 留在 310 正式接收材料。實際 rollback／USER recovery 未執行。
