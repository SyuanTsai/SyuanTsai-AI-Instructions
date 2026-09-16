"""Synthetic raw-graph contracts for an unsigned SkillSpector scan adapter."""

from __future__ import annotations

import importlib.util
from hashlib import sha256
import json
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "Normalize-InstalledSemanticGraph.py"
SPEC = importlib.util.spec_from_file_location("standard_semantic_raw_graph", SOURCE)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


IDS = ["semantic_alpha", "semantic_beta"]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "semantic-raw-graph"


def finding(identity: str, severity: str = "HIGH") -> SimpleNamespace:
    return SimpleNamespace(
        finding_id=f"finding-{identity}",
        rule_id="SEM-1",
        severity=severity,
        message=f"synthetic {identity} finding",
        file="SKILL.md",
        fingerprint=lambda: "f" * 64,
    )


def graph_result(skill: str, with_finding: bool = True) -> dict[str, object]:
    rows = []
    statuses = []
    calls = []
    raw_findings = []
    for identity in IDS:
        work_id = f"{skill}-{identity}-work"
        emitted = []
        if with_finding and identity == "semantic_alpha":
            item = finding(f"{skill}-{identity}")
            raw_findings.append(item)
            emitted.append(item.finding_id)
        rows.append({
            "work_id": work_id, "record_type": "work_item", "phase": "semantic",
            "analyzer_id": identity, "outcome": "completed", "path": "SKILL.md",
            "start_line": 1, "end_line": 1, "input_finding_ids": [],
            "emitted_finding_ids": emitted,
        })
        statuses.append({
            "analyzer_id": identity, "status": "completed",
            "planned_work": [{"work_id": work_id, "path": "SKILL.md",
                              "start_line": 1, "end_line": 1}],
        })
        calls.append({
            "node": identity, "work_id": work_id, "path": "SKILL.md",
            "start_line": 1, "end_line": 1, "ok": True, "error": None,
        })
    return {
        "execution_successful": True, "use_llm": True,
        "analysis_completeness": {
            "status": "complete", "is_complete": True,
            "execution_successful": True, "ledger_exceptions": [],
            "limitations": [],
        },
        "llm_components": ["SKILL.md"],
        "llm_file_cache": {"SKILL.md": "synthetic input"},
        "analyzer_status_events": statuses,
        "inspection_ledger": rows,
        "llm_call_log": calls,
        "findings": raw_findings,
    }


def invocation() -> dict[str, object]:
    return {
        "candidate_id": "a" * 64,
        "input_inventory_sha256": "b" * 64,
        "provider": "fixture-provider", "purpose": "fixture semantic review",
        "scope": "fixture active skill files",
        "expected_active_skills": ["alpha-skill", "beta-skill"],
        "registered_analyzer_ids": IDS,
        "wired_analyzer_ids": IDS,
        "graphs_by_skill": {
            "alpha-skill": graph_result("alpha-skill"),
            "beta-skill": graph_result("beta-skill", with_finding=False),
        },
    }


def bound_invocation() -> dict[str, object]:
    """Attach two real synthetic package paths and their exact raw source bytes."""
    inputs = invocation()
    source_paths = {}
    source_manifests = {}
    for skill_id, state in inputs["graphs_by_skill"].items():
        package = (FIXTURES / skill_id).resolve(strict=True)
        payload = (package / "SKILL.md").read_bytes()
        state["input_path"] = str(package)
        state["skill_path"] = str(package)
        state["raw_file_cache"] = {"SKILL.md": payload}
        state["llm_file_cache"] = {"SKILL.md": payload.decode("utf-8")}
        source_paths[skill_id] = str(package)
        source_manifests[skill_id] = {
            "SKILL.md": {"sha256": sha256(payload).hexdigest(), "bytes": len(payload)}
        }
    inputs["expected_skill_paths"] = source_paths
    inputs["expected_committed_source_by_skill"] = source_manifests
    inputs["expected_provider_components_by_skill"] = {
        skill_id: ["SKILL.md"] for skill_id in inputs["graphs_by_skill"]
    }
    return inputs


