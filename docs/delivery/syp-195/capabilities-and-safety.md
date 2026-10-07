# 能力、相依與四項使用漏洞

Catalog v2 的 `dependencies` 表示 Skill 間相依。diagram-design 無其他 Skill 的硬相依；文字／範例參考不需要 Python，所以候選未把 Python 或瀏覽器設為整個 Skill discovery 的硬門檻。下表是各能力的實際前置條件與驗收狀態，不能用空的 Catalog dependencies 推論所有能力都可執行。

| 能力 | 必要前置與缺失處理 | 本次證據 |
| --- | --- | --- |
| Mermaid 原稿與重繪 | 可讀原稿、明確 profile 與 fidelity；缺 parser 時保留原稿並回報未解析 | 三種完整原稿／IR／HTML／SVG |
| Python extractor／SVG exporter／self_check | Python 3 與無秘密、低權限、限制檔案可讀範圍的有界執行環境 | 固定官方 Python 3.14.8 容器，`-I -B`；network none、readonly root、nonroot、cap-drop、memory/pid/cpu limits |
| HTML／SVG 視覺 | 真實瀏覽器及可用 CJK 字體；缺失時不宣稱視覺通過 | 既有 Chrome 154.0.8037.98，六份實際截圖已檢視；本機 CJK fallback，无外部資源 |
| 上游 SVG export 的遠端字型 | exporter 自動加 Google Fonts import；離線目的端應使用核實的完全內嵌 static SVG | XML／文字保留 PASS；離線攜帶性未通過；未下載字型 |
| PNG／瀏覽器自動 export | 上游流程所需 Playwright／Chromium 等須獨立核實與授權；缺失時列受影響能力 | 未執行 Skill PNG automation；Chrome 驗收截圖不冒充此能力 |
| draw.io import | 累積解壓／輸入／執行量需有界；外部連結與 active content 按不可信資料檢查 | 未驗收、未核准；不能以 Mermaid 成功宣稱安全 |
| Notion／Confluence／簡報 | 目的端實際支援格式與既有寫入授權；連回原稿 revision | 已交輸入／產物／維護規則；未冒充各目的端實際發布 |

## 四項既有使用漏洞的處置

| ID | 觀察 | 本次有效處置與剩餘限制 |
| --- | --- | --- |
| UR-01 | Python import 未隔離 | 實際候選 script 在 `python -I -B`、無秘密、只讀 Skill 掛載、network none、nonroot 容器執行；沒有把一般同帳號子程序說成檔案 read isolation |
| UR-02 | 不可信 HTML 主動內容／SVG 無 sanitizer | 交付由本次原稿重繪的無 script／event／外部資源 static artifact；外部 HTML／SVG 的 sanitizer 未驗證，不能在私人登入瀏覽器執行；原始 exporter 的字型網路引用另列 |
| UR-03 | self_check 未涵蓋導航／相對資源 | 實際 self_check 加獨立 artifact 檢查：URL scheme、導航、CSS import/url、object、event、相對資源與外部依賴。三種輸出無此類資源；self_check PASS 單獨不構成安全／視覺 PASS |
| UR-04 | draw.io 無累積解壓 budget | 保留完整 raw package 的觀察；本次不核准 draw.io 能力，尚須正式有界執行／解壓驗證。容器記憶體／CPU 限制不能冒充程式已實作累積 budget |

四項均不是「發現惡意 Skill」的證據。未驗收能力不自動安裝工具；已通過 Mermaid 路徑不擴張成所有能力安全。

## Profile

候選 `diagram-design` profile 為非預設，只表示 Catalog 選取。正式部署應保留原有 profiles／includeSkills／excludeSkills，按接收差異增加選取；本次隔離 fixture 明確只選它，以避免下載其他 sources。個人品牌、字體、色彩與 detail level 保存在獨立使用者 profile 並記錄 hash/revision；本次使用 `neutral-acceptance` 測試 profile，不改上游 style-guide。Onboarding 若修改受管 style-guide，視為 customized drift；本次實際驗證已證明會停止 mutation 並保留它。
