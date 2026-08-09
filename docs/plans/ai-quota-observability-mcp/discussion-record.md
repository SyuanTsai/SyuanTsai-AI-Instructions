# AI 額度觀測與獨立 PowerShell 指令討論紀錄

## 文件定位

- 狀態：已從「Codex 自主派工與 AI 額度路由」拆出，並確認目前以獨立 PowerShell（`pwsh`）指令為目標產物；仍在收斂使用者可見行為，尚未進入實作規劃。
- 工作分支：`codex/plan-ai-quota-observability-mcp`。
- 用途：規劃如何以獨立本機 PowerShell 指令，安全取得各 AI 額度來源的剩餘量、重置時間與可信度，供使用者或 Codex 按需呼叫。
- 上游規劃：`docs/plans/ai-quota-routing/` 只使用額度觀測結果進行資格判斷與派工，不在該規劃實作資料取得。
- 更新原則：只有經使用者確認的內容列為「已確認決策」；評估結論與建議在確認前保留為候選方向。

## 1. 問題與目標

Codex 在 Task Execution 準備派工時，需要知道使用者已加入的 AI 額度來源目前是否可用、剩餘多少、何時重置，以及資訊是否足以支持「不侵入預留額度」的判斷。

本規劃的目標不是替 Codex 選擇 AI，而是提供範圍清楚、可追溯且安全的額度觀測。Codex 仍負責 task profile、必要能力、預留額度、重置急迫性、成功率、切換成本與最終派工決策。

預期涵蓋的第一批來源包括：

- 當前 Codex 與未來由使用者加入的其他 Codex 額度來源。
- GitHub Copilot 公司與私人額度來源。
- JetBrains AI／Junie 私人額度來源。
- Google Antigravity 私人額度來源。
- 後續由使用者加入且能以合法、可信方式取得狀態的其他 AI 額度來源。

## 2. 與自主派工規劃的責任邊界

```text
AI 供應商官方狀態、API、CLI 或使用者輸入
                    ↓
       額度觀測與可信度判定
                    ↓
          提供標準化額度狀態
                    ↓
 Codex 套用 task profile、能力、預留與派工規則
```

本規劃負責：

- 確認各額度來源能取得哪些資料，以及資料的合法性、即時性與可信度。
- 定義來源不可用、資訊過期、互相衝突或只能估算時的可見狀態。
- 定義獨立 PowerShell 指令的使用者可見行為與完成條件。
- 在使用者加入新來源時，依實際驗證路徑判斷是否需要隔離登入內容，並在需要時引導完成一次性的官方登入與來源確認。
- 限制憑證、帳號識別、紀錄與輸出的安全範圍。

本規劃不負責：

- 判斷任務屬於公司或私人 task profile。
- 設定或修改使用者的預留額度。
- 選擇 AI、模型、模式或實際額度來源。
- 改變供應商 CLI 的全域 active account、執行 AI 任務、重試派工或驗收結果；登入隔離只選擇已建立的來源內容，不執行背景 `/user switch`。
- 展開自主派工流程、Worker 或完整 AI Router 的實作。

## 3. 已確認的上游約束

- Codex App 是主控；額度觀測只提供資訊，不取代 Codex 的派工判斷。
- AI 資源由使用者加入後才納入可派工範圍；同一 AI／模型可因帳號或共享額度來源不同而有多個選項。
- 多個模型或執行模式若共用同一額度來源，不能被誤判為各自擁有完整額度。
- 任何自主派工不得侵入使用者為該共享額度來源保留的預留額度。
- 真實帳號、Token、email、organization 或其他非必要識別資訊不得寫入受版本控制文件或一般派工輸出。
- 額度觀測結果是派工輸入；task profile、能力、偏好與路由規則仍保存在 Codex 的規劃範圍，不屬於外部工具。

## 4. 現有工具評估

### 4.1 caut

目前不建議採用 `coding_agent_usage_tracker` 作為額度來源。原始碼與最新 CI 稽核發現：

- 公開說明列出多個供應商，但實際抓取流程主要只有 Claude 與 Codex；Copilot、Antigravity 等選項沒有完整 fetch plan。
- Codex provider 沒有可靠的官方額度查詢，部分路徑只回傳帳號身分而沒有 quota。
- 多帳號參數沒有完整接入實際抓取流程。
- Token account 可序列化至本機明文檔案，且使用紀錄會保存 email／organization 等資訊。
- 稽核時目前 commit 的安全 CI 因 RustSec high-severity 相依套件弱點失敗，Windows CI 也因 SQLite linker 問題失敗。
- Repository 使用帶有限制性 rider 的非標準 MIT 條款，對 Codex 整合存在需法律確認的授權風險。

