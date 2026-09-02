# Agent Skill Standards

本目錄是 `SyuanTsai-AI-Instructions` 對 Agent Skill repository、package、validation、security 與 lifecycle 的唯一 normative source of truth。

## Current version

- Standard version: **v1**
- Authority: `docs/standards/skill-repository-standard.md`
- Cross-repository evidence: `docs/standards/skill-repository-review-matrix.md`
- Validation tool policy: `docs/standards/validation-toolchain.json`
- Authority regression: `tests/skill-repository-standard.Tests.ps1`
- Tracking: Jira `SYP-167`

## Scope

Standard v1 適用於由 SyuanTsai 維護、可被 Agent / Codex / GitHub Copilot 等 host 安裝或執行的 Agent Skill source repositories。

本標準定義：

- canonical source repository contract；
- Skill package 與 `agents/openai.yaml` metadata contract；
- source inventory、pin、provenance 與 integrity contract；
- canonical validation / security lifecycle；
- local / pre-push / CI 共用 validation contract；
- latest-stable validation tool policy；
- testing、release、publish、install 與 post-install verification；
- SkillSpector Static / Semantic Security Gate；
- AI Review / Human Release Approval boundary；
- approved immutable release installation semantics；
- repository-specific extension / adapter / exception policy。

## Normative language

- **MUST / MUST NOT**：conformance 必須遵守，違反即不符合 Standard v1。
- **SHOULD / SHOULD NOT**：預設應遵守；若偏離，必須有具體理由與可追蹤 evidence。
- **MAY**：允許的 extension，不影響基礎 conformance。

## Authority and precedence

1. `docs/standards/skill-repository-standard.md` 是 normative authority。
2. `docs/standards/validation-toolchain.json` 是 canonical validation tool selection 的 machine-readable policy；正式 validation 預設每次 run 解析 latest stable，並在該 run 內 freeze resolved version。
3. `tests/skill-repository-standard.Tests.ps1` 保護 Standard authority 自身的核心 contract，Standard 的 normative change 必須在同一 PR 更新相關 regression。
4. `Skill-General` 在 SYP-155 完成後是 reference implementation，但不得反向覆寫或私自擴充 normative policy。
5. `Skill-Knowledge-Content`、`Skill-Code-Collaboration`、`Skill-Darktide-Translate`、`Skill-Atlassian-Ecosystem` 依 SYP-156～159 做 conformance migration。
6. 舊文件若與 Standard v1 衝突，以本目錄為準；歷史文件應保留歷史語意並加上 superseded notice，不得重寫歷史。

## Change rule

任何會改變 MUST / MUST NOT、canonical lifecycle、validation tool policy、security gate semantics、metadata contract、integrity contract、approval boundary 或 exception policy 的變更，必須：

1. 在本目錄修改 normative 文件；
2. **同一 PR** 更新 `tests/skill-repository-standard.Tests.ps1` 與受影響的 machine-readable policy；
3. 說明對 reference implementation 與已遷移 repositories 的影響；
4. 執行 authority-level conformance regression；
5. 經 human review 後才可 fan out。

這項 self-conformance rule 從 Standard v1 首次 merge 前即生效，不延後到 SYP-155。

Repository-specific implementation 不得自行建立第二套 lifecycle、security、validation-tool 或 release policy。
