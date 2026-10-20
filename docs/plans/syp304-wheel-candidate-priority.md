# 計畫：循序探索共同相容的 wheel candidate

- 目標／範圍：固定四路 closure hashing 保持原 bytes，其他 concurrency、Pester、worker、sharding 不變。只改善 `Resolve-PythonWheelClosure.py` 在 verified local pool 已由 pip 判定無解後的 candidate 探索順序。
- 證據：真實 acquisition 的前兩輪重複相同 httpx 約束衝突（root >=0.28、另一 parent <1.0）；`_eligible` 使用任一約束的 over-approximation，導致逐版取得 1.x，再反覆啟動 offline pip，直到探索 0.28.x。helper 合計 165.056 秒、12 輪。
- 最小修正：僅 backtracking 時先探索符合目前 graph 全部 specifiers 的 descriptor，再探索原本任一 specifier 的 fallback；兩組各自保留既有 PEP 440/tag 排序。初次最高版本 seeding 不變。不得刪除、永久排除或把 fallback 標記為 attempted；graph 仍每次重算，最終仍由現有 isolated offline pip 決定 exact closure。
- Red／Green：離線 fixture 包含 root >=0.28、parent <1、數個高於共同範圍的 versions；舊版須多輪，目標 <=2 pip rounds，selected wheel 必須是共同相容版；另證明回退組仍可探索。先最小 Red，再 production 改寫，最後完整 helper self-test、三個 authority suites、同 gate 與真實分段收益。
- 權威契約：先在 normative Standard 說明這是優先順序而非 pruning，同步 standard/workflow/resolver regressions。原有來源、HTTPS/redirect、SHA-256、metadata、direct-reference、Requires-Python、yanked、isolated interpreter、offline pip、budget 及完整 closure 檢查不變。
- 驗收：不以離線 fixture 時間推算正式收益。真實 acquisition 分段必須支持完整 wall <=1200 秒，才跑一次完整 preflight，之後 immutable 正式 Stages 1–5 與後續 Git/PR 流程。失敗只按實測根因修正，不新增並行變體。
- 風險／回復：目前 graph 可能包含會被 pip 捨棄的 parent，故共同約束只能作優先提示；保留原始 fallback 是必要安全／可解性邊界。未證明收益或相容性則還原這個循序候選，保留已驗證四路基線與 evidence。

## 實測

- Red：真實 offline pip fixture 原本需要 6 輪，未達 <=2 輪要求；Green 在 2 輪內選出共同相容版，並能繼續探索原本的非共同 fallback。完整 helper self-test 通過。另補強初次 seeding 確實保留最高相容版的行為 assertion。
- 完整 resolver／workflow adjacent regression 71/71，0 failed/skipped/pending。
- 全新四工具 acquisition 327.651 秒，resolver exit 0、4 份同 run receipts、stderr 空白；相對相同四路基線 381.661 秒減少 54.010 秒。實際 pip 12→3 輪、candidate 77→68、selected 仍 66。
- 兩次 selected closure 只有上游 certifi 從 2026.10.18 更新到 2026.10.19，其他 selected versions 與 wheel hashes 相同；不得宣稱跨不同 upstream release 的 closure digest 相同。
- 以完整 519-test segment 612.082 秒估算，合計仍約 1247.609 秒，未啟動正式驗收。此已證實收益的循序候選固定保留，再按 HTTPS 實測 profile 處理下一個單一 acquisition 根因。
- 組合同主機循序 HTTPS reuse 後：acquisition 241.986 秒；同 canonical authority development gate 289/289 與完整 resolver 52/52 通過，0 failed/skipped/pending。consumer preflight／正式驗收由合併後 immutable authority pin 另行執行。
