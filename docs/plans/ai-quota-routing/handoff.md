# AI 額度自主路由：AI 交班文件

## 接手任務

請接續規劃「AI 額度自主路由」。目前只討論目標、硬性邊界、成功條件與未決問題，不得開始功能實作或提前決定技術架構。

開始前先完整閱讀 [discussion-record.md](./discussion-record.md)，並以該文件的「已確認決策」為準。不要因新對話缺少先前聊天內容而重新推翻已確認決策；若發現衝突，應指出衝突並向使用者確認。

## 目前狀態

- 工作分支：`codex/plan-ai-quota-routing`。
- 階段：目標探索。
- 已建立 production code：否。
- 已決定實作形式：否。
- 主要紀錄：[discussion-record.md](./discussion-record.md)。

## 必須保留的已確認決策

1. 明確的個人任務只能使用個人 quota profile，不得因其他額度充足而跨 profile。
2. 每項額度的重置時間可能不同；未來決策需要理解各自的可用週期，但目前尚未決定如何分配或使用 AI。
3. 任務歸屬使用平台無關的 Git Repository 來源資訊判定，不綁定 GitHub 或任何特定 Git 供應商。
4. 無法確認任務歸屬時，不得自行跨越 quota profile；remote 的解析、匹配與衝突處理尚未決定。
5. 真實 Git 來源、帳號與 quota 映射只能存在本機私有設定；tracked file 只保存通用規則與去識別化範例。
6. 額度邊界先於 AI 能力與額度最佳化；後兩者不能成為跨越 quota profile 的理由。
7. 每個 AI 都必須具備獨立設定預留額度的能力，而不是只有特定 AI 才支援；個人 Copilot Review 是目前已知的保障用途之一。
8. 預留額度如何影響 AI 選擇尚未決定；其表示方式、約束強度與人工覆寫規則也尚未決定。

## 接手時不要做的事

- 不要開始修改 production code、script、hook、skill 或 installer。
- 不要建立供應商清單或假設一定使用某個 AI CLI。
- 不要把平均分配、固定比例、輪替或任何其他 AI 使用策略寫成已確認需求。
- 不要將 GitHub organization 規則當成唯一方案。
- 不要提前決定 Git remote 的正規化格式、匹配優先序或 authoritative remote。
- 不要提前決定預留額度的數值、比例或設定格式。
- 不要要求使用者把真實公司網域、repository 或帳號資訊寫入 Git。
- 不要把尚未確認的提議寫成既定需求。

## 下一步建議

下一輪先繼續確認目標邊界，優先問題是：

> 每個 AI 的預留額度應以 AI、帳號、額度來源或 quota profile 中的哪一層為獨立設定邊界？

確認後，再依序討論公司／客戶 profile 邊界、`unknown`／非 Git 任務與多 Repository 混合任務；如何分配或使用 AI 留待目標邊界完整後再討論。

## 文件維護方式

- 每項新決策經使用者確認後，更新 `discussion-record.md` 的已確認決策、概念流程或待討論問題。
- 每次準備結束對話時，更新本文件的目前狀態、必須保留的決策與下一步建議。
- 規劃尚未進入實作前，維持這兩個檔案為唯一新增產物。