def expected_provider_inventory_digest(inputs: dict[str, object]) -> str:
    rows = []
    for skill_id in sorted(inputs["expected_provider_components_by_skill"]):
        state = inputs["graphs_by_skill"][skill_id]
        for path in sorted(inputs["expected_provider_components_by_skill"][skill_id]):
            payload = state["raw_file_cache"][path]
            text = payload.decode("utf-8", errors="strict")
            rows.append({
                "skillId": skill_id,
                "path": path,
                "sourceSha256": sha256(payload).hexdigest(),
                "sourceBytes": len(payload),
                "transformation": "strict-utf8-v1",
                "providerTextSha256": sha256(text.encode("utf-8")).hexdigest(),
            })
    canonical = json.dumps(rows, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256(canonical.encode("utf-8")).hexdigest()


class RawGraphNormalizationContract(unittest.TestCase):
    # Scenario: Two active Skills have every installed semantic node completed and one raw finding.
    # Purpose: Keep the finding and both Skill coverage rows in the unsigned scanner result.
    def test_UnitT10_preserves_complete_peer_skill_coverage_and_finding(self) -> None:
        inputs = bound_invocation()
        result = module.normalize_candidate_scan(**inputs)
        self.assertEqual(result["activeSkills"], ["alpha-skill", "beta-skill"])
        self.assertEqual([row["identity"] for row in result["analyzers"]], IDS)
        self.assertEqual(result["analyzers"][0]["coveredSkills"], result["activeSkills"])
        self.assertEqual(result["analyzers"][0]["findings"][0]["severity"], "high")
        self.assertEqual(result["analyzers"][1]["findings"], [])
        self.assertEqual(
            result["providerTextInventorySha256"], expected_provider_inventory_digest(inputs)
        )

    # Scenario: A single completed whole-file batch covers every line in a multi-line LLM input.
    # Purpose: Permit full-file work without requiring artificial chunks.
    def test_UnitT15_accepts_full_multiline_work(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / "alpha-skill"
            package.mkdir()
            payload = b"first\nsecond\nthird\n"
            (package / "SKILL.md").write_bytes(payload)
            inputs = bound_invocation()
            state = inputs["graphs_by_skill"]["alpha-skill"]
            state["input_path"] = str(package)
            state["skill_path"] = str(package)
            state["raw_file_cache"]["SKILL.md"] = payload
            state["llm_file_cache"]["SKILL.md"] = payload.decode("utf-8")
            inputs["expected_skill_paths"]["alpha-skill"] = str(package)
            inputs["expected_committed_source_by_skill"]["alpha-skill"]["SKILL.md"] = {
                "sha256": sha256(payload).hexdigest(), "bytes": len(payload)
            }
            for status in state["analyzer_status_events"]:
                status["planned_work"][0]["end_line"] = 3
            for row in state["inspection_ledger"]:
                row["end_line"] = 3
            for call in state["llm_call_log"]:
                call["end_line"] = 3
            result = module.normalize_candidate_scan(**inputs)
            self.assertEqual(result["analyzers"][0]["coveredSkills"], result["activeSkills"])

    # Scenario: The installed registry has two semantic nodes, but the frozen graph wired only one.
    # Purpose: Block scanner normalization despite an otherwise complete static projection.
    def test_UnitT20_rejects_unwired_registered_node(self) -> None:
        inputs = bound_invocation()
        inputs["wired_analyzer_ids"] = ["semantic_alpha"]
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: Each synthetic graph points at its own package and raw byte cache equals the frozen source manifest.
    # Purpose: Allow only a scan input that is associated with the exact active Skill bytes.
    def test_UnitT21_accepts_exact_source_path_and_raw_byte_binding(self) -> None:
        result = module.normalize_candidate_scan(**bound_invocation())
        self.assertEqual(result["activeSkills"], ["alpha-skill", "beta-skill"])

    # Scenario: Verified raw bytes still match the committed source, but the text cache passed to the LLM is replaced.
    # Purpose: Prevent stale or substituted provider input from inheriting the verified candidate identity.
    def test_UnitT22_rejects_llm_text_that_is_not_the_verified_source_bytes(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["llm_file_cache"]["SKILL.md"] = "substituted input"
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: A valid alpha graph is relabelled as beta while the beta expected package path remains frozen.
    # Purpose: Prevent one Skill's scan from claiming another Skill's complete coverage.
    def test_UnitT23_rejects_reused_graph_under_another_skill_key(self) -> None:
        inputs = bound_invocation()
        alpha_path = inputs["graphs_by_skill"]["alpha-skill"]["skill_path"]
        inputs["graphs_by_skill"]["beta-skill"]["input_path"] = alpha_path
        inputs["graphs_by_skill"]["beta-skill"]["skill_path"] = alpha_path
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: The complete committed package contains a PNG that the frozen scanner inventories but does not send to the provider.
    # Purpose: Keep binary assets byte-bound without forcing them into the authenticated provider-text inventory.
    def test_UnitT24_accepts_binary_outside_provider_text_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / "alpha-skill"
            package.mkdir()
            text = (FIXTURES / "alpha-skill" / "SKILL.md").read_bytes()
            binary = b"\x89PNG\r\n\x1a\n\x00fixture-binary"
            (package / "SKILL.md").write_bytes(text)
            (package / "assets.png").write_bytes(binary)
            inputs = bound_invocation()
            state = inputs["graphs_by_skill"]["alpha-skill"]
            state["input_path"] = str(package)
            state["skill_path"] = str(package)
            state["raw_file_cache"] = {"SKILL.md": text, "assets.png": binary}
            inputs["expected_skill_paths"]["alpha-skill"] = str(package)
            inputs["expected_committed_source_by_skill"]["alpha-skill"] = {
                "SKILL.md": {"sha256": sha256(text).hexdigest(), "bytes": len(text)},
                "assets.png": {"sha256": sha256(binary).hexdigest(), "bytes": len(binary)},
            }
            result = module.normalize_candidate_scan(**inputs)
            self.assertRegex(result["providerTextInventorySha256"], r"^[0-9a-f]{64}$")

            inputs["expected_provider_components_by_skill"]["alpha-skill"].append("assets.png")
            state["llm_components"].append("assets.png")
            state["llm_file_cache"]["assets.png"] = "misclassified binary"
            with self.assertRaisesRegex(ValueError, "strict UTF-8"):
                module.normalize_candidate_scan(**inputs)

    # Scenario: A raw cached file differs by one byte from the exact committed source manifest.
    # Purpose: Stop source transformations that would otherwise inherit the wrong immutable candidate SHA.
    def test_UnitT25_rejects_changed_raw_source_byte(self) -> None:
        inputs = bound_invocation()
        state = inputs["graphs_by_skill"]["alpha-skill"]
        state["raw_file_cache"]["SKILL.md"] += b"x"
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: Raw byte provenance includes a second committed file while the LLM cache silently contains only SKILL.md.
    # Purpose: Require the provider's applicable file set to cover every reviewed source file.
    def test_UnitT26_rejects_committed_file_missing_from_llm_scope(self) -> None:
        extra = FIXTURES / "alpha-skill" / "additional.md"
        self.assertFalse(extra.exists())
        payload = b"synthetic additional source\n"
        extra.write_bytes(payload)
        try:
            inputs = bound_invocation()
            inputs["expected_committed_source_by_skill"]["alpha-skill"]["additional.md"] = {
                "sha256": sha256(payload).hexdigest(), "bytes": len(payload)
            }
            inputs["graphs_by_skill"]["alpha-skill"]["raw_file_cache"]["additional.md"] = payload
            inputs["expected_provider_components_by_skill"]["alpha-skill"].append("additional.md")
            with self.assertRaises(ValueError):
                module.normalize_candidate_scan(**inputs)
        finally:
            extra.unlink(missing_ok=True)

    # Scenario: A graph has completed work for its LLM path but omits that file from its raw source cache.
    # Purpose: Require complete byte provenance before accepting semantic coverage.
    def test_UnitT27_rejects_missing_raw_source_file(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["raw_file_cache"].clear()
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: The graph raw cache includes an extra file that is absent from the reviewed committed package scope.
    # Purpose: Prevent unreviewed input bytes from entering the candidate scan result.
    def test_UnitT28_rejects_unscoped_raw_source_file(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["raw_file_cache"]["extra.md"] = b"extra"
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: One expected active Skill has no source manifest even though a graph result is present.
    # Purpose: Refuse a caller-declared complete result without per-Skill immutable source identity.
    def test_UnitT29_rejects_missing_frozen_skill_manifest(self) -> None:
        inputs = bound_invocation()
        inputs["expected_committed_source_by_skill"].pop("beta-skill")
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: The graph reports global complete but omits one semantic status event.
    # Purpose: Require actual per-analyzer execution evidence.
    def test_UnitT30_rejects_missing_semantic_status(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["analyzer_status_events"].pop()
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: One planned semantic batch has a partial terminal outcome.
    # Purpose: Stop a result that lost part of the approved scan scope.
    def test_UnitT40_rejects_partial_work(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["inspection_ledger"][0]["outcome"] = "partial"
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: Completed chunks cover lines 1 and 3 of a three-line file but omit line 2.
    # Purpose: Refuse falsely complete planned work when the graph silently lost a range.
    def test_UnitT45_rejects_gap_between_completed_chunks(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / "alpha-skill"
            package.mkdir()
            payload = b"first\nsecond\nthird\n"
            (package / "SKILL.md").write_bytes(payload)
            inputs = bound_invocation()
            state = inputs["graphs_by_skill"]["alpha-skill"]
            state["input_path"] = str(package)
            state["skill_path"] = str(package)
            state["raw_file_cache"]["SKILL.md"] = payload
            state["llm_file_cache"]["SKILL.md"] = payload.decode("utf-8")
            inputs["expected_skill_paths"]["alpha-skill"] = str(package)
            inputs["expected_committed_source_by_skill"]["alpha-skill"]["SKILL.md"] = {
                "sha256": sha256(payload).hexdigest(), "bytes": len(payload)
            }
            for status, row in zip(state["analyzer_status_events"], state["inspection_ledger"]):
                status["planned_work"][0].update({"start_line": 1, "end_line": 1})
                row.update({"start_line": 1, "end_line": 1})
                target = dict(status["planned_work"][0])
                target.update({"work_id": target["work_id"] + "-third", "start_line": 3, "end_line": 3})
                status["planned_work"].append(target)
                terminal = dict(row)
                terminal.update({"work_id": target["work_id"], "start_line": 3,
                                 "end_line": 3, "emitted_finding_ids": []})
                state["inspection_ledger"].append(terminal)
            with self.assertRaisesRegex(ValueError, "chunks omit"):
                module.normalize_candidate_scan(**inputs)

    # Scenario: One analyzer plans and completes two chunks but records a provider call for only the first.
    # Purpose: Prevent a completed work row from inheriting another chunk's successful provider telemetry.
    def test_UnitT47_rejects_planned_work_without_its_own_provider_call(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / "alpha-skill"
            package.mkdir()
            payload = b"first\nsecond\n"
            (package / "SKILL.md").write_bytes(payload)
            inputs = bound_invocation()
            state = inputs["graphs_by_skill"]["alpha-skill"]
            state["input_path"] = str(package)
            state["skill_path"] = str(package)
            state["raw_file_cache"]["SKILL.md"] = payload
            state["llm_file_cache"]["SKILL.md"] = payload.decode("utf-8")
            inputs["expected_skill_paths"]["alpha-skill"] = str(package)
            inputs["expected_committed_source_by_skill"]["alpha-skill"]["SKILL.md"] = {
                "sha256": sha256(payload).hexdigest(), "bytes": len(payload)
            }
            for status, row, call in zip(
                state["analyzer_status_events"], state["inspection_ledger"], state["llm_call_log"]
            ):
                status["planned_work"][0]["end_line"] = 2
                row["end_line"] = 2
                call["end_line"] = 2
            first_status = state["analyzer_status_events"][0]
            first_row = state["inspection_ledger"][0]
            first_call = state["llm_call_log"][0]
            first_status["planned_work"][0]["end_line"] = 1
            first_row["end_line"] = 1
            first_call["end_line"] = 1
            second_work = dict(first_status["planned_work"][0])
            second_work.update({"work_id": second_work["work_id"] + "-second",
                                "start_line": 2, "end_line": 2})
            first_status["planned_work"].append(second_work)
            second_row = dict(first_row)
            second_row.update({"work_id": second_work["work_id"], "start_line": 2,
                               "end_line": 2, "emitted_finding_ids": []})
            state["inspection_ledger"].append(second_row)
            with self.assertRaisesRegex(ValueError, "provider call"):
                module.normalize_candidate_scan(**inputs)

    # Scenario: One analyzer scans two files, but a finding emitted by the first work row names the second file.
    # Purpose: Bind every normalized finding path to the exact provider work item that produced it.
    def test_UnitT48_rejects_finding_path_different_from_producer_work(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            package = Path(root) / "alpha-skill"
            package.mkdir()
            skill_payload = (FIXTURES / "alpha-skill" / "SKILL.md").read_bytes()
            payload = b"additional semantic input\n"
            (package / "SKILL.md").write_bytes(skill_payload)
            (package / "additional.md").write_bytes(payload)
            inputs = bound_invocation()
            state = inputs["graphs_by_skill"]["alpha-skill"]
            state["input_path"] = str(package)
            state["skill_path"] = str(package)
            state["raw_file_cache"]["SKILL.md"] = skill_payload
            state["raw_file_cache"]["additional.md"] = payload
            state["llm_components"].append("additional.md")
            state["llm_file_cache"]["additional.md"] = payload.decode("utf-8")
            inputs["expected_skill_paths"]["alpha-skill"] = str(package)
            inputs["expected_provider_components_by_skill"]["alpha-skill"].append("additional.md")
            inputs["expected_committed_source_by_skill"]["alpha-skill"]["additional.md"] = {
                "sha256": sha256(payload).hexdigest(), "bytes": len(payload)
            }
            for status, row, call in zip(
                state["analyzer_status_events"], state["inspection_ledger"], state["llm_call_log"]
            ):
                second_work = dict(status["planned_work"][0])
                second_work.update({"work_id": second_work["work_id"] + "-additional",
                                    "path": "additional.md"})
                status["planned_work"].append(second_work)
                second_row = dict(row)
                second_row.update({"work_id": second_work["work_id"], "path": "additional.md",
                                   "emitted_finding_ids": []})
                state["inspection_ledger"].append(second_row)
                second_call = dict(call)
                second_call.update({"work_id": second_work["work_id"], "path": "additional.md"})
                state["llm_call_log"].append(second_call)
            state["findings"][0].file = "additional.md"
            with self.assertRaisesRegex(ValueError, "producer work path"):
                module.normalize_candidate_scan(**inputs)

    # Scenario: One analyzer's LLM call failed after its work row claimed complete.
    # Purpose: Reconcile provider telemetry with work accounting.
    def test_UnitT50_rejects_failed_provider_call(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["llm_call_log"][0]["ok"] = False
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: A raw finding has no unique producer ledger row.
    # Purpose: Prevent reporting only the subset that can be attributed to an analyzer.
    def test_UnitT60_rejects_unaccounted_raw_finding(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["findings"].append(finding("orphan"))
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: Two work rows claim one raw finding ID.
    # Purpose: Reject ambiguous finding provenance rather than arbitrarily choosing an analyzer.
    def test_UnitT70_rejects_duplicate_finding_producer(self) -> None:
        inputs = bound_invocation()
        rows = inputs["graphs_by_skill"]["alpha-skill"]["inspection_ledger"]
        rows[1]["emitted_finding_ids"] = rows[0]["emitted_finding_ids"][:]
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: One expected active Skill has no graph invocation result.
    # Purpose: Keep an earlier candidate or partial batch from claiming full Skill coverage.
    def test_UnitT80_rejects_missing_skill_result(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"].pop("beta-skill")
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)

    # Scenario: An output-bound ledger system row appears alongside all complete semantic rows.
    # Purpose: Refuse a graph whose raw ledger or findings may have been truncated.
    def test_UnitT90_rejects_output_limit(self) -> None:
        inputs = bound_invocation()
        inputs["graphs_by_skill"]["alpha-skill"]["inspection_ledger"].append({
            "work_id": "output-limit", "record_type": "system", "phase": "ledger_output",
            "outcome": "partial", "reason_code": "output_limit",
            "path": "SKILL.md", "emitted_finding_ids": [],
        })
        with self.assertRaises(ValueError):
            module.normalize_candidate_scan(**inputs)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--emit-fixture":
        result = module.normalize_candidate_scan(**bound_invocation())
        with Path(sys.argv[2]).open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(result, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    else:
        unittest.main()