因此先前僅依 README 得出的「高度符合需求」判斷已撤回。未來若重新評估，必須以固定 commit、通過的安全與 Windows CI、實際 provider 覆蓋及可接受授權為前提。

### 4.2 現有 MCP 與社群工具

- GitHub 官方 MCP Server 可操作 GitHub 與 Copilot coding agent，但目前公開工具清單未提供個人／組織 AI credit 額度查詢。
- Google Cloud Quotas MCP 查詢的是 Google Cloud 專案與服務 quota，不是 Antigravity 個人訂閱的 agent quota。
- `opencode-quotas` 可顯示 Antigravity 與 Codex quota，但它是 OpenCode plugin／CLI，不是可直接採用的通用 MCP，且 Copilot 支援仍標為 experimental。
- Antigravity Storage Manager 雖提供 `get_quota` MCP tool，但同時包含 AI proxy、chat completion、Google Drive、Telegram、帳號切換與同步等超出需求的能力；其額度工具也未完整涵蓋 Copilot，不適合直接授予目前規劃所需的最小權限。
- Agent delegation 類 MCP 可以呼叫 Codex、Copilot 或 Antigravity 執行任務，但它們解決的是派工執行，不是可信額度觀測，且通常具有檔案、命令與網路權限。

目前沒有找到一個安全、成熟且同時覆蓋 Codex、Copilot 公司／私人與 Antigravity 多額度來源的現成 MCP。

## 5. 已確認的官方資料能力

### GitHub Copilot

GitHub 官方 REST Billing API 已提供個人與 organization／enterprise 的 AI credit 或 premium request usage 報告：

- 個人來源需要對應使用者及 `Plan: read` 權限。
- 公司來源需要 organization／enterprise 管理或 billing 權限。
- 個人自行購買的 Copilot 與由公司管理、計費的 Copilot 必須查詢不同層級，不能合併成同一份個人額度。

已針對使用者目前的舊制個人 Copilot Pro 完成唯讀實測並確認：

- PowerShell 可沿用 GitHub CLI 保存的登入憑證，呼叫個人 `premium_request/usage` 專用端點；不得輸出登入帳號、Token、Repository 或完整帳務內容。
- 專用端點與通用個人 Billing Usage 端點在同一月份分別回傳不同分組筆數，但彙總後的 Premium Request 使用量一致，因此第一版以語意明確的專用端點為主要來源，通用端點只作相容性或人工交叉比對。
- 目前帳號的計量制度是舊制 `premium-requests`；使用量以所有共用該額度的相關 SKU 彙總，不得替不同模型或功能複製完整額度。
- GitHub API 回傳實際使用與折抵資料，但不直接回傳個人方案額度。首次查詢且本機沒有設定時，由使用者確認方案；目前已確認為舊制 Copilot Pro，每月 300 Premium Requests，並以 `user-confirmed` 標示額度來源。
- 指令由官方使用量與使用者確認的月額度推導剩餘量、已用／剩餘百分比；重置時間依官方規則推導為每月 1 日 `00:00 UTC`。推導欄位必須與官方回傳欄位區分。
- 若 API 改回傳 `ai-credits`、查詢所用帳號改變或使用者變更方案，舊制本機設定立即失效並重新詢問，不得沿用每月 300 Requests 的假設。

已針對使用者目前由公司管理的 Copilot Business 登入完成唯讀實測並確認：

