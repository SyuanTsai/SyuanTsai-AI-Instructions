# SYP-167 Cross-Repository Review Matrix

本文件記錄 Standard v1 的跨 repository evidence。它是 review evidence，不是第二份 normative policy；最終 normative requirement 以 `skill-repository-standard.md` 為準。

## Reviewed repositories

- `SyuanTsai/Skill-General`
- `SyuanTsai/Skill-Knowledge-Content`
- `SyuanTsai/Skill-Code-Collaboration`
- `SyuanTsai/Skill-Darktide-Translate`
- `SyuanTsai/Skill-Atlassian-Ecosystem`

## Matrix

| 面向 | Skill-General | Knowledge-Content | Code-Collaboration | Darktide-Translate | Atlassian-Ecosystem | Standard 決策 |
| --- | --- | --- | --- | --- | --- | --- |
| Repository structure | `.agents/skills`, catalog, scripts, tests, dual CI | `.agents/skills`, `catalog/source.json`, validator, Pester | `.agents/skills`, full local catalog, `VERSION`, release docs | `.agents/skills`, large domain package, pre-push/release tooling | canonical `skills/`, `catalog/source.json`, install/host adapters | **MUST** separate canonical source layout from consumer projection; v1 canonical source root is `skills/` |
| Skill package structure | `SKILL.md`, `agents/openai.yaml`, optional refs/scripts | same + references | same | same + assets, extensive scripts/references | same under `skills/` | `SKILL.md` + validated `agents/openai.yaml` **MUST**; scripts/references/assets **MAY** |
| Catalog / inventory | repository-local full catalog | compact source inventory | repository-local full catalog | repository-local full catalog | compact source inventory + `skillsRoot` | Source repo **MUST** own compact source inventory; cross-source profiles/dependencies/lifecycle remain central policy |
| Source / pin / provenance | consumer pins external source | emits per-Skill deterministic hash in validator | `Get-SourcePin.ps1` emits repository tree fingerprint | strong commit/package/source binding | explicit source tracking and reviewed revision install | commit identity, archive integrity, per-Skill content integrity **MUST** be distinct concepts and fields |
| Validation entry point | repo contract + Pester | `scripts/validate.ps1` + Pester | catalog validation + pin script | pre-push orchestration + component diagnostics | repository/API validation + quality gates | Each repo **MUST** expose one canonical validation entry contract used by local/CI; diagnostic subcommands **MAY** exist |
| Local validation | PowerShell contract + Pester | PowerShell validator + Pester | PowerShell scripts | HEAD-bound pre-push gate | PowerShell tests | Local gate **MUST** execute same policy as CI; no divergent judgment logic |
| CI workflow | `skill-validator` / `skill-tools` + repository tests | shared quality gate + repo tests | shared quality gate + catalog tests | shared quality gate + strict domain tests | shared quality gate + `gh skill publish --dry-run` + routing tests | Common spec/security/repo/test stages **MUST** be shared contract; host/domain checks are extensions |
| Validation tool policy | quality tools currently resolve latest while Pester compatibility lanes may pin older versions | mixed repository-local tool resolution | mixed repository-local tool resolution | strong gates but repository-local tool acquisition | latest quality tools plus host-specific checks | Formal validation **MUST** resolve central approved sources/endpoints at latest stable per run, record version/identity and freeze that run; `skill-tools` is bound to `https://registry.npmjs.org/`; `skill-validator` is bound to `https://proxy.golang.org` + `sum.golang.org`, with `GOENV=off` and no private/no-proxy/no-sumdb/insecure bypass; prerelease/pseudo versions are not stable releases; older pins are compatibility-only |
| Tests / regression | repository and Skill regressions | repository contract | catalog regressions | extensive functional/state/provenance regressions | API safety/routing/host regressions | Conformance + repository regression **MUST**; domain regression **MUST** when domain behavior exists |
| Release / publish | immutable SHA/tag consumer pin | release/rollback contract | explicit `VERSION`, release/rollback | strong release/pin/rollback evidence | GitHub Skill publishing/install path | Publish **MUST** follow immutable validated candidate; GitHub-hosted Skill repos **SHOULD** dry-run publish compatibility |
| Security checks | current general quality gates | limited repository safety | limited repository safety | high-risk external-write/state controls | credential/network/MCP/API safety controls | Security policy **MUST** be centralized; legitimate capability is not automatically a vulnerability |
| AI / Human Review | review Skill exists but not lifecycle authority | no uniform lifecycle boundary | no uniform lifecycle boundary | explicit review/evidence concepts | routing/security acceptance | AI Review **MUST NOT** replace Human Release Approval; approved immutable releases do not require repeated release approval on every install |
| Special capabilities | Datadog/Notion connectors | private knowledge/material processing | Copilot delegation | executable PowerShell, Git, GitHub, state/reservations | Jira/Confluence/Bitbucket, credentials, MCP/network | Differences **MUST** enter via declared capability/adapter/config/extension points |
| Extension / exception needs | low | source-inventory hash logic | repository fingerprint naming | clean-HEAD/package binding/stateful gates | host publishing/routing/credential adapters | Extension may strengthen controls, but **MUST NOT** redefine base gate semantics |

