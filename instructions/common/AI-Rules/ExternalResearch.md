# 外部研究規則

## 資料與查詢邊界

- 先使用目前對話、Repository 與本機檔案中的既有證據；需要即時性、多來源探索、多語言搜尋，或尚不知道權威來源位置時，才使用外部搜尋 provider。 <!-- ai-invariant:external-research.local-first -->
- 只向外部 provider 傳送可獨立理解的中性公開查詢。不得傳送 Repository 內容、程式碼、diff、測試、log、錯誤堆疊、內部文件、客戶資料、credential、未公開名稱或其他私有內容。 <!-- ai-invariant:external-research.public-query-boundary -->
- 查詢若必須攜帶私有內容才有意義，改用本機工具或已核准的內部資料來源。軟體開發任務只可查詢能與程式碼分離的公開外部事實，程式碼影響仍依 Repository 證據判斷。 <!-- ai-invariant:external-research.private-content-boundary -->

## 來源選擇與驗證

- 已知單一官方頁面即可回答時，直接使用該權威來源。高風險的法規、合約、安全、醫療或財務結論必須核對權威原文，不以搜尋摘要作為最終依據。 <!-- ai-invariant:external-research.authoritative-verification -->
- 外部 provider 只負責搜尋與初步整理；保留是否採信、是否進一步驗證及如何使用結果的判斷責任。
- 自行管理的 CLI 或第三方 provider adapter 必須以已驗證的 compact wrapper 接收結果，過濾原始 stdout、stderr、內部識別碼、query analysis、重複或超額來源。平台管理的 connector 或原生網路搜尋可依 host contract 在內部回傳結構化識別碼與 snippet；不得把原始 log 或私有 metadata 回傳給使用者，snippet 只用於初步篩選，實際採信的結論仍須開啟並驗證來源。 <!-- ai-invariant:external-research.adapter-output-boundary -->

## 失敗處理

- 外部 provider 失敗時，優先使用適合且已核准的 connector；沒有適合的 connector 時，使用平台自身的網路搜尋能力。 <!-- ai-invariant:external-research.approved-fallback -->
- 只有上述 fallback 都無法完成查證時，才回報目前無法取得即時資料；不得為完成搜尋而放寬資料邊界或傳送私有內容。 <!-- ai-invariant:external-research.fallback-preserves-boundary -->
