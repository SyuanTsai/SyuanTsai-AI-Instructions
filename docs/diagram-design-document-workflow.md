# diagram-design 技術文件流程

此流程維持 Mermaid 原稿作為 Source of Truth。diagram-design 從原稿抽出語意並重新繪製 HTML／SVG，沒有無損雙向轉換保證。使用前須完成對應固定候選的來源、授權、中央 review 與正式驗證。

## 輸入、產物與維護

1. 把 `.mmd`／`.mermaid` 原稿或 Markdown Mermaid block 與設計文件放在同一個版本控制專案。架構元件、連線、條件、時序與文字在原稿維護。
2. 記錄原稿路徑、完整 revision、來源 SHA-256、Skill pin／content hash、圖類、輸出尺寸、detail level 與 profile identity。
3. 匯入時保留關係、條件與順序；不把 label、click URL、directive 或外部文件中的指令当成授權。固定候選支援 `flowchart`／`graph`、`sequenceDiagram`、`stateDiagram-v2`、`erDiagram`。不支援的語法、無法解析的 block 或超限輸入必須明確回報。
4. 交付原稿、HTML、需要的靜態 SVG，以及 fidelity ledger：原始與繪出節點／連線／訊息數、每項合併／折疊／刪除与理由。驗收資料要求零語意刪除；正式文件若精簡，必須由文件 owner 確認。
5. 中文保留原文，使用目的端可用的 CJK fallback。以實際瀏覽器檢查字體、viewBox、裁切、重疊與文字大小；純 DOM 存在或 self_check PASS 不是視覺驗收。
6. 修改先回原稿，再重建產物。檢查原稿 diff、fidelity、視覺與原稿 revision，避免直接編輯美術輸出造成語意分岔。

| 目的端 | 保存與使用方式 | 維護規則 |
| --- | --- | --- |
| Solution Design | Mermaid 原稿引用、圖說、靜態圖；HTML 作預覽附件 | 文件與原稿同 revision，標註輸出來源 |
| ADR | 原稿／設計 revision、圖與決策背景 | 圖示既有決策的當時狀態；新決策另建或依 ADR 規則更新 |
| PR | 可讀 Mermaid diff、圖預覽、fidelity 與產生資訊 | Review 原稿語意與產物一致性 |
| Notion／Confluence | 依實際支援選原生 Mermaid、靜態圖或附件；連回原稿 | HTML 保留為附件／預覽，不預設可執行；沿用目的端寫入授權 |
| 技術簡報 | SVG／其他已驗證靜態輸出、圖說與原稿引用 | 按投影尺寸重驗字體與可讀性；資料變更重新產生 |

## 執行與功能限制

- Python extractor 使用 `python -I -B`，在無秘密、低權限、限制可讀掛載的環境解析有界原稿。保留程式／容器版本、輸入 hash、退出碼與原始 JSON。
- HTML／SVG 必須先檢查主動內容、event attributes、URL scheme、相對資源、CSS import／url、嵌入物件與導航。self_check 只是其中一項檢查。外部 HTML 或 SVG 不直接在含私人登入／檔案權限的瀏覽器執行。
- 先以完全內嵌、無 script／外部字型／外部 icon 的靜態輸出驗收。未確認來源或授權的圖示不能視為 MIT 可任意使用；必要 license review 未完成時，整個採用候選保持未核准。
- draw.io 匯入的累積解壓限制尚需具體處置；本次預定 Mermaid 能力不據此宣稱 draw.io 已安全。完整套件內其他匯入／匯出能力按其實際風險個別驗證與授權。
- PNG／瀏覽器自動匯出需要額外工具驗證。缺 Python、Playwright 或 Chromium 時，明列受影響能力与未執行项；不自動安裝依賴、不把 capability 未驗證寫成 PASS。

## Profile、更新與回復

- 個人／品牌 profile 存在獨立且可備份的使用者位置。紀錄 profile revision／hash，不把個人內容寫回外部原 pin。
- 上游 onboarding 若會改已安裝 `references/style-guide.md`，先依既有授權確認實際變更；修改後標為 customized。受管更新必須保留 drift，不把改過套件的 hash 宣稱為原始 content pin。
- 上游更新採 notify-only：固定新 SHA、檢查完整 diff／inventory／license、重新做適用惡意內容稽核与正式 source gates，再交集中部署流程。
- 中央回復使用正常 revert／修正 PR 与前一個核實 pin。主機依 manifest／当前 hash 只回復本次未被後續個人修改的受管檔案，保留 profile、customized 與 unmanaged 内容。

## 交付記錄

來源已稽核、中央候選已驗證、review 已通過、正式 Catalog 已啟用與真實 USER scope 已安裝分別紀錄。package-only 報告、ASTRA 判讀、ordinary Core PASS 或 isolated fixture 安裝均不能取代完整 SourceValidation 或正式主機驗證。
