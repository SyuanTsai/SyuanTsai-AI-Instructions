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
| CI workflow | `skill-validator` / `skill-tools` + repository tests | shared quality gate + repo tests | shared quality gate + catalog tests | shared quality gate + strict domain tests | shared quality gate + `gh skill publish --dry-run` + routing tests | Common spec/security/repo/test stages **MUST** be shared contract; authority gate is independently visible as Standards Conformance and bridged into the Ruleset-required `Composition (PowerShell 7 on Linux)` context; reusable actions use reviewed full commit SHAs, every checkout sets `persist-credentials: false`, authority path filters include the bridge/regressions, and whitespace checks use the actual PR/push range |
| Validation tool policy | quality tools currently resolve latest while Pester compatibility lanes may pin older versions | mixed repository-local tool resolution | mixed repository-local tool resolution | strong gates but repository-local tool acquisition | latest quality tools plus host-specific checks | Formal validation **MUST** resolve central approved sources/endpoints at latest stable per run, record version/identity and freeze that run; `skill-tools` is bound to `https://registry.npmjs.org/`; `skill-validator` is bound to `https://proxy.golang.org` + `sum.golang.org`, empty per-run module/build caches, and empty `GOFLAGS`; SkillSpector uses `https://pypi.org/simple`, verified hash-locked wheelhouse installation, isolated venv / Python `-I`, GitHub-token clearing before Python, ephemeral installability verification, static `dist-info/METADATA` verification, root direct-reference pre-network rejection and transitive post-materialization rejection before install; older pins are compatibility-only and the resolver validates that boundary |
| Tests / regression | repository and Skill regressions | repository contract | catalog regressions | extensive functional/state/provenance regressions | API safety/routing/host regressions | Conformance + repository regression **MUST**; authority regression is split into core policy, workflow enforcement and resolver-hardening suites; domain regression **MUST** when domain behavior exists |
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

### 6. Validation tool source, distribution endpoint, dependency closure and version are supply-chain properties

Existing repositories resolve quality/security/test tools differently. Checking only a tool's version channel is insufficient because a changed package/repository source, package-manager endpoint, dependency source, injected package-manager environment option, local cache or ambient credential could still claim `latest-stable`. SYP-167 therefore adds central `validation-toolchain.json`, `scripts/Resolve-StandardValidationTool.ps1`, authority-level regression tests and Standards Conformance CI. Canonical runs validate approved sources/endpoints first, resolve latest stable from those sources, reject prerelease/pseudo versions where provider semantics require a stable release, record resolved version/identity, and freeze the resolved tool for that run.

For Go-based `skill-validator`, repository identity alone is insufficient because Go distribution/build behavior can be redirected by environment/config, satisfied from caller-controlled shared module/build caches, or altered with injected `GOFLAGS`. The authority policy therefore fixes `GOPROXY=https://proxy.golang.org`, `GOSUMDB=sum.golang.org`, disables persisted Go environment config with `GOENV=off`, prevents `GOPRIVATE`, `GONOPROXY`, `GONOSUMDB`, or `GOINSECURE` from bypassing the canonical proxy/checksum path, rejects non-empty `GOFLAGS`, and requires each resolver invocation to use fresh temporary `GOMODCACHE` and `GOCACHE` directories. Resolver regressions require conflicting process-level overrides, including inherited caches, to fail before module resolution and require both isolated caches to be removed afterward.

For Python-based SkillSpector, verifying only the GitHub release wheel does not protect its transitive runtime dependencies, isolating pip alone does not prevent inherited `PYTHONPATH`, `PYTHONHOME`, or user-site imports from changing the interpreter that creates the venv or runs pip, and `Requires-Dist` direct references require more precise enforcement semantics than a single “approved index only” claim. The authority policy therefore requires Python `-I` isolated mode for Python subprocesses, rejects direct URL/VCS/local-file references in the root wheel before dependency network resolution, binds normal dependency resolution to `https://pypi.org/simple`, applies deny-by-default inheritance for `PIP_*` environment variables, disables pip config and cache, accepts wheels only, and materializes the resolved direct/transitive closure into a temporary wheelhouse. Every materialized wheel is inspected; a transitive direct reference causes a post-materialization fail closed before installation or SkillSpector execution. This post-materialization check is not evidence that pip never contacted the referenced network location during resolution; environments that require that stronger guarantee need transport/sandbox egress enforcement.

