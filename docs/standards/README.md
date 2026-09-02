# Agent Skill Standards

本目錄是 `SyuanTsai-AI-Instructions` 對 Agent Skill repository、package、validation、security 與 lifecycle 的唯一 normative source of truth。

## Current version

- Standard version: **v1**
- Authority: `docs/standards/skill-repository-standard.md`
- Cross-repository evidence: `docs/standards/skill-repository-review-matrix.md`
- Tracking: Jira `SYP-167`

## Scope

Standard v1 適用於由 SyuanTsai 維護、可被 Agent / Codex / GitHub Copilot 等 host 安裝或執行的 Agent Skill source repositories。

本標準定義：

- canonical source repository contract；
- Skill package contract；
- source inventory、pin、provenance 與 integrity contract；
- canonical validation / security lifecycle；
- local / pre-push / CI 共用 validation contract；
- testing、release、publish、install 與 post-install verification；
- SkillSpector Static / Semantic Security Gate；
- AI Review / Human Approval boundary；
- repository-specific extension / adapter / exception policy。

## Normative language

- **MUST / MUST NOT**：conformance 必須遵守，違反即不符合 Standard v1。
- **SHOULD / SHOULD NOT**：預設應遵守；若偏離，必須有具體理由與可追蹤 evidence。
- **MAY**：允許的 extension，不影響基礎 conformance。

## Authority and precedence

1. `docs/standards/skill-repository-standard.md` 是 normative authority。
2. `Skill-General` 在 SYP-155 完成後是 reference implementation，但不得反向覆寫或私自擴充 normative policy。
3. `Skill-Knowledge-Content`、`Skill-Code-Collaboration`、`Skill-Darktide-Translate`、`Skill-Atlassian-Ecosystem` 依 SYP-156～159 做 conformance migration。
4. 舊文件若與 Standard v1 衝突，以本目錄為準；歷史文件應保留歷史語意並加上 superseded notice，不得重寫歷史。

## Change rule

任何會改變 MUST / MUST NOT、canonical lifecycle、security gate semantics、integrity contract 或 exception policy 的變更，必須：

1. 在本目錄修改 normative 文件；
2. 更新 conformance / regression tests；
3. 說明對 reference implementation 與已遷移 repositories 的影響；
4. 經 human review 後才可 fan out。

Repository-specific implementation 不得自行建立第二套 lifecycle、security policy 或 release policy。
