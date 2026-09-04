# SYP-167 Cross-Repository Review Matrix

本文件記錄 Standard v1 的跨 repository evidence。它是 review evidence，不是第二份 normative policy；最終 normative requirement 以 `skill-repository-standard.md` 為準。

## Reviewed repositories

- `SyuanTsai/Skill-General`
- `SyuanTsai/Skill-Knowledge-Content`
- `SyuanTsai/Skill-Code-Collaboration`
- `SyuanTsai/Skill-Darktide-Translate`
- `SyuanTsai/Skill-Atlassian-Ecosystem`

舊版 matrix 只列 repository name，沒有留下 immutable revision，因此無法由舊文字反向證明當時實際檢查的 mutable branch head。下表自本次修正起建立可重現 review baseline；所有 claim 只涵蓋表列 commit，後續 repository change 必須明確 refresh evidence。Production pin 是另一個 consumer runtime fact，不等同 reviewed revision。

| Repository | Exact reviewed commit | Review date (UTC) | Primary evidence paths at that commit | Production pin at review |
| --- | --- | --- | --- | --- |
| `Skill-General` | [`01ac760cff3e0722849e0705c7af44cfe19835ba`](https://github.com/SyuanTsai/Skill-General/commit/01ac760cff3e0722849e0705c7af44cfe19835ba) | 2026-09-02 | `catalog/skills-catalog.json`, `.github/workflows/validate.yml`, `README.md` | `01ac760cff3e0722849e0705c7af44cfe19835ba` |
| `Skill-Knowledge-Content` | [`d483dce47b199b65a309839720bf131b188ac5a5`](https://github.com/SyuanTsai/Skill-Knowledge-Content/commit/d483dce47b199b65a309839720bf131b188ac5a5) | 2026-09-02 | `catalog/source.json`, `scripts/validate.ps1`, `.github/workflows/validate.yml`, `RELEASING.md` | `d483dce47b199b65a309839720bf131b188ac5a5` |
| `Skill-Code-Collaboration` | [`2d864e4b0ee0f9e2a0cc00dab29cf2f1cfdae45d`](https://github.com/SyuanTsai/Skill-Code-Collaboration/commit/2d864e4b0ee0f9e2a0cc00dab29cf2f1cfdae45d) | 2026-09-02 | `catalog/skills-catalog.json`, `tests/validate-catalog.ps1`, `scripts/Get-SourcePin.ps1`, `.github/workflows/validate.yml`, `.github/workflows/skill-validator.yml` | `2d864e4b0ee0f9e2a0cc00dab29cf2f1cfdae45d` |
| `Skill-Darktide-Translate` | [`d08261243d531a815128ffb8c5d99e1f4ea12f19`](https://github.com/SyuanTsai/Skill-Darktide-Translate/commit/d08261243d531a815128ffb8c5d99e1f4ea12f19) | 2026-09-02 | `catalog/skills-catalog.json`, `.github/workflows/validate.yml`, `tests/Invoke-Tests.ps1`, `README.md` | `None` — independent product，刻意不進 central Catalog/Lock |
| `Skill-Atlassian-Ecosystem` | [`110170a1c54ea42a5a6cc8a483e70e561e19fea0`](https://github.com/SyuanTsai/Skill-Atlassian-Ecosystem/commit/110170a1c54ea42a5a6cc8a483e70e561e19fea0) | 2026-09-02 | `catalog/source.json`, `tests/validate-repository.ps1`, `tests/validate-api-access.ps1`, `.github/workflows/skill-validator.yml`, `README.md` | `975661f8c9e64cea21e6b8109329888d3f5697da` |

Production pin 欄以 [`SyuanTsai-AI-Instructions@a3eb0416746d343e4a3c8d99b1c635fdbbd7195e/catalog/skills-catalog-lock.json`](https://github.com/SyuanTsai/SyuanTsai-AI-Instructions/blob/a3eb0416746d343e4a3c8d99b1c635fdbbd7195e/catalog/skills-catalog-lock.json) 為 immutable evidence；它只證明 consumer pin，不證明外部 repository review coverage。

## Matrix

| 面向 | Skill-General | Knowledge-Content | Code-Collaboration | Darktide-Translate | Atlassian-Ecosystem | Standard 決策 |
| --- | --- | --- | --- | --- | --- | --- |
| Repository structure | `.agents/skills`, catalog, scripts, tests, dual CI | `.agents/skills`, `catalog/source.json`, validator, Pester | `.agents/skills`, full local catalog, `VERSION`, release docs | `.agents/skills`, large domain package, pre-push/release tooling | canonical `skills/`, `catalog/source.json`, install/host adapters | **MUST** separate canonical source layout from consumer projection; v1 canonical source root is `skills/` |
| Skill package structure | `SKILL.md`, `agents/openai.yaml`, optional refs/scripts | same + references | same | same + assets, extensive scripts/references | same under `skills/` | `SKILL.md` + validated `agents/openai.yaml` **MUST**; scripts/references/assets **MAY** |
| Catalog / inventory | repository-local full catalog | compact legacy source inventory | repository-local full catalog | repository-local full catalog | compact legacy source inventory + `skillsRoot` | Source repo **MUST** own strict `catalog/source.json` schema v2 inventory; cross-source profiles/dependencies/lifecycle remain central policy, while an excluded independent product may retain non-competing product-local extension metadata |
| Source / pin / provenance | consumer pins external source | emits per-Skill deterministic hash in validator | `Get-SourcePin.ps1` emits repository tree fingerprint | strong commit/package/source binding | explicit source tracking and reviewed revision install | commit identity, archive integrity, per-Skill content integrity **MUST** be distinct concepts and fields |
| Validation entry point | repo contract + Pester | `scripts/validate.ps1` + Pester | catalog validation + pin script | pre-push orchestration + component diagnostics | repository/API validation + quality gates | Each repo **MUST** expose one canonical validation entry contract used by local/CI; diagnostic subcommands **MAY** exist |
| Local validation | PowerShell contract + Pester | PowerShell validator + Pester | PowerShell scripts | HEAD-bound pre-push gate | PowerShell tests | Local gate **MUST** execute same policy as CI; no divergent judgment logic |
| CI workflow | `skill-validator` / `skill-tools` + repository tests | shared quality gate + repo tests | shared quality gate + catalog tests | shared quality gate + strict domain tests | shared quality gate + `gh skill publish --dry-run` + routing tests | Common spec/security/repo/test stages **MUST** be shared contract; formal tools must actually execute against complete active inventory, not stop at resolver receipts; authority gate is independently visible as Standards Conformance and bridged into the Ruleset-required `Composition (PowerShell 7 on Linux)` context; reusable actions use reviewed full commit SHAs, every checkout sets `persist-credentials: false`, authority path filters include the bridge/regressions, and whitespace checks use the actual PR/push range |
| Validation tool policy | quality tools currently resolve latest while Pester compatibility lanes may pin older versions | mixed repository-local tool resolution | mixed repository-local tool resolution | strong gates but repository-local tool acquisition | latest quality tools plus host-specific checks | Formal validation **MUST** resolve central approved sources/endpoints at latest stable per run, record version/identity and freeze that run; `skill-tools` is bound to `https://registry.npmjs.org/`; `skill-validator` is bound to `https://proxy.golang.org` + `sum.golang.org`, empty per-run module/build caches, and empty `GOFLAGS`; SkillSpector uses only approved `https://pypi.org/simple` JSON candidates, pre-pool endpoint/hash/wheel/metadata/direct-reference/`Requires-Python` checks, lazy offline backtracking, an exact hash-locked selected wheelhouse, a run-owned isolated venv, static `dist-info` metadata/entry-point verification and GitHub-token clearing before resolver-managed Python; older pins are compatibility-only and the resolver validates that boundary |
| Tests / regression | repository and Skill regressions | repository contract | catalog regressions | extensive functional/state/provenance regressions | API safety/routing/host regressions | Conformance + repository regression **MUST**; authority regression is split into core policy, workflow enforcement and resolver-hardening suites; domain regression **MUST** when domain behavior exists |
| Managed lifecycle / legacy migration | managed manifest and user-scope projection; migration evidence pending reference implementation | source migration pending | source migration pending | independent product; no central managed projection | host/install adapter migration pending | Central `managed-skill-lifecycle.md` **MUST** define deterministic replacement, explicit known-legacy adoption, ownership evidence, drift/collision blocking, transaction backup/rollback/recovery and exact post-install verification; repositories **MUST** conform through adapters and domain tests, not local lifecycle policies |
| Upstream interoperability | portable `SKILL.md` plus OpenAI metadata; no Plugin wrapper | portable `SKILL.md`; legacy projection | portable `SKILL.md`; Copilot-specific extension | portable `SKILL.md` plus domain/runtime extensions | portable `SKILL.md`; MCP/API host adapters | SYP-193 **MUST** pin the Agent Skills baseline and define explicit Adopt / Partial Adopt / Do Not Adopt decisions for Plugin manifest, `skills/`, MCP/app mapping, marketplace, ref/version and hooks; upstream surfaces **MUST NOT** replace central provenance, security, lifecycle or approval |
| Release / publish | immutable SHA/tag consumer pin | release/rollback contract | explicit `VERSION`, release/rollback | strong release/pin/rollback evidence | GitHub Skill publishing/install path | Publish **MUST** follow immutable validated candidate; GitHub-hosted Skill repos **SHOULD** dry-run publish compatibility |
| Security checks | current general quality gates | limited repository safety | limited repository safety | high-risk external-write/state controls | credential/network/MCP/API safety controls | Security policy **MUST** be centralized; legitimate capability is not automatically a vulnerability |
| AI / Human Review | review Skill exists but not lifecycle authority | no uniform lifecycle boundary | no uniform lifecycle boundary | explicit review/evidence concepts | routing/security acceptance | AI Review **MUST NOT** replace Human Release Approval; approved immutable releases do not require repeated release approval on every install |
| Special capabilities | Datadog/Notion connectors | private knowledge/material processing | Copilot delegation | executable PowerShell, Git, GitHub, state/reservations | Jira/Confluence/Bitbucket, credentials, MCP/network | Differences **MUST** enter via declared capability/adapter/config/extension points |
| Extension / exception needs | low | source-inventory hash logic | repository fingerprint naming | clean-HEAD/package binding/stateful gates | host publishing/routing/credential adapters | Extension may strengthen controls, but **MUST NOT** redefine base gate semantics; release-affecting extension executables require a central source/version/resolver declaration first |

## Main findings

### 1. Source layout and runtime layout are currently conflated

Four repositories historically use `.agents/skills/<id>` as source layout, while `Skill-Atlassian-Ecosystem` already uses `skills/<id>` as canonical source and projects installed copies to host-specific paths. The central Catalog/Lock still contains production pins for the historical layout. Standard v1 therefore separates source package identity from consumer installation projection; migration changes are deferred to SYP-155～159 and later pin updates.

### 2. Two metadata ownership models exist

`Skill-General`, `Skill-Code-Collaboration`, and `Skill-Darktide-Translate` maintain richer local catalogs, while `Skill-Knowledge-Content` and `Skill-Atlassian-Ecosystem` use compact source inventory. Cross-source policy such as profiles, compatibility, dependencies and lifecycle is already centrally consumed by `SyuanTsai-AI-Instructions`; duplicating that policy in each source repository creates drift. Standard v1 therefore selects strict `catalog/source.json` schema v2 as the source-owned inventory contract. `Skill-Darktide-Translate` 不進 central composition；其 Darktide-only selection/state/domain metadata 可改列 product-local extension config 保留，但不得冒充 source inventory 或共用 policy authority。

### 3. Integrity names are not consistent

Per-Skill deterministic content inventory, repository tree fingerprint, archive SHA and resolved Git commit are different security properties. Existing scripts do not always name them distinctly. Standard v1 requires distinct names and semantics.

### 4. Validation must be layered, not flattened

All repositories need common Skill/package validation and repository contract validation, but Darktide and Atlassian have legitimate additional gates. Standard v1 therefore defines shared stage semantics plus extension stages/adapters, rather than requiring every repository to run every domain-specific check.

### 5. Security must distinguish capability from risk

Jira/MCP/network/environment variables/executable scripts are legitimate capabilities in some repositories. Static or semantic scanners may flag them, but capability presence alone must not equal BLOCK. Standard v1 requires deterministic severity policy, analyzer completeness, explicit suppression/exception evidence, and Human Release Approval for accepted risk.

### 6. Validation tool source, distribution endpoint, dependency closure and version are supply-chain properties

Checkout disables persisted credentials, and the authority gate removes `GITHUB_TOKEN`/`GH_TOKEN` immediately after SkillSpector release acquisition, before approved-index candidate requests or another tool resolution.

The Requires-Python policy parses zero or one wheel `METADATA` field for the root and every dependency, rejects invalid or current-interpreter-incompatible specifiers, and requires the approved Simple JSON and wheel values to produce the same normalized PEP 440 `SpecifierSet`; formatting-only whitespace or ordering differences are accepted. A missing/null index value is accepted only when the wheel also omits the field, so pip never sees a candidate whose index compatibility claim is missing or semantically inconsistent with its embedded metadata.

Existing repositories resolve quality/security/test tools differently. Checking only a tool's version channel is insufficient because a changed package/repository source, package-manager endpoint, dependency source, injected package-manager environment option, local cache or ambient credential could still claim `latest-stable`. SYP-167 therefore adds central `validation-toolchain.json`, `scripts/Resolve-StandardValidationTool.ps1`, authority-level regression tests and Standards Conformance CI. Canonical runs validate approved sources/endpoints first, resolve latest stable from those sources, reject prerelease/pseudo versions where provider semantics require a stable release, record resolved version/identity, and freeze the resolved tool for that run.

Resolution/install receipts are supply-chain evidence, not validation results. A conformant source-repository run must freeze the complete required toolset once and then actually execute SkillSpector, `skill-validator`, `skill-tools check` and Pester against the exact active package/test inventory assigned by the Standard; missing invocation/coverage/result fails closed. The authority repository intentionally has no active shared Skill source, so its gate must run the same four tools against a candidate-bound controlled Skill fixture plus authority regressions rather than vacuously passing an empty inventory. Repository-specific executable extensions such as `gh` may affect release outcome only after central policy defines their source, endpoint, version rule, identity evidence and resolver/host verification adapter.

For Go-based `skill-validator`, repository identity alone is insufficient because Go distribution/build behavior can be redirected by environment/config, satisfied from caller-controlled shared module/build caches, or altered with injected compiler roots, targets, or `GOFLAGS`. The authority policy therefore fixes `GOPROXY=https://proxy.golang.org`, `GOSUMDB=sum.golang.org`, disables persisted Go environment config with `GOENV=off`, prevents `GOPRIVATE`, `GONOPROXY`, `GONOSUMDB`, or `GOINSECURE` from bypassing the canonical proxy/checksum path, rejects inherited `GOROOT`, `GOTOOLDIR`, target/build selectors and non-empty `GOFLAGS`, and requires each resolver invocation to use fresh temporary `GOMODCACHE` and `GOCACHE` directories plus run-owned temporary/build-output paths. Resolver regressions require conflicting process-level overrides, including inherited caches and tool roots, to fail before module resolution and require all isolated build inputs to be removed afterward.

For Python-based SkillSpector, verifying only the GitHub release wheel does not protect its transitive runtime dependencies, isolating pip alone does not prevent inherited `PYTHONPATH`, `PYTHONHOME`, user-site imports, or caller-selected CA bundles from changing the interpreter or transport trust, and `Requires-Dist` direct references can bypass an approved index. The authority policy therefore requires Python `-I` isolated mode for every resolver-managed Python subprocess used for venv creation, candidate-helper execution and offline pip resolution/install; installed Name/Version and the `skillspector` console entry point are instead read statically from `.dist-info/METADATA` and `entry_points.txt` before any installed interpreter can process site-packages `.pth` startup code. It rejects direct URL/VCS/local-file dependency references before root dependency resolution and on every candidate before pip can inspect it, and forbids pip from traversing dependencies online. A hash-bound helper reads only the approved PyPI Simple JSON API, rejects yanked files, explicitly sorts PEP 440 versions and current-interpreter wheel tags, verifies redirect/endpoint, advertised SHA-256, wheel/archive identity, metadata and direct-reference policy, and lazily adds one older compatible candidate per known project only when the current verified local pool is unsatisfiable. pip performs the authoritative backtracking solely with `--no-index` against that pool; this avoids both the false failure caused by freezing one incompatible parent-version combination and the unbounded cost of prefetching every historical release. The selected report is path/hash checked against the pool, reduced to an exact selected wheelhouse, verified again with a hash-locked offline plan, and installed with `--no-index --require-hashes --no-deps`. The receipt binds the helper hash, stable candidate inventory, normalized plan, selected closure, pip version, run-local raw report evidence, credential isolation and static installed-metadata verification. The resolver also applies deny-by-default inheritance for `PIP_*` environment variables (only an already-approved `PIP_INDEX_URL` may be inherited), rejects `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `SSL_CERT_FILE`, and `SSL_CERT_DIR`, disables pip config and cache, and binds the root release across GitHub tag, expected wheel filename, wheel `METADATA` Name/Version, release asset SHA-256, installed package version and console entry point.

For npm-based `skill-tools`, an approved registry string is insufficient if inherited Node/npm TLS or configuration controls can replace transport trust or execution behavior. The resolver therefore uses empty user/global npm config plus a controlled project config, rejects inherited `NPM_CONFIG_*` except an already-approved `NPM_CONFIG_REGISTRY`, rejects inherited `NODE_*`, `SSL_CERT_FILE`, and `SSL_CERT_DIR`, disables package scripts, and binds the exact lockfile, package integrity, Node runtime, package entry point, and installed closure.

### 7. Authority CI must be merge-blocking, not merely visible

The active SYP-94 Ruleset requires the existing Production and PowerShell contexts but does not currently list the new `Standards Conformance` context. To avoid a window where the authority workflow can fail without blocking merge, SYP-167 bridges the same central resolver/live SkillSpector/latest-Pester authority gate into the already-required `Composition (PowerShell 7 on Linux)` job. The standalone Standards Conformance workflow remains the dedicated evidence surface.

A second review found three enforcement gaps and closed them: workflow actions are now pinned to reviewed full commit SHAs instead of mutable major tags; every checkout explicitly sets `persist-credentials: false`; and the dedicated workflow watches changes to the required bridge and all authority regression files. Both authority workflows select whitespace/diff ranges from the actual pull-request base or push-before SHA, avoiding the previous `origin/main...HEAD` expression that becomes empty after a push has already advanced `main`. Workflow regression protects these invariants.

### 8. Verification must not execute newly installed startup code

The first resolver implementation verified the installed SkillSpector version by starting the newly installed Python interpreter and calling `importlib.metadata.version`. Python startup can process executable `.pth` lines from site-packages, so this turned an identity check into an unintended execution boundary. The resolver now performs static `dist-info/METADATA` and `entry_points.txt` inspection from PowerShell, rejects reparse-backed metadata and entry-point paths, requires exactly one matching distribution and one safe `skillspector = module:attr` console entry point, and records `installedMetadataVerification=static-dist-info-metadata`. Dedicated regression creates a synthetic executable `.pth` line and proves metadata verification does not process it.

### 9. Managed replacement must prove ownership before destructive change

The repositories expose different historical projection and migration shapes, so a path name or directory name cannot be a portable ownership proof. SYP-194 adds the central managed lifecycle contract and evidence schema: current manifest entries prove `managed` ownership only when their recorded hash matches; explicit Catalog lifecycle aliases plus `-MigrateLegacyCatalogSkills` prove `known-legacy` ownership only for the exact legacy inventory; local hash drift, unlisted legacy content, and unknown collisions block closed and preserve the bytes. The reference reconciler snapshots every verified candidate into the transaction before mutation, writes only from that snapshot, records structured evidence/remediation, and verifies the exact installed inventory and manifest bytes before clearing recovery state. SYP-155～159 must adopt this contract without introducing repository-local lifecycle or deletion policy.

### 10. Upstream interoperability is an adapter boundary

SYP-193 records the reviewed Agent Skills and OpenAI Plugin evidence in [`upstream-interoperability.md`](upstream-interoperability.md). The portable contract is `SKILL.md` plus optional relative resources; Plugin packaging and MCP/app/marketplace surfaces are conditional adapters. The Agent Skills baseline is pinned to an immutable commit, while the reviewed OpenAI Plugin documentation did not expose a versioned public JSON Schema, so its documented fields are not allowed to drift into Standard v1 without a new review and authority regression. Dynamic discovery, mutable refs, version-only provenance, hook execution and marketplace metadata cannot bypass the central Catalog/Lock, security gate, lifecycle, AI Review or Human Approval.

## SYP-167 authority deliverables

SYP-167 now establishes more than prose policy. The authority repository contains:

- normative Standard v1;
- cross-repository review evidence;
- strict source-inventory schema v2 and OpenAI metadata semantic schema;
- machine-readable validation tool policy;
- trusted-source / trusted-endpoint validation tool resolver;
- core policy authority regression: `tests/skill-repository-standard.Tests.ps1`;
- workflow authority regression: `tests/skill-repository-workflows.Tests.ps1`;
- resolver hardening regression: `tests/standard-validation-resolver-hardening.Tests.ps1`;
- authority-level negative regressions covering source/registry/Go-distribution/pip-distribution/version/dependency closure, static installed metadata, credential lifetime, checkout and merge enforcement;
- managed lifecycle contract/schema plus regressions for candidate integrity, ownership classification, legacy alias evidence, collision blocking, transaction-owned staging and exact post-install manifest verification;
- dedicated Standards Conformance CI using the central resolver, shared authority gate and all authority suites;
- merge-blocking authority enforcement through the Ruleset-required Linux Composition context;
- immutable full-SHA workflow action pins, checkout credential isolation and event-aware diff-range enforcement.

These are authority-level controls only; SYP-167 still does **not** migrate any external Skill repository or repin production Catalog/Lock content.

## Migration order

1. SYP-167 establishes Standard v1 plus the authority-level tool policy, resolver, regression tests and CI.
2. SYP-155 migrates `Skill-General` to source inventory schema v2 and creates the first complete Skill repository reference implementation/conformance validator.
3. SYP-156～159 migrate the remaining repositories using the Standard as authority and `Skill-General` only as implementation reference.
4. Before the first `skills/<id>` production repin, central Catalog/Lock schemas、parsers、acquisition/composition and manifest provenance gain a versioned source/target-separation contract.
5. Production Catalog/Lock pins are updated only after the corresponding source migration and central contract migration are merged and validated.
