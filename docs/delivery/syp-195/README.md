# SYP-195 候選交付與部署接收

此目錄是惰性候選交付。`candidate/catalog/` 不在正式 `catalog/` 位置，不由 runtime 自動選取；raw descriptor 維持 `candidate/pending`。本目錄、隔離安裝成功或 package-only PASS 都不構成採用／發布批准。

## 固定來源

| 項目 | 值 |
| --- | --- |
| 中央規劃基準 | `838ed0619c3703af207b836b74eec5576d738c45` |
| Authority 實作 PR | [PR #76](https://github.com/SyuanTsai/SyuanTsai-AI-Instructions/pull/76) |
| 原始來源 | [cathrynlavery/diagram-design](https://github.com/cathrynlavery/diagram-design/tree/d1376371965f513d99cc9ec388835d255c5c88d5) |
| 完整 commit | `d1376371965f513d99cc9ec388835d255c5c88d5` |
| 版本標示 | manifest `2.6.64`；SKILL.md metadata `2.6`，不改寫上游 |
| 原始 ZIP | [不可變 codeload archive](https://codeload.github.com/cathrynlavery/diagram-design/zip/d1376371965f513d99cc9ec388835d255c5c88d5) |
| archive SHA-256 | `dbc9d20de788c82f0d34031df296d77df93272b58280a0625074254d1cd350fc` |
| 完整 Skill content SHA-256 | `ad655b3749a92dbbb9da3a5c42168eeb350b50221cbfb72e3cbf232039067e8f` |

只投影 `skills/diagram-design/**` 的完整 279 個檔案及必要原始授權文件／receipt。來源的 commands、hooks、Plugin manifest、MCP、根目錄維護 scripts 與其他 assets 不納入安裝。中央保存 metadata、validator、驗收原稿與成果，未保存外部 Skill source。

## 證據索引

- [候選 Catalog](candidate/catalog/skills-catalog.json)、[sources](candidate/catalog/skills-catalog.sources.json)、[Lock](candidate/catalog/skills-catalog-lock.json)：在既有中央資料上增加一個來源與非預設 `diagram-design` profile；其餘 pin 保留。
- [raw descriptor](candidate/raw-source-descriptor.json)、[package integrity](candidate/package-integrity.json)：完整原始 archive 重新展開比對、281 個 package／legal 原始檔的 inventory、原始 hash、central metadata ownership。`releaseEligible=false`、`adoptionApproved=false`。
- [隔離受管驗證](managed-acceptance.json) 與 [重現 harness](verify-managed-candidate.ps1)：包含實際套件、逐檔 hash、provenance、冪等、VerifyOnly、customized／unmanaged、profile、移除與交易失敗回復。使用本次中央 code 的獨立 runtime fixture 與派生候選 Catalog，未修改真實 USER scope。
- [實際 runtime bytes 綁定](managed-runtime-binding.json)：原報告的 `runtimeAuthorityCommit` 是 fixture Catalog 的基準，並非執行 module 的完整 identity。保留的 19 個 runtime modules 已逐檔比對雲端實作，記錄原始 bytes 與 Git blob SHA-256，僅正規化 LF／CRLF 後完全相同。後續 harness 直接記錄 `runtimeModuleInventory` 與明確的 `catalogBaselineCommit`。
- [三種 Mermaid 功能驗收](../../examples/diagram-design-acceptance/README.md)：架構、流程、時序；原稿、實際 extractor IR、HTML／SVG、fidelity 與瀏覽器證據。
- [實際 exporter／self_check](upstream-export-checks.json)：三種 exporter XML 與文字保留成功，三種 self_check 退出碼 0。未修改的 exporter 會加入 Google Fonts import，沒有通過離線攜帶性；交付 static SVG 使用另行繪製的完全內嵌版本。
- ASTRA `gpt-6-astra / xhigh` 完整惡意內容 JSON：Jira SYP-195 attachment `10035`，SHA-256 `6d289fad53400e895c4f5dafd3fafa0cfe64952ba0e82bc5b267702a74547733`；完整範圍為固定 279 個 Skill 檔案及 4 份 policy／license 文件，結論為未發現。該結論不能代替實際 SkillSpector 或授權確認。
- [授權後續查證](license-assessment.md)、[圖示來源 geometry 比對](brand-glyph-provenance.json)、[六份 static artifact 檢查](static-artifact-inspection.json)、[能力與漏洞處置](capabilities-and-safety.md)、[文件維護流程](../../diagram-design-document-workflow.md)。

## 重現隔離安裝

以核實 hash 的原始 ZIP、PR checkout 和全新 workspace 子目錄執行 `verify-managed-candidate.ps1`，明確傳入 `CentralRoot`、`ArchivePath`、`WorkRoot`、`ReportPath`。四項都是此電腦發現的絕對路徑。`WorkRoot` 和報告不可已存在。harness 建立自己的 `home-clean`／`home-rollback`／`home-unmanaged`，不使用 `$HOME`；不下載或執行上游程式。fixture 的 Catalog commit 表示實作基準，派生 Catalog／Lock bytes 另外由報告 hash 綁定，不冒充正式 Catalog。

## 正式採用與 SYP-259 接收

1. 完成 PR #76 的最新 HEAD required CI 與 human review，依中央 AGENTS.md 正常 merge authority 變更。記錄最終 merge SHA；目前尚無 merge SHA，不以分支 commit 代替。
2. 補齊原始套件必要授權／notice 與未證實素材的可用權利，作實際 license review；只禁用圖示不能掩蓋套件再散布權利缺口。依此結論處理完整套件，不自行裁掉檔案。
3. 以同一固定來源、descriptor、原始 archive 與最新已 merge authority 建立 fresh RunId 的 canonical `-SourceValidation`。凍結 adapter、module closure、schema、descriptor、archive 和工具 receipts；實際執行 skill-validator、skill-tools、完整 SkillSpector Static no-LLM、中央 raw ownership general／Pester checks。任何 severity／coverage 失敗保持阻擋，不能降級為 ordinary Core-only PASS。
4. `Validate-ThirdPartySkillSource.ps1 -SourceValidationEnvelope` 會強制 `RequireApproved`；現在的 pending descriptor 應被拒絕。尚未產生的正式 source CI／receipt／review 證據明列未完成，不填入猜測值。
5. 通過本單交付條件後，SYP-259 重新讀取四张前置 SYP-195／215／216／275、latest central/source、個人選取与實際已授權主機。以本候選差異重建正式 Catalog／sources／Lock，做部署時 CI、review、normal merge 後才生效。
6. 真實 USER scope 安裝、記憶入口切換及一次性更新由 SYP-259 執行。本次工作的電腦不自動成為部署目標。保留 notify-only，先產生 install/update/remove/preserve/ownership 清單與備份；正式執行後重驗 hash、discovery、冪等與回復。

更新需重新固定 SHA／hash、核對 upstream diff／license／ownership，重新稽核適用範圍及正式 source gates。首次採用之前的回復狀態為未安裝此 Skill；其後使用前一個核實 pin。中央使用正常 revert／修正 PR；主機僅回復 manifest 與當下 hash 足以證明為本次受管的檔案，保留個人 profile 和後續修改。