- Copilot CLI `1.0.78` 的互動式 `/usage` 可顯示方案 AIC 總量、已用量與百分比，但第一版不解析其終端畫面。
- Copilot CLI 的 headless JSON-RPC 可先用 `account.getCurrentAuth` 確認目前有效登入是否對應本機設定的公司資源，再用 `account.getQuota` 取得結構化 `quotaSnapshots`；驗證過程不送出模型提示，也沒有消耗 AI Units。
- 實測 `premium_interactions` 回傳的方案總量、已用量與剩餘百分比，均與同時間互動式 `/usage` 顯示的 AIC 總量、用量及百分比一致。`chat` 與 `completions` 是其他 entitlement，不得併入或複製為 AIC 額度。
- 回傳的 plan 與 access SKU 可用來驗證這是公司管理的 Business 額度來源；真實 login、organization、email、Token 與完整 auth payload 只可在 process 內完成比對，不得寫入一般輸出、紀錄或 Repository。
- ACP 模式雖 advertise `usage`，但本機實測只收到 Session Usage，沒有收到互動式畫面中的 Plan quota；ACP 也未 advertise `user`，因此不得用 ACP prompt 嘗試 `/user show` 或 `/user switch`。公司額度第一版以 headless JSON-RPC 的結構化 quota 方法為主要來源。
- `account.getQuota` 與相關 account 方法在目前 CLI schema 中仍標示為 experimental，必須做 CLI 版本、方法與回應 schema 檢查。實測 `resetDate` 尚未證明代表方案實際重置時間，因此第一版不得用它做接近重置排序，應回報未驗證或未知。
- 已實測 `COPILOT_HOME` 可隔離 Copilot CLI 的設定與登入選擇：預設內容解析為公司 Business，暫存隔離內容解析為 `gh` 的個人 Individual，完成隔離查詢後預設內容仍維持 Business。這證明 Codex 可藉由選擇登入內容查詢多個來源，不需要也不得自動操作 `/user switch`。

官方參考：<https://docs.github.com/en/rest/billing/usage>

官方 Copilot SDK headless 參考：<https://docs.github.com/en/copilot/how-tos/copilot-sdk/setup/backend-services>

### Codex

OpenAI 官方提供 Codex usage dashboard；活動中的 Codex CLI 對話可使用 `/status` 查看目前執行環境與剩餘限制，`/usage` 可查看使用量歷史。這兩個互動式畫面只作為使用者檢視與人工比對，不作為自動化解析來源。

已在本機 Codex CLI `0.147.0` 驗證其 app-server 提供結構化唯讀方法：

- `account/rateLimits/read`：取得目前有效登入狀態的限制窗口、已使用百分比與重置時間，並可表達同一帳號下的多個計量限制。
- `account/usage/read`：取得每日 Token 使用量及 lifetime、peak、streak 等摘要。
- `account/rateLimits/updated`：接收限制狀態更新通知。

上述方法也存在於未開啟 `--experimental` 的本機產生協定 schema；實測可在不啟動模型任務的情況下，透過本機 stdio 取得目前有效登入狀態的額度中繼資料。因此 Codex 第一版不需要解析終端畫面，也不需要先依賴第三方 quota tracker。

但 `codex app-server` 命令本身仍標示為 experimental，且目前只證明「單一目前登入內容」可查詢，尚未證明跨版本相容性或多個 Codex 登入內容的安全隔離方式。後續應以版本相容檢查與方法偵測保守使用，不能把目前協定視為永久穩定的公開 API。

app-server 另有會消耗 usage limit reset credit 的寫入方法；這類操作不屬於額度觀測，第一版必須排除。查詢結果也不得保存或回傳 email、session、Token 或其他不必要的帳號識別資訊。

官方 dashboard：<https://chatgpt.com/codex/settings/usage>

官方 CLI 指令參考：<https://learn.chatgpt.com/docs/developer-commands?surface=cli>

### Antigravity

Google 官方文件說明 baseline quota、五小時或每週重置行為，並表示可在設定頁查看跨模型使用狀態。Antigravity CLI 也具有 Models & Quota 使用者介面；目前尚未確認公開且穩定的跨帳號 quota API 或 MCP。

官方參考：<https://antigravity.google/docs/plans?app=antigravity>

### JetBrains AI／Junie

已確認使用者本機存在 Junie CLI，且人工執行互動式 `/usage` 可在不產生模型 Token 使用量的工作階段中顯示目前 JetBrains AI license 與剩餘 AI Credits；IDE 的 JetBrains AI Widget 可另外顯示方案月額度、剩餘量、重置時間與 Top-up Credits。

目前邊界如下：

