# AI 額度自主路由：討論與決策紀錄

## 文件定位

- 狀態：目標探索中，尚未進入實作規劃。
- 工作分支：`codex/plan-ai-quota-routing`。
- 用途：保存已確認的目標、限制、理由與未決問題，作為後續討論的主要依據。
- 更新原則：只有經使用者確認的內容才能列為「已確認決策」；尚未確認的內容應保留在「待討論問題」。

## 1. 問題背景

在分析問題或進行功能修改時，使用者不希望每次都手動選擇要由哪一個 AI 執行，也不希望所有工作固定消耗同一個 AI 或帳號的額度。

這個需求的核心不是平均分配額度，而是讓 Agent 在合法的額度範圍內，依任務需求與各額度的實際狀態自主選擇 AI。

## 2. 目前目標

當使用者提出問題分析或功能修改任務時，Agent 應先判定任務所屬的 quota profile，將可使用的 AI 額度限制在該 profile 內，再依任務所需能力、剩餘額度與個別重置時間，自主選擇合適的 AI 執行來源。

正常情況下，使用者不需要逐次指定 AI、模型、帳號或額度來源；無法安全判定或沒有合適額度時，Agent 不應自行跨越額度邊界。

## 3. 已確認決策

### 3.1 個人任務只能使用個人額度

- 明確屬於個人的任務，只能消耗個人 quota profile 中的額度。
- 即使其他 profile 的額度充足，也不得自動拿來執行個人任務。
- 個人額度不足時，可在個人 profile 內改選其他合適 AI；不得自動切換至公司或其他非個人額度。

### 3.2 額度不能以平均方式規劃

- 不同 AI 或帳號的額度重置時間不盡相同，每項額度必須獨立看待。
- 不以平均分配、固定比例、round-robin 或「目前剩餘最多」作為單一選擇原則。
- 在合法的 quota profile 內，選擇應同時考慮任務所需能力、剩餘額度及距離重置的時間。
- 同一類任務在不同時間執行，合理結果可能是選擇不同 AI。

### 3.3 使用平台無關的 Git remote identity 分類

- 任務歸屬的主要判定依據是目前 Git Repository 的 remote identity，不綁定 GitHub、GitLab、Bitbucket、Azure DevOps、Gitea 或其他特定供應商。
- HTTPS、SSH、`ssh://` 與 SCP-like remote URL 應先正規化為概念上的 `<host>/<repository-path>`，再進行規則匹配。
- 不依賴供應商專屬 API，也不從 repository 內容推測任務歸屬。
- 規則依下列具體程度判定：
  1. 完整 repository identity。
  2. Namespace 或 repository path 前綴。
  3. 完整 hostname。
  4. 無匹配時為 `unknown`。
- 同等具體程度的規則若互相衝突，結果為 `unknown`，不得自行猜測。
- 預設使用 `origin` 作為 authoritative remote；fork 或其他工作流程可透過本機設定指定 `upstream` 或其他 remote。
- 本機路徑或 `file://` remote 若沒有明確本機規則，結果為 `unknown`。
- 分類結果為 quota profile，而不是寫死為 Git 供應商或固定的 personal/company 二元值；初期可以只有 `personal` 與 `company`，未來可增加其他組織或客戶 profile。

### 3.4 真實識別資訊不得進入 Git

- 真實 Git hostname、remote URL、namespace、repository、帳號、quota profile 映射與額度重置資訊，只能保存在 `~/.codex/`、環境變數或其他未受 Repository 追蹤的個人設定中。
- 受版本控制的 schema、文件、範例與測試資料只使用 `example.com`、`example.org`、`example.test` 與中性 placeholder。
- Remote URL 中若包含 username、token 或其他 credential，必須在比對、診斷與輸出前移除，不得記錄或顯示。
- 功能不得要求將真實公司或個人識別資訊寫入 tracked file，才能完成分類。

## 4. 目前概念流程

```text
Git remote identity
→ quota profile
→ 該 profile 允許使用的 AI 額度池
→ 任務所需能力
→ 各額度的剩餘量與重置時間
→ 選擇 AI 執行來源
```

這個順序表示額度邊界必須先於最佳化決策建立。能力或額度狀態不能成為跨越 profile 邊界的理由。

## 5. 目前階段的非目標

- 尚不決定 CLI、背景服務、hook、skill、設定檔或其他實作形式。
- 尚不決定支援哪些 AI 供應商、模型或帳號。
- 尚不定義如何取得、快取或更新剩餘額度與重置時間。
- 尚不設計具體的 AI 選擇演算法、權重或評分公式。
- 尚不開始撰寫 production code、安裝腳本或測試。

## 6. 待討論問題

1. 公司或客戶任務是否也只能使用對應的非個人 quota profile，或目前只有「個人任務不得使用公司額度」這一側是硬性限制？
2. 不在 Git Repository 中、沒有 remote 或判定為 `unknown` 的任務，是否一律先詢問使用者？
3. 同一任務同時涉及不同 quota profile 的多個 Repository 時，應拆分任務、採最嚴格邊界，還是必須詢問使用者？
4. 在合法 profile 內選擇 AI 時，任務成功率、能力適配、剩餘額度、重置時間與預期消耗量之間的目標優先順序為何？
5. 當首選 AI 無法執行或額度不足時，允許 Agent 在同一 profile 內自動切換到什麼程度？
6. 使用者是否需要看到每次選擇所依據的 profile、額度狀態與簡短理由？

## 7. 安全範例

以下只表示規則概念，不是已決定的設定格式：

```text
git.example.com/example-user/**
→ personal

git.example.org/example-organization/**
→ company

code.example.test/**
→ example-customer
```

## 8. 更新紀錄

- 2026-08-08：建立初始紀錄；確認個人額度隔離、非平均額度規劃、平台無關 Git remote identity，以及真實映射不得進入 Git。
