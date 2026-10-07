# diagram-design Mermaid acceptance

The version-controlled Mermaid inputs are the maintained source for these acceptance drawings. The agent authored each static redraw from actual IR produced by the audited fixed upstream extractor. The neutral acceptance profile uses local CJK font fallback and inline shapes, without external fonts, icons or scripts.

| Case | Nodes / participants | Edges / messages | Evidence |
| --- | --- | --- | --- |
| Architecture | 3 | 2 | `architecture.mmd`, IR, HTML and SVG |
| Flowchart | 5 | 5 | `flowchart.mmd`, IR, HTML and SVG |
| Sequence | 3 | 4 | `sequence.mmd`, IR, HTML and SVG |

`extractor-acceptance.json` records actual process exit codes, source/Skill/archive hashes and the digest-pinned Python container. It ran as uid 65534 with no network, a read-only root, dropped capabilities, resource limits, and only the audited Skill, owned inputs and owned outputs mounted. The unsupported timeline negative case returned exit 2; the untrusted-label case retained label text as data and discarded its click target.

`fidelity-ledger.json` binds source and output hashes, all relationships and sequence order, with no merges, collapses or drops. `browser-acceptance.json` records actual fresh-profile Chrome rendering at 1100×900. All six HTML/SVG screenshots were visually inspected: CJK text was readable, labels and connectors remained inside their drawing bounds, and branches/message order matched the source.

This evidence covers Mermaid extraction and the authored static HTML/SVG presentation workflow. Upstream SVG export of arbitrary HTML, draw.io decompression and PNG/browser automation require their own disposition. SourceValidation, necessary licensing, human review and managed deployment admission remain separate gates; these acceptance results are release-ineligible.