- Junie 使用 JetBrains 帳號提供的模型時，消耗的是 Junie、AI Assistant 與其他適用 JetBrains AI 功能共用的個人 AI Credits，不是各 Junie 模型獨立擁有額度。
- 使用 BYOK 模型時不消耗 JetBrains AI Credits，額度應歸屬底層模型供應商，不得同時計入 Junie 額度來源。
- 本機已驗證 Junie CLI 可從使用者 PATH 找到；先前只用目前 Codex process 的 `Get-Command` 得出「未安裝」是環境 PATH 差異造成的誤判，該結論已撤回。
- 官方 CLI 參數目前未提供獨立的 quota JSON 指令，但本機套件已確認 `usage` 同時是 ACP Available Command。PowerShell 可啟動 `junie --acp true`，依序完成 `initialize`、`session/new` 與 `session/prompt("/usage")`，從 stdio JSON-RPC 的 agent message 取得 license、剩餘 balance 與 Session Token 使用量，不需要初始化 TUI 或 pseudo-console。
- 上述 ACP 路徑已在本機 Junie CLI `26.8.3 (2548.5)` 實測成功；回傳餘額與 IDE Widget／人工 `/usage` 顯示一致，且新 Session 的總 Token 使用量為零，因此額度觀測本身不啟動模型任務。
- ACP `/usage` 的 quota 內容仍是協定內的 Markdown 訊息，而不是獨立 quota schema。第一版採用此路徑時，必須檢查 CLI 版本、確認 `usage` command advertisement、嚴格驗證欄位並在格式不符時回報未知，不得退回解析 ANSI TUI 畫面。
- 本機套件另包含 IDE RPC 的 `QuotaInfoResult`，可表達方案名稱、已用／總量／剩餘量與下次補充時間；但這是未公開的 IDE 內部介面，第一版不得直接綁定。獨立 ACP Session 目前只驗證可取得 license 與剩餘 balance，總額度與重置時間仍需另外確認安全來源。
- 不得僅憑方案月額度在本機推算實際餘額，因為同一額度池可能被 IDE 內其他 JetBrains AI 功能消耗；若無法取得即時餘額，必須標示為未知或需要人工更新。

官方參考：<https://junie.jetbrains.com/docs/junie-cli.html>

官方額度說明：<https://www.jetbrains.com/help/ai-assistant/licensing-and-subscriptions.html>

## 6. 已確認方向：獨立 PowerShell 指令

目前已確認：

- 目前目標產物是可由使用者或 Codex 直接執行的獨立本機 PowerShell（`pwsh`）指令，不建立 npm 服務、常駐服務或 MCP Server。
- Codex 第一版直接以本機 app-server 的結構化唯讀方法作為主要資料來源；`/status` 與 `/usage` 只用於人工比對，不解析其視覺輸出。
- PowerShell 指令負責啟動本機 app-server、完成唯讀查詢並輸出額度觀測結果；不自行判斷 task profile、預留額度、派工資格或資源排序。
- 指令執行完成後即結束，不維持背景服務；Codex 需要更新額度時再按需呼叫。
- 指令不保存、輸出或複製供應商 Token；登入與憑證沿用官方 CLI 或其他供應商原生機制。
- 回傳內容使用使用者設定的安全資源名稱，不包含不必要的 email、organization 或真實帳號識別。
- 指令只在 Task Execution 準備派工、使用者明確查詢額度或需要重新整理過期資訊時執行。
- 無法從官方或已核准來源取得的狀態，不得偽裝成精確剩餘額度。

### 6.1 Codex 多額度桶選擇

已確認目前可行方向：

- 同一個 Codex 登入狀態可以透過 `rateLimitsByLimitId` 回傳多個獨立計量額度桶；它們可以分開觀測，但不等於不同帳號或不同訂閱。
- 本機實測目前包含一般 Codex 額度桶 `codex`，以及 `limitName` 為 `GPT-5.3-Codex-Spark` 的額度桶 `codex_bengalfox`；兩者目前的 `planType` 都是 `pro`。
- 指令只呼叫一次 `account/rateLimits/read` 取得完整額度桶集合，再於本機依 `limitId` 精確篩選，不為每個桶重複呼叫供應商介面。
- 未指定 `limitId` 時，回傳目前發現的全部額度桶。
- 指定 `limitId` 時，只回傳相符額度桶。行為可表達為 `Get-AiQuota -Provider Codex -LimitId <id>`；最終安裝方式不影響此選擇契約。
- `limitId` 是精確選擇條件；`limitName` 用於顯示。當 `limitName` 為空時，輸出仍保留原始 `limitId`，不得捏造供應商名稱。
- 找不到指定 `limitId` 時，回傳 `status: not_found`、原始查詢值及當下可用的 `limitId`／`limitName` 清單，並以非成功 exit code 結束。
- 找不到時不得自動退回 `codex`、第一個額度桶或任何其他桶，避免 Codex 使用錯誤的共享額度來源。
- `codex_bengalfox` 類供應商內部識別不得被假設永久不變；指令每次從當下回應探索可用桶，不能將目前實測清單寫死為唯一合法值。

