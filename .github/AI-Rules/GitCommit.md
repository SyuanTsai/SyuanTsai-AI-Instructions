# Git Commit 產生規範

只有在產生 Git Commit Message 時，才套用本規範。只輸出最終 Commit Message，不得輸出說明、分析過程、驗證結果或 Markdown code fence。

## 目標

根據 staged changes 產生正確、聚焦且可供核對的 Commit Message：

- 第一行符合公司規定的 Jira Smart Commit 格式。
- 英文 Commit 內容採用 Conventional Commit 的 type、scope 與 description 結構。
- 提供忠實對應的台灣繁體中文翻譯，供使用者確認英文內容。
- 只描述 branch name 與 staged changes 能夠支持的資訊。
- 不得臆測 Jira ticket、工作時間、修改目的、系統行為或實作細節。

## 資訊來源

只能使用 staged changes，以及 request context 確實提供的目前 branch name。不得將 `$GIT_BRANCH_NAME` 當成實際 branch name，也不得假設 Copilot 一定能取得 branch name。

從 branch name 擷取符合 `[A-Z]{2,}-[0-9]+` 的 Jira ticket。例如：

```text
origin/feature/PROJ-11805-asset-class-import-by-asset-external-ID
```

應擷取 `PROJ-11805`。如果 branch name 未提供或沒有有效 ticket，第一行使用 `PROJECT-XXXX` 作為明確佔位符，不得猜測或建立 ticket；使用者必須在 Commit 前手動確認並替換。

## Commit Message 格式

```text
<ticket 或 PROJECT-XXXX>, #time XXm

<type>[optional scope][optional !]: <英文描述>

[optional 英文 body]

zh-TW:
<Commit type 的繁體中文含義>[相同的 optional scope]：<繁體中文描述>

[optional 繁體中文 body]

[optional machine-readable footer(s)]
```

例如：

```text
PROJ-11805, #time XXm

fix(import): handle missing external asset IDs

Prevent records without an external asset ID from failing the entire import.

zh-TW:
修正(import)：處理缺少的外部資產 ID

避免缺少外部資產 ID 的資料導致整批匯入失敗。
```

## Jira Ticket 與工作時間

- 第一行固定使用 `<ticket>, #time XXm`。
- 使用 branch name 中實際存在的 Jira ticket；ticket 只能出現在第一行，不得在中文內容或 footer 重複。
- `XXm` 必須原樣保留，供使用者手動輸入工作時間。
- 不得依 staged changes 的大小或複雜度估算時間，也不得自行替換 `XXm`。
- 使用者必須在 Commit 前將 `XXm` 改為實際時間，例如 `30m` 或 `1h`。

## 產生流程

1. 檢查 staged changes。
2. 當 request context 有 branch name 時，從中擷取 Jira ticket。
3. 判斷 staged changes 的主要目的，選擇最能代表該目的的一個 Commit type。
4. 產生英文 description，必要時加入英文 body。
5. 將英文內容忠實翻譯為台灣繁體中文。
6. 確認中英文表達相同事實並驗證結構後，只輸出 Commit Message。

當 staged changes 包含多個獨立目的時，只描述主要目的；不得在 Commit Message 中輸出拆分建議。

## Commit Type 選擇

每個 Commit 只選擇一個主要 type：

- `feat`：新增功能或使用者可觀察的新能力。
- `fix`：修正既有的不正確行為。
- `refactor`：調整內部結構，但不改變預期外部行為。
- `perf`：改善效能，同時維持預期行為。
- `test`：只新增或更新測試。
- `docs`：只修改文件。
- `style`：只修改格式，不影響程式行為。
- `build`：修改建置系統或外部相依套件。
- `ci`：修改 CI/CD 或部署設定。
- `chore`：不屬於其他明確類型的維護工作。
- `revert`：還原先前的 Commit。

依 staged changes 的主要目的選擇 type，不得只根據檔名判斷。Production code 修正錯誤並更新測試時通常使用 `fix`；新增功能與測試時通常使用 `feat`；只有測試變更時才優先使用 `test`。

## Scope 與英文內容

- 只有在 staged changes 能清楚識別 component、module、service 或 subsystem 時才加入簡短且穩定的 scope。
- 中英文使用完全相同的 scope，且不得翻譯 scope；無法準確判斷時省略。
- 英文 description 使用 imperative form，描述完成的行為或結果，不列出修改檔案。
- 避免 `update code`、`fix issue` 或 `make changes` 等模糊描述。
- 只有在能實質說明動機、重要行為、前後差異、限制或不明顯決定時才加入 body。
- 所有敘述都必須由 staged changes 支持；無法確認時省略 body，不得推測。

## 台灣繁體中文翻譯

繁體中文區段以 `zh-TW:` 開始，且只能是英文 Commit 內容的忠實翻譯，不是另一次獨立摘要：

- 中英文描述完全相同的事實，不得新增、刪除、擴大或重新解釋內容。
- 英文的每項行為描述都必須有對應翻譯；中文不得加入英文沒有的目的、原因或影響。
- 翻譯 Commit type 的語意，例如將 `fix` 翻譯為「修正」，但保留相同 scope。
- 保留 class、method、property、API、Jira ticket、程式碼符號及翻譯後會降低精確度的技術詞彙。
- 不得在中文區段重複 Jira ticket 與工作時間。

## Footer 與 Breaking Changes

Machine-readable footers 必須位於整個 Commit Message 最後。不得翻譯 `BREAKING CHANGE`、`Reviewed-by`、`Refs` 等 footer token；需要中文說明時，放在 `zh-TW:` 區段。

不相容的 API 或行為變更使用 `!`，或加入：

```text
BREAKING CHANGE: <English description>
```

`BREAKING CHANGE` 必須保持大寫。不得以 `Refs` footer 重複第一行已有的 Jira ticket。

## 最終驗證

輸出前確認：

- 第一行符合 `<ticket>, #time XXm`，ticket 來自實際提供的 branch name，否則使用 `PROJECT-XXXX`。
- `XXm` 保留供人工輸入，沒有推測 ticket 或工作時間。
- 只選擇一個主要 type，且 description、scope 與 optional body 都由 staged changes 支持。
- 中英文內容表達相同事實，中文沒有額外資訊。
- Breaking Change 已明確標示，machine-readable footers 位於最後。
- 最終輸出沒有說明、分析、建議、驗證清單或 Markdown code fence。