## Main findings

### 1. Source layout and runtime layout are currently conflated

Four repositories historically use `.agents/skills/<id>` as source layout, while `Skill-Atlassian-Ecosystem` already uses `skills/<id>` as canonical source and projects installed copies to host-specific paths. The central Catalog/Lock still contains production pins for the historical layout. Standard v1 therefore separates source package identity from consumer installation projection; migration changes are deferred to SYP-155～159 and later pin updates.

### 2. Two metadata ownership models exist

`Skill-General`, `Skill-Code-Collaboration`, and `Skill-Darktide-Translate` maintain richer local catalogs, while `Skill-Knowledge-Content` and `Skill-Atlassian-Ecosystem` use compact source inventory. Cross-source policy such as profiles, compatibility, dependencies and lifecycle is already centrally consumed by `SyuanTsai-AI-Instructions`; duplicating that policy in each source repository creates drift. Standard v1 selects a compact source-owned inventory contract.

### 3. Integrity names are not consistent

Per-Skill deterministic content inventory, repository tree fingerprint, archive SHA and resolved Git commit are different security properties. Existing scripts do not always name them distinctly. Standard v1 requires distinct names and semantics.

### 4. Validation must be layered, not flattened

All repositories need common Skill/package validation and repository contract validation, but Darktide and Atlassian have legitimate additional gates. Standard v1 therefore defines shared stage semantics plus extension stages/adapters, rather than requiring every repository to run every domain-specific check.

### 5. Security must distinguish capability from risk

Jira/MCP/network/environment variables/executable scripts are legitimate capabilities in some repositories. Static or semantic scanners may flag them, but capability presence alone must not equal BLOCK. Standard v1 requires deterministic severity policy, analyzer completeness, explicit suppression/exception evidence, and Human Release Approval for accepted risk.

### 6. Validation tool source, distribution endpoint and version are supply-chain properties

Existing repositories resolve quality/security/test tools differently. Checking only a tool's version channel is insufficient because a changed package/repository source or package-manager endpoint could still claim `latest-stable`. SYP-167 therefore adds central `validation-toolchain.json`, `scripts/Resolve-StandardValidationTool.ps1`, authority-level regression tests and Standards Conformance CI. Canonical runs validate approved sources/endpoints first, resolve latest stable from those sources, reject prerelease/pseudo versions where provider semantics require a stable release, record resolved version/identity, and freeze the resolved tool for that run.

For Go-based `skill-validator`, repository identity alone is insufficient because Go distribution can be redirected by environment/config. The authority policy therefore fixes `GOPROXY=https://proxy.golang.org`, `GOSUMDB=sum.golang.org`, disables persisted Go environment config with `GOENV=off`, and prevents `GOPRIVATE`, `GONOPROXY`, `GONOSUMDB`, or `GOINSECURE` from bypassing the canonical proxy/checksum path. Resolver regressions require conflicting process-level overrides to fail before module resolution.

## SYP-167 authority deliverables

SYP-167 now establishes more than prose policy. The authority repository contains:

- normative Standard v1;
- cross-repository review evidence;
- machine-readable validation tool policy;
- trusted-source / trusted-endpoint validation tool resolver;
- authority-level regression tests, including source/registry/Go-distribution/version negative cases;
- Standards Conformance CI using the central resolver.

These are authority-level controls only; SYP-167 still does **not** migrate any external Skill repository or repin production Catalog/Lock content.

## Migration order

1. SYP-167 establishes Standard v1 plus the authority-level tool policy, resolver, regression tests and CI.
2. SYP-155 migrates `Skill-General` and creates the first complete Skill repository reference implementation/conformance validator.
3. SYP-156～159 migrate the remaining repositories using the Standard as authority and `Skill-General` only as implementation reference.
4. Production Catalog/Lock pins are updated only after the corresponding source migration is merged and validated.