The wheelhouse uses normalized distribution names with ordinal ordering, records SHA-256 for every distribution, writes a hash-locked requirements file, and performs final installation inside an isolated venv with `--no-index --require-hashes --no-deps`. Resolver `-Install` is explicitly an ephemeral installability check: after installation it reads the sole matching `*.dist-info/METADATA` directly, verifies Name/Version without starting the installed interpreter, and removes the temporary venv. This matters because starting Python normally can process executable `.pth` lines placed in site-packages. The root release is bound across GitHub tag, expected wheel filename, wheel `METADATA` Name/Version, release asset SHA-256, installed metadata Name/Version, dependency closure and these verification-mode receipts.

GitHub API credentials are used only for SkillSpector release/tag/asset acquisition and are removed from the process environment before any Python or pip subprocess. The resolver restores the caller environment during cleanup and records `credentialIsolation=github-token-cleared-before-python`. The compatibility-lane fields are also enforced by the resolver rather than treated as passive JSON documentation.

### 7. Authority CI must be merge-blocking, not merely visible

The active SYP-94 Ruleset requires the existing Production and PowerShell contexts but does not currently list the new `Standards Conformance` context. To avoid a window where the authority workflow can fail without blocking merge, SYP-167 bridges the same central resolver/live SkillSpector/latest-Pester authority gate into the already-required `Composition (PowerShell 7 on Linux)` job. The standalone Standards Conformance workflow remains the dedicated evidence surface.

A second review found three enforcement gaps and closed them: workflow actions are now pinned to reviewed full commit SHAs instead of mutable major tags; every checkout explicitly sets `persist-credentials: false`; and the dedicated workflow watches changes to the required bridge and all authority regression files. Both authority workflows select whitespace/diff ranges from the actual pull-request base or push-before SHA, avoiding the previous `origin/main...HEAD` expression that becomes empty after a push has already advanced `main`. Workflow regression protects these invariants.

### 8. Verification must not execute newly installed startup code

The first resolver implementation verified the installed SkillSpector version by starting the newly installed Python interpreter and calling `importlib.metadata.version`. Python startup can process executable `.pth` lines from site-packages, so this turned an identity check into an unintended execution boundary. The resolver now performs static `dist-info/METADATA` inspection from PowerShell, rejects reparse-backed metadata, requires exactly one matching distribution, and records `installedMetadataVerification=static-dist-info-metadata`. Dedicated regression creates a synthetic executable `.pth` line and proves metadata verification does not process it.

## SYP-167 authority deliverables

SYP-167 now establishes more than prose policy. The authority repository contains:

- normative Standard v1;
- cross-repository review evidence;
- machine-readable validation tool policy;
- trusted-source / trusted-endpoint validation tool resolver;
- core policy authority regression: `tests/skill-repository-standard.Tests.ps1`;
- workflow authority regression: `tests/skill-repository-workflows.Tests.ps1`;
- resolver hardening regression: `tests/standard-validation-resolver-hardening.Tests.ps1`;
- dedicated Standards Conformance CI using the central resolver and all authority suites;
- merge-blocking authority enforcement through the Ruleset-required Linux Composition context;
- immutable full-SHA workflow action pins, checkout credential isolation and event-aware diff-range enforcement.

These are authority-level controls only; SYP-167 still does **not** migrate any external Skill repository or repin production Catalog/Lock content.

## Migration order

1. SYP-167 establishes Standard v1 plus the authority-level tool policy, resolver, regression tests and CI.
2. SYP-155 migrates `Skill-General` and creates the first complete Skill repository reference implementation/conformance validator.
3. SYP-156～159 migrate the remaining repositories using the Standard as authority and `Skill-General` only as implementation reference.
4. Production Catalog/Lock pins are updated only after the corresponding source migration is merged and validated.
