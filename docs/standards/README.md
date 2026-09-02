# Agent Skill Standards

本目錄是 `SyuanTsai-AI-Instructions` 對 Agent Skill repository、package、validation、security 與 lifecycle 的唯一 normative source of truth。

## Current version

- Standard version: **v1**
- Authority: `docs/standards/skill-repository-standard.md`
- Cross-repository evidence: `docs/standards/skill-repository-review-matrix.md`
- Validation tool policy: `docs/standards/validation-toolchain.json`
- Validation tool resolver: `scripts/Resolve-StandardValidationTool.ps1`
- Core authority regression: `tests/skill-repository-standard.Tests.ps1`
- Workflow authority regression: `tests/skill-repository-workflows.Tests.ps1`
- Resolver hardening regression: `tests/standard-validation-resolver-hardening.Tests.ps1`
- Tracking: Jira `SYP-167`

## Scope

Standard v1 適用於由 SyuanTsai 維護、可被 Agent / Codex / GitHub Copilot 等 host 安裝或執行的 Agent Skill source repositories。

本標準定義：

- canonical source repository contract；
- Skill package 與 `agents/openai.yaml` metadata contract；
- source inventory、pin、provenance 與 integrity contract；
- canonical validation / security lifecycle；
- local / pre-push / CI 共用 validation contract；
- trusted-source / trusted-endpoint + latest-stable validation tool policy；
- immutable workflow-action pin、checkout credential isolation、authority trigger 與 event-aware diff contract；
- verification-only tool installation、static installed metadata verification 與 credential boundary；
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
2. `docs/standards/validation-toolchain.json` 是 canonical validation tool selection 的 machine-readable policy；正式 validation 預設每次 run 從 approved source / endpoint 解析 latest stable，並在該 run 內 freeze resolved version。
3. `scripts/Resolve-StandardValidationTool.ps1` 是 tool source / endpoint trust anchor 與 provider-specific resolution authority；workflow 不得另建第二套 acquisition logic。
4. `tests/skill-repository-standard.Tests.ps1`、`tests/skill-repository-workflows.Tests.ps1` 與 `tests/standard-validation-resolver-hardening.Tests.ps1` 共同保護 Standard authority、workflow merge enforcement 與 resolver security boundary；normative、resolver 或 workflow authority change 必須在同一 PR 更新受影響 regression。
5. `.github/workflows/standards-conformance.yml` 是 dedicated authority evidence surface；`.github/workflows/pr8-powershell-validation.yml` 的 Ruleset-required Linux Composition job 是 merge-blocking bridge。兩者必須執行相同 authority regression 與 live resolver receipt checks。
6. `Skill-General` 在 SYP-155 完成後是 reference implementation，但不得反向覆寫或私自擴充 normative policy。
7. `Skill-Knowledge-Content`、`Skill-Code-Collaboration`、`Skill-Darktide-Translate`、`Skill-Atlassian-Ecosystem` 依 SYP-156～159 做 conformance migration。
8. 舊文件若與 Standard v1 衝突，以本目錄為準；歷史文件應保留歷史語意並加上 superseded notice，不得重寫歷史。

## Change rule

任何會改變 MUST / MUST NOT、canonical lifecycle、validation tool source / endpoint / version policy、security gate semantics、metadata contract、integrity contract、approval boundary、workflow authority enforcement 或 exception policy 的變更，必須：

1. 在本目錄修改 normative 文件；
2. **同一 PR** 更新受影響的 authority regression 與 machine-readable policy；
3. tool source / endpoint / resolver behavior 變更時，同一 PR 更新 `scripts/Resolve-StandardValidationTool.ps1` 與負向 regression；
4. workflow action、trigger、credential 或 merge-blocking bridge 變更時，同一 PR 更新 workflow regression，並確認 dedicated／required gate 都會執行；
5. 說明對 reference implementation 與已遷移 repositories 的影響；
6. 執行 authority-level conformance regression；
7. 經 human review 後才可 fan out。

這項 self-conformance rule 從 Standard v1 首次 merge 前即生效，不延後到 SYP-155。

Repository-specific implementation 不得自行建立第二套 lifecycle、security、validation-tool 或 release policy。
