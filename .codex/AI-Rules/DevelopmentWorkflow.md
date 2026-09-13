# 開發任務交付流程

## 範圍與授權

- 從任務開始、接手到交付，持續完成使用者已授權範圍內的實作、驗證、PR feedback 處理與進度同步。已明確授權的持續操作不逐次重問；使用者只要求 Review 時，維持唯讀審查。發現會實質擴大範圍、改變權限或不可逆的操作，先完成可審閱成果，再針對缺少的授權詢問。 <!-- ai-invariant:development-workflow.scope-and-authority -->

## PR findings 與完成判斷

- 實作任務已有 PR 時，主動讀取全部分頁的 review threads、review summaries、Conversation comments 及 CI 結果。逐筆保留 finding 連結、適用 commit、嚴重程度、處置與證據；已 resolved、outdated、沒有 inline thread 的 finding 仍需核對實際處置。 <!-- ai-invariant:development-workflow.complete-feedback-inventory -->
- 對成立且在範圍內的 finding，依適用 Testing 規則修正與驗證；在已授權的 branch commit／push 與 PR 回覆範圍內，主動推進到可核對的結果。回覆修正 commit、行為說明與測試／CI 證據後，才 resolve 對應 thread。不成立或已被其他修改涵蓋時，回覆當前程式碼與驗證理由；需由 reviewer 判定時保留未解決。範圍外或受阻項目保留原因、責任歸屬及下一步，不以 resolve 隱藏。 <!-- ai-invariant:development-workflow.finding-evidence-loop -->
- 每次修改或 push 後，重新讀取新增 findings 與 CI 並持續修復；在最後一次提交後核對 PR HEAD、reviewed commit、所有 findings 的處置及 required checks。等待外部 review／CI 時，單次等待最多 60 秒並逐步降低查詢頻率；每次交付檢查預設最多等待 10 分鐘，使用者指定的等待範圍優先。仍待人工或外部結果時，記錄 pending gate、目前 HEAD、已完成證據及接續條件，交接並繼續不受影響工作，不無限輪詢或宣稱批准。HEAD 改變時重新驗證受影響證據。只有綠燈、已合併或 unresolved threads 為零，不能單獨證明驗收完成。PR 已合併才發現遺漏時，明確登錄差距並在任務範圍內以後續修正 PR 處理。 <!-- ai-invariant:development-workflow.final-head-review -->

## Ticket 進度同步

- 任務已明確綁定 ticket，且使用者已授權本次或持續進度同步時，在開始／接手、階段完成、PR 建立或更新、新阻擋、阻擋解除、合併、交接與結束前主動同步。用簡短 checkpoint 記錄已完成、進行中、阻擋、下一步及 PR／commit／驗證連結；對應子單放執行細節，父單只更新有意義的整體變化。維持適量更新，沒有實質變化不重複留言。 <!-- ai-invariant:development-workflow.ticket-progress-sync -->
- 先確認正式站台與 issue 身分，按使用者明確授權同步留言及符合事實的工作狀態。只有明確給予的持續授權可重用；逐次核准要求、撤回或縮小授權均須遵守，除非使用者較新的明確指示已取代該限制。既有文件不能自行創造或擴張授權。每次寫入後回讀；不確定是否成功時先查重再重試。工具無權限或失敗時明確回報未同步，保留可貼上的 checkpoint，繼續不受影響工作。沒有已綁定 ticket 時不自動建立；沒有外部寫入授權時先完成草稿。結案須符合整張單的驗收；PR merge、局部測試通過或 Notion 交接不能取代 Jira 正式進度。 <!-- ai-invariant:development-workflow.ticket-authority-and-verification -->

## 最新穩定版與可重現驗證

- 每次 run 先確認使用者與 Repository 的有效版本政策及允許來源。最新 stable 是本共通流程的升級目標；現有 SDK／runtime／測試框架 pin、內部 registry 或來源限制仍約束實際驗證，除非本次有明確升級授權。使用者或 Repository 已明確採用 latest-stable 政策的流程，須於每次 run 開始從官方發布資訊解析流程可控制的工具、SDK、runtime、測試框架、驗證器與 scanner 最新 stable，經允許來源取得並實際使用。記錄政策、解析時間、來源、版本、執行路徑及 hash／digest，優先用任務隔離環境。尚未採用該政策的專案按有效 pins 執行基準驗證，另列與最新目標的差距及升級工作；基準通過不能宣稱最新版驗收通過。只修改版本宣告、寫 latest 或查到版本但執行舊 binary，均不符合最新版驗收。 <!-- ai-invariant:development-workflow.latest-stable-toolchain -->
- 解析後將確切版本與來源身分固定至整次 run 結束，下一次 run 再解析；local、pre-push 與 CI 使用同一策略，沿用證據時必須核對 candidate、工具與環境身分。最新版不相容或無法取得時記錄具體阻擋並在範圍內修復，不默默降版或放寬檢查來宣稱通過。舊版相容性測試可另外執行，但不能替代最新版驗收。 <!-- ai-invariant:development-workflow.frozen-run-evidence -->
- 維持已批准的 source／authority commit、archive hash、action SHA 與安裝 lock；最新版策略不等於把來源改成 floating ref 或略過 integrity／release approval。專案產品 dependency、OS／IDE／driver／host 更新若超出任務授權，列明目前版本、最新目標、差異與所需升級工作，不擅自升級或宣稱全部已是最新版。使用者明確指定版本或接受例外時，記錄其範圍與理由。 <!-- ai-invariant:development-workflow.version-boundaries -->

## 交接

- 結束或交接前，保存當前 candidate、已完成與未完成驗收、逐筆 finding 處置、CI 結果、工具版本及 ticket 同步結果。區分歷史快照與最新狀態；尚未整合的變更與未解決事項必須讓接手者可直接找到。此流程描述執行中任務的責任；跨回合監看或排程只有在使用者要求且能力可用時才建立。 <!-- ai-invariant:development-workflow.handoff-continuity -->