目前確認的單桶回應至少保留 `limitId`、`limitName`、`planType`、`usedPercent`、衍生的 `remainingPercent`、`windowDurationMins` 與 `resetsAt`。其他狀態欄位與輸出格式仍待後續收斂。

### 6.2 Junie 個人額度 ACP 行為

已確認 Junie 個人額度第一版採用 ACP 作為即時觀測來源：

- PowerShell 啟動本機 `junie --acp true`，透過 stdio JSON-RPC 完成 `initialize`、確認 `usage` Available Command、建立新 Session，並以 `session/prompt` 執行 `/usage`。
- 指令只擷取 ACP agent message 中可嚴格驗證的 license、剩餘額度、額度單位與 Session Token 使用量，完成後關閉 Junie process；不啟動互動式 TUI，也不使用 pseudo-console。
- 查詢沿用 Junie 現有的本機登入狀態，不複製、保存或輸出 JetBrains credential 與帳號識別資訊。
- ACP 即時回傳的剩餘額度屬於 Junie 與其他 JetBrains AI 功能共用的 JetBrains AI Credits；不得依模型建立重複額度，也不得把 BYOK 使用量算入此來源。
- ACP 目前沒有提供月總額、已用額度、重置時間或 Top-up Credits 的獨立結構化欄位。第一版對這些欄位回報 `unknown`，不得僅憑方案名稱或本機差額估算成供應商即時資料。
- 因 quota payload 是 ACP 內的 Markdown 訊息，指令必須做 CLI 版本與欄位格式檢查；若 `usage` 未被 advertised、回應格式改變、欄位缺失或 Session 失敗，整筆 Junie 狀態回報未知並附原因，不得自動退回 ANSI TUI 畫面解析。
- 驗收時必須確認新建查詢 Session 沒有產生模型 Token 使用量，且 ACP 餘額與同一時間人工 `/usage` 顯示一致；若任一條件不成立，不得將該版本標示為可靠來源。

### 6.3 Copilot 公司額度行為

已確認 Copilot 公司額度第一版採用目前 Copilot CLI 登入的結構化 quota 作為即時觀測來源：

- PowerShell 啟動本機 Copilot CLI headless JSON-RPC，先確認目前登入符合使用者加入的安全資源名稱，再呼叫 `account.getQuota`。
- 指令只保留 `premium_interactions` 的總量、已用量、剩餘量與百分比，以及必要的 plan／SKU 驗證結果；不得輸出或持久化 auth payload、login、organization、email 或 Token。
- 互動式 `/usage` 只作人工交叉比對，不解析其文字、色彩或進度條。ACP `/usage` 因未穩定回傳 Plan quota，不作主要資料來源。
- 查詢結果必須通過 CLI 版本、方法存在與 quota schema 檢查；不相容時回報未知，不得自動退回畫面解析。
- `resetDate` 在語意完成額外驗證前回報未知；不得以目前觀測值進行重置急迫性排序。
- 多帳號自主查詢採隔離登入內容，不授權指令改變全域登入狀態；各來源的首次官方登入與身分確認依下一節辦理。

### 6.4 Copilot 新來源加入與登入隔離

已確認把 `COPILOT_HOME` 視為 Copilot CLI 額度來源的隔離邊界，而不是交由使用者自行判斷的進階設定。當使用者要求加入新來源時，Codex 必須先辨識該來源的額度驗證路徑，再決定是否啟用隔離：

- 來源需要沿用 Copilot CLI 的 OAuth／Credential Manager 登入，並要成為之後可重複自主查詢或執行的資源時，必須建立該來源專用的 `COPILOT_HOME`。公司 Business 的 `account.getQuota` 屬於此情況。
- 來源只透過 GitHub Billing REST 與 `gh` 查詢舊制個人用量時，額度觀測本身不需要 `COPILOT_HOME`；若同一帳號之後也要成為 Copilot CLI Execution Resource，再另外引導建立隔離內容。
- 使用者只要求一次性檢視目前有效的 Copilot CLI 登入時，可以不建立隔離內容，但該結果不能登記為可供 Codex 長期自主使用的穩定來源。
- 非 Copilot CLI 的供應商或資料路徑不適用 `COPILOT_HOME`；必須使用該供應商自己的隔離方式，不能因為同樣是 AI 額度來源就套用 Copilot 規則。

需要隔離且尚未完成設定時，Codex 自動進入引導流程：

