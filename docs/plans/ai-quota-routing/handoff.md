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
2. 每項額度的重置時間不同，不能以平均分配、固定比例或 round-robin 規劃。
3. 任務歸屬使用平台無關的 Git remote identity 判定，不綁定 GitHub 或任何特定 Git 供應商。
4. Remote identity 概念上正規化為 `<host>/<repository-path>`，並以完整 repository、namespace/path 前綴、hostname 的具體程度進行匹配。
5. 無匹配、無 remote、無法安全判定或同級規則衝突時，結果為 `unknown`，不得自行猜測。
6. 真實 hostname、remote URL、namespace、repository、帳號與 quota 映射只能存在本機私有設定；tracked file 只使用保留網域與中性 placeholder。
7. 額度邊界先於 AI 能力與額度最佳化；後兩者不能成為跨越 quota profile 的理由。

## 接手時不要做的事

- 不要開始修改 production code、script、hook、skill 或 installer。
- 不要建立供應商清單或假設一定使用某個 AI CLI。
- 不要設計平均分配或固定輪替演算法。
- 不要將 GitHub organization 規則當成唯一方案。
- 不要要求使用者把真實公司網域、repository 或帳號資訊寫入 Git。
- 不要把尚未確認的提議寫成既定需求。

## 下一步建議

下一輪先繼續確認目標邊界，優先問題是：

> 公司或客戶任務是否也只能使用對應 quota profile，還是目前只有個人任務的額度隔離是硬性限制？

確認後，再依序討論 `unknown`／非 Git 任務、多 Repository 混合任務，以及合法 profile 內的選擇優先順序。

## 文件維護方式

- 每項新決策經使用者確認後，更新 `discussion-record.md` 的已確認決策、概念流程或待討論問題。
- 每次準備結束對話時，更新本文件的目前狀態、必須保留的決策與下一步建議。
- 規劃尚未進入實作前，維持這兩個檔案為唯一新增產物。
