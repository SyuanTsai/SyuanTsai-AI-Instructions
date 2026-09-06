# SYP-193 Upstream Interoperability Decision

Status: **Normative companion decision record for Standard v1**
Authority: `SyuanTsai-AI-Instructions/docs/standards/`
Tracking: Jira `SYP-193`
Review baseline: **2026-09-05 (Asia/Taipei)**

本文件把上游 Agent Skills 與 Agent Plugins 契約轉換成 Standard v1 的採用邊界。它不是 source repository 可以複製的第二套規範；與本文件衝突時，以 [`skill-repository-standard.md`](skill-repository-standard.md) 為準。Source repository 只能透過 Standard 定義的 adapter、extension、config 與 domain tests 接入上游能力。

## 1. Reviewed upstream evidence

| Upstream contract | Immutable or review binding | Reviewed surface | Result |
| --- | --- | --- | --- |
| Agent Skills format | `agentskills/agentskills@69ef37e9424c0a7ea9dd2293b559e43ec8176379` | [`docs/specification.mdx`](https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/docs/specification.mdx) | Portable `SKILL.md` directory contract |
| OpenAI Plugin architecture | Official documentation URL + review date; no immutable public docs revision was exposed by the reviewed surface | [`Plugin architecture`](https://developers.openai.com/plugins/concepts/plugins) | Plugin is a package containing Skills, an MCP server, or both; capabilities may remain surface-specific |
| OpenAI Plugin package contract | Official documentation URL + review date; no versioned public JSON Schema was found during this review | [`Package your plugin`](https://developers.openai.com/plugins/build/plugins) | `.codex-plugin/plugin.json` is the required manifest; `skills/`, `.mcp.json`, `.app.json`, hooks and marketplace are optional package surfaces |
| OpenAI Skill/MCP boundary | Official documentation URL + review date | [`Skills`](https://developers.openai.com/plugins/concepts/skills) | Skill supplies workflow instructions; MCP supplies live data, authentication, authorization and actions |
| OpenAI metadata baseline already adopted by Standard v1 | `openai/skills@49f948faa9258a0c61caceaf225e179651397431` | [`quick_validate.py`](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.system/skill-creator/scripts/quick_validate.py), [`openai_yaml.md`](https://github.com/openai/skills/blob/49f948faa9258a0c61caceaf225e179651397431/skills/.system/skill-creator/references/openai_yaml.md) | Existing pinned compatibility baseline; not silently advanced by upstream drift |

The Agent Skills commit is the reproducible format baseline. The OpenAI Plugin pages are a documented package interface rather than a machine-readable, versioned schema in the reviewed evidence. Therefore a later Plugin field or behavior change **MUST NOT** silently become Standard v1: it requires a new reviewed pin/evidence entry, authority regression, and the Standard change contract.

## 2. Gap / overlap / decision matrix

`Adopt` means the upstream contract is part of the portable v1 baseline. `Partial Adopt` means only the stated adapter surface is accepted; the upstream feature cannot relax a central requirement. `Do Not Adopt` means the feature is not a v1 authority or automatic execution mechanism, although a separately reviewed product adapter may expose it as a derived view.

| Capability | Upstream contract | Overlap or gap | SYP-193 decision | Standard v1 boundary and required evidence |
| --- | --- | --- | --- | --- |
| `SKILL.md` package | One Skill directory contains `SKILL.md` with YAML frontmatter and Markdown instructions | Direct overlap with the portable package core | **Adopt** | `name`/directory identity, UTF-8, parser, body, length, security and content-integrity rules remain those of Standard v1; upstream optionality cannot weaken them |
| `scripts/`, `references/`, `assets/` | Optional resources beside `SKILL.md` | Direct overlap; references are loaded on demand | **Adopt** | Relative references, regular-file/reparse checks, package hash and executable capability review are required; a resource is not trusted merely because the upstream format permits it |
| `name` and `description` | Required metadata with stable lowercase identity and bounded description | Direct overlap, but Standard adds exact source/catalog binding | **Adopt** | Package directory, frontmatter, source inventory, Catalog/Lock and runtime manifest identity must agree; collision or drift blocks |
| `compatibility`, `metadata`, `allowed-tools` | Optional Agent Skills fields; `allowed-tools` is experimental | Portable clients may ignore them; `allowed-tools` is not a universal permission model | **Partial Adopt** | Preserve valid metadata as package data. `allowed-tools` **MUST NOT** grant credentials, write access, network access or bypass approval/security gates; host semantics remain an adapter concern |
| Canonical `skills/<skill-id>` root | OpenAI Plugin package examples point `skills` at a root directory; Standard v1 requires `skills` | Strong overlap | **Adopt** | Source repositories use `skills/` plus `catalog/source.json`; consumer projections such as `.agents/skills/` remain separate managed targets |
| `.codex-plugin/plugin.json` | Required Plugin manifest at the plugin root | Gap: a Skill source repository does not need to be a Plugin | **Partial Adopt** | A Plugin wrapper **MAY** package Standard-conformant `skills/`; manifest paths **MUST** be relative, `./`-prefixed and root-contained. It is a distribution adapter, never the source inventory or lifecycle authority |
| Plugin `skills` manifest field | Manifest points to bundled Skill folders | Overlaps the canonical source root but does not describe provenance | **Partial Adopt** | Resolve only declared package paths; validate every bundled Skill with the same canonical gate and bind source commit, archive hash, package hash and manifest identity |
| `.mcp.json` / `mcpServers` | Optional direct or wrapped MCP server map | Standard permits MCP dependencies, but a declaration is not a security approval | **Partial Adopt** | Accept only through a declared adapter. Bind endpoint, transport, tool schema, credential/permission boundary, read/write authorization and deterministic test adapter; run conditional semantic security review when capability changes |
| `.app.json` / manifest `apps` | Optional registered MCP app mapping and compatibility field | Host-specific mapping, not portable Skill content | **Partial Adopt** | Keep as Plugin/host adapter metadata. It **MUST NOT** become a central Catalog dependency or silently alter the shared MCP/security semantics |
| MCP discovery | Plugin may expose an MCP server and tools | Dynamic registry/network discovery is outside the portable Skill package | **Partial Adopt** | Only package-declared, reviewed and pinned server/tool schemas may enter a release. No implicit remote discovery, mutable endpoint, credential inheritance or auto-install is allowed |
| Plugin hooks | Optional lifecycle hooks | Hooks are host-specific executable behavior and are not required by Agent Skills | **Do Not Adopt** for Standard v1 core | A future host adapter may add hooks under the central extension/security contract; hooks cannot bypass ownership, validation, approval, rollback or post-install verification |
| `marketplace.json` | JSON catalog for Plugin distribution and install policy | Distribution view overlaps central Catalog naming, but it is not source provenance | **Partial Adopt** as a derived view | It **MAY** advertise an approved immutable Plugin release. It **MUST NOT** replace `catalog/source.json`, central Catalog/Lock, source pin, lifecycle manifest, provenance or Human Approval evidence |
| Plugin `version` / marketplace `ref` | Install-surface version/ref selectors | Version or floating ref alone is not a source/integrity proof | **Partial Adopt** | Release evidence **MUST** bind immutable Git commit/archive/package SHA and all required manifests. Mutable `main`, moving tag, unverified URL or version-only install **MUST NOT** pass |
| Plugin package publication | Public/workspace/marketplace publication surfaces | Publication occurs after, not instead of, the shared release gate | **Partial Adopt** | Canonical order remains Controlled Acquisition → Integrity → Package → SkillSpector → Repository Tests → Conditional Semantic Scan → AI Review → Human Approval → Publish/Install → Post-install Verification |

## 3. Portable contract versus SYP-specific governance

The portable contract is intentionally small:

- a stable Skill directory;
- `SKILL.md` with valid frontmatter and Markdown instructions;
- optional package-local resources addressed by relative paths;
- a host that can ignore unknown extension metadata without losing the core workflow.

SYP-specific governance remains central and is not exported as an upstream replacement:

- `catalog/source.json` schema v2, central Catalog/Lock and source ownership;
- `agents/openai.yaml` as the required organization routing/metadata extension;
- immutable source pin, provenance, per-Skill content hash and archive integrity;
- managed replacement, known-legacy ownership evidence, drift/collision blocking and rollback;
- canonical validation order, SkillSpector severity semantics, AI Review and Human Release Approval;
- local, pre-push and CI pass/block equivalence;
- release, install and exact post-install verification.

An upstream-compatible client may consume `SKILL.md` without understanding these extensions. That makes the Skill portable; it does not make an unverified source, Plugin, MCP server or marketplace entry releasable under Standard v1.

## 4. Adapter contract

An adapter that exposes the upstream surfaces **MUST**:

1. Identify its source repository, immutable revision, package/archive hash and adapter version.
2. Validate the portable `SKILL.md` contract before reading or executing optional extensions.
3. Treat `agents/openai.yaml`, `plugin.json`, `.mcp.json`, `.app.json`, marketplace metadata and hooks as typed extension inputs, not authority replacements.
4. Reject path traversal, absolute/out-of-root paths, reparse/special files, duplicate identities, unknown destructive ownership and mutable source selectors.
5. Keep MCP tool schemas, endpoint/transport, credential scope and read/write capability explicit and reviewable.
6. Emit provenance and integrity evidence that can be joined to the central release record.
7. Re-enter the canonical lifecycle and post-install verification after package projection; an upstream installer cannot stop after copying files.

Source repositories **MUST NOT** add a local Plugin/marketplace policy to compensate for a missing central decision. A requested new upstream feature is an extension proposal: update this decision record, the normative Standard if semantics change, all affected authority regressions, and the applicable repository adapters in one reviewed change.

## 5. Conformance and regression requirements

SYP-193 is complete only when the central authority proves:

- the upstream Agent Skills baseline is pinned to the exact reviewed commit above;
- Plugin manifest, `skills/`, MCP, app mapping, marketplace, version/ref and hook decisions are each explicit as Adopt / Partial Adopt / Do Not Adopt;
- the portable/governance boundary is stated and no source repository is instructed to maintain a second policy;
- schema/pin limitations are fail-closed rather than inferred from a mutable upstream document;
- authority workflow watches this document and runs all three authority regression suites;
- representative package, Plugin, MCP declaration, mutable ref, unsafe path, unknown marketplace field and unapproved endpoint cases have negative regression coverage before any fan-out migration.

The SYP-155 reference implementation and SYP-156～159 migrations may add adapter/domain tests, but they **MUST NOT** change the decisions above locally. Any finding affecting portability, security, ownership, provenance, integrity, rollback or compatibility is fixed in the current delivery or blocks the delivery; only clearly out-of-scope non-blocking work may be carried to a new Jira item with evidence.