1. 說明為何此來源需要獨立登入內容，以及不會改變既有 Copilot active account。
2. 以使用者提供的安全資源名稱建立本機隔離內容；實際目錄位於個人設定範圍，不得建立在 Repository，也不得把包含使用者路徑的絕對位置寫入一般報告。
3. 透過該隔離內容啟動官方 `copilot login`。Codex 可以啟動與等待流程，但帳號選擇、瀏覽器授權或 device code 確認必須由使用者親自完成，不得代替使用者輸入 credential。
4. 登入後用 `account.getCurrentAuth` 在 process 內驗證預期的 plan、SKU 與不透明帳號指紋，再用 `account.getQuota` 驗證額度可讀；無法從可靠訊號判斷公司／私人來源時，只在第一次詢問使用者並把確認結果保存在本機來源設定。
5. 驗證隔離查詢前後，其他已建立來源與預設 Copilot CLI 的有效登入均未改變。全部成立後才能把來源標記為可自主查詢。

設定完成後，Codex 只需要以安全資源名稱選擇對應的隔離內容，PowerShell 於該 child process 設定 `COPILOT_HOME`、執行唯讀 quota 查詢並關閉 process。它不列出其他帳號、不取得 `account.getAllUsers` 中可能附帶的 Token，也不修改全域 active account。

安全失敗行為已確認如下：

- 隔離內容不存在或尚未登入：回報 `setup_required` 並重新進入引導，不得 fallback 至預設帳號。
- 官方登入已過期：回報 `reauth_required`，由使用者重新完成官方授權。
- plan、SKU 或帳號指紋不符合來源設定：回報 `identity_mismatch`，不得更新綁定或改查另一帳號，必須讓使用者確認。
- Copilot CLI 不支援必要方法或 schema 已改變：回報 `unsupported`／`unknown`，不得退回 `/usage` 畫面解析或 `/user switch`。

目前已完成的隔離驗證為：在同一台 Windows 主機上，預設 Copilot 內容查得 Business，暫存 `COPILOT_HOME` 依官方 auth fallback 查得 Individual，兩者均可取得 `premium_interactions` quota，且隔離查詢沒有改變預設 Business 登入。測試產生的暫存內容未保留。正式實作仍需驗收「公司與私人各自完成一次官方登入的兩個持久隔離內容」，以排除對當下 `gh` active account 的依賴。

MCP 不屬於目前目標；未來只有在獨立指令已穩定，且 Codex 的直接指令呼叫不足以滿足需求時，才另外評估是否包裝成 MCP。

這個方向的價值是讓使用者與 Codex 共用同一個可檢查、可手動執行的本機入口，同時避免常駐服務與額外工具層；代價是仍需持續追蹤各供應商介面變更，且指令本身無法補出供應商未提供的資料。

## 7. 尚未確認，不得提前實作

- 指令最終安裝位置，以及是否提供人類可讀與結構化兩種輸出；`Provider` 與 `LimitId` 的選擇行為已確認。
- Codex app-server 的最低相容版本、執行時方法偵測與版本不相容時的安全 fallback。
- 額度狀態需要哪些最小可見資訊，以及是否顯示百分比、剩餘量、重置時間或原始值。
- 如何區分可靠、估算、過期、未知與來源衝突。
- 來源未知或過期時，是停用自主使用、詢問使用者、接受本機估算，或採其他保守行為。
- 本機紀錄允許保存哪些歷史與校正資訊、保存多久，以及使用者如何清除。
- Copilot 隔離內容的個人設定根目錄、命名與清除行為；隔離判斷、首次引導與安全失敗狀態已確認。
- 指令失敗是否只回報未知，或需要影響後續 Task Execution。
- 具體參數、程序架構、輸出 schema、快取格式、檔案位置與安裝方式。

## 8. 下一個顆粒度

下一階段先定義「額度觀測的使用者可見行為與完成條件」，仍不進入程式架構：

1. 多額度桶的 `Provider`／`LimitId` 選擇行為已確認；下一步收斂完整輸出欄位、格式與 exit code。
2. Codex 已成為第一個驗證來源；下一步確認第一版只讀取目前有效登入狀態，或一開始就涵蓋多個隔離的 Codex 登入狀態。
3. 定義一次額度查詢成功、部分成功、過期與未知時，Codex 應看到什麼結果。
4. 確認額度資訊不足以證明不侵入預留時的安全行為。
5. 確認不保存 Token、最小化帳號識別與本機紀錄的邊界。
