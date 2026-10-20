# 計畫：循序 acquisition 重用同主機 HTTPS 連線

- 證據：未修改的 helper profile 為 133.151 秒，132 次 HTTPS open 中 TCP connect 28.968 秒、TLS handshake 19.839 秒；圖重建不是關鍵成本。
- 範圍：同一 catalog、同一 approved host 的循序 HTTPS GET 可重用前次已完整讀完的連線；每個 opener 最多保留一個連線。沿用 urllib redirect/error processing，絕不新增執行緒、下載並行或改 scheduler。
- 安全契約：每次 request 與每個 redirect 都先驗證 HTTPS、host、port、credentials、query/fragment。保留系統憑證與 hostname 驗證。只有 content-length 明確歸零、非 will-close 且仍存活的連線可重用；中止、未知長度、換 host 或 transport error 關閉後重建；每次重設剩餘 timeout。既有 bytes/deadline/retry/hash/metadata/offline pip 檢查不變。
- Red／Green：先加入離線真實 HTTPResponse fixture，覆蓋完整讀取後重用、未讀完重建、timeout 更新、換 host、連線失敗清理及 redirect 在接觸不允許主機前拒絕。舊版缺少 API 應 Red，最小 handler 使 Green，再跑完整 helper 與相關 resolver suites。
- 驗收：診斷 profile 只證明根因；必須以全新四工具 acquisition 分段證明收益，並支持完整 preflight 與 immutable 正式 Stages 1–5 <=1200 秒。三個 authority suites 與同 authority gate 必須通過，再循既有授權完成中央與 consumer Git／PR／CI／review／normal merge。
- 回復：若連線相容性或分段收益不成立，只還原本次循序 transport 候選，保留已獨立驗證的 hashing 與候選排序基線。安全失敗直接 fail closed，不透明重試模糊的 response。

## Red／Green

- 最小 fixture 在 production API 缺失時得到 NameError Red；實作後，同主機完整 response 重用與 timeout 更新、未完整讀取／未知長度／server-close／換 host 重建、失敗關閉且不額外重試、redirect 在接觸未允許主機前拒絕等行為通過。
- 完整既有 helper self-test 發現 offline LocalCatalog 缺少新增 cleanup interface；補上不持有網路資源的 no-op close 後，完整 helper self-test 通過。所有原有 backtracking、budget、artifact retry、metadata、direct-reference 及 evidence regressions 仍執行。
- 真實全新四工具 acquisition：241.986 秒，exit 0、4 份同 run receipts、stderr 空白；相對前一個已驗證循序候選 327.651 秒再減少 85.665 秒。以完整 519-test segment 612.082 秒與既有其他階段 307.876 秒估算，約 1161.944 秒，支持進入完整 authority gate、中央 rollout 與 consumer preflight／正式驗收，估算本身不等於正式通過。
- transport 前後皆 3 pip rounds、68 candidates、66 selected wheels；全部 selected versions／SHA-256 及 selected closure digest 相同，helper selection verified 47.339 秒。
- 組合 correctness 完整通過：canonical authority development gate 289/289（2488.679 秒）、完整 resolver 52/52（154.301 秒），0 failed/skipped/pending。所有變更的 PowerShell／Python parse 與 git diff --check 通過。接續以中央 exact head 的 CI、code/security review 與 normal merge 發布，再由 consumer exact repin 執行完整 preflight 與 immutable 正式 Stages 1–5；後者仍須 <=1200 秒。
