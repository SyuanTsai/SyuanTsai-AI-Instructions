"""Failure boundaries for the offline routine semantic candidate preflight."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from routine_semantic_candidate import CandidateError, preflight  # noqa: E402
from routine_semantic_fake_graph import FakeProvider, capture_graph_state  # noqa: E402
from routine_semantic_inactive_receipt import verify_inactive  # noqa: E402


class RoutineSemanticCandidateTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        source = self.repo / "skills" / "example" / "SKILL.md"
        source.parent.mkdir(parents=True)
        source.write_text("---\nname: example\ndescription: Synthetic.\n---\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", "skills"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "fixture"], check=True)
        self.revision = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        blob = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD:skills/example/SKILL.md"], text=True).strip()
        body = subprocess.check_output(["git", "-C", str(self.repo), "cat-file", "blob", blob])
        self.inventory = self.root / "inventory.json"
        self.inventory.write_text(json.dumps({"candidate": self.revision, "items": [{"path": "skills/example/SKILL.md", "gitBlobSha1": blob, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(), "changed": True, "skillInstructions": True}]}), encoding="utf-8")
        self.prompts = self.root / "prompts"
        self.prompts.mkdir()
        self.calls = []
        for analyzer in ("semantic_developer_intent", "semantic_quality_policy", "semantic_security_discovery"):
            data = ("Synthetic prompt\n## File: SKILL.md\n" + analyzer + "\n").encode()
            name = analyzer + ".txt"
            (self.prompts / name).write_bytes(data)
            self.calls.append({"file": name, "skill": "example", "analyzerId": analyzer, "promptSha256": hashlib.sha256(data).hexdigest(), "promptBytes": len(data), "model": "z-ai/glm-5.2", "maxOutputTokensRequested": 32000})
        self.manifest = {"schemaVersion": 1, "sourceRevision": self.revision, "sourceInventorySha256": hashlib.sha256(self.inventory.read_bytes()).hexdigest(), "sourceFileCount": 1, "sourceBytes": len(body), "promptCandidates": self.calls, "realProviderCalls": 0, "egressAuthorized": False}
        self.write_manifest()

    def write_manifest(self):
        (self.prompts / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def test_UnitT10_preflight_blocks_insufficient_call_budget_before_execution(self):
        # Scenario: all three synthetic analyzer prompts exist, but the run allows two calls.
        # Purpose: a partial scan must not be reported as complete or authorized.
        result = preflight(self.inventory, self.prompts, self.repo, maximum_calls=2)
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(result["requiredCalls"], 3)
        self.assertEqual(result["callShortfall"], 1)
        self.assertFalse(result["egressAuthorized"])

    def test_UnitT20_fake_only_candidate_requires_exact_three_analyzer_coverage(self):
        # Scenario: the same complete synthetic prompt set is reviewed with capacity for three.
        # Purpose: capacity changes must remain offline and retain complete per-file coverage.
        result = preflight(self.inventory, self.prompts, self.repo, maximum_calls=3)
        self.assertEqual(result["status"], "READY_FAKE_ONLY")
        self.assertEqual(len(result["calls"]), 3)
        self.assertFalse(result["egressAuthorized"])
        self.assertFalse(result["releaseEligible"])

    def test_UnitT30_missing_or_duplicate_prompt_fails_closed(self):
        # Scenario: a selected analyzer prompt disappears or is repeated in the manifest.
        # Purpose: no missing coverage or replay can be accepted as a complete candidate.
        (self.prompts / self.calls[0]["file"]).unlink()
        with self.assertRaises(CandidateError):
            preflight(self.inventory, self.prompts, self.repo, maximum_calls=3)
        data = ("Synthetic prompt\n## File: SKILL.md\n" + self.calls[0]["analyzerId"] + "\n").encode()
        (self.prompts / self.calls[0]["file"]).write_bytes(data)
        self.manifest["promptCandidates"].append(dict(self.calls[0]))
        self.write_manifest()
        with self.assertRaises(CandidateError):
            preflight(self.inventory, self.prompts, self.repo, maximum_calls=4)

    def test_UnitT40_mutated_prompt_or_uncommitted_source_fails_closed(self):
        # Scenario: a prompt hash or inventory blob no longer matches the immutable commit.
        # Purpose: all inputs must be bound to exact reviewed bytes.
        (self.prompts / self.calls[0]["file"]).write_text("changed", encoding="utf-8")
        with self.assertRaises(CandidateError):
            preflight(self.inventory, self.prompts, self.repo, maximum_calls=3)
        self.manifest["promptCandidates"][0]["promptSha256"] = hashlib.sha256(b"changed").hexdigest()
        self.manifest["promptCandidates"][0]["promptBytes"] = len(b"changed")
        self.write_manifest()
        with self.assertRaises(CandidateError):
            preflight(self.inventory, self.prompts, self.repo, maximum_calls=3)

    def test_UnitT50_fake_provider_rejects_timeout_route_and_call_overrun(self):
        # Scenario: a fake call exceeds time, model, or call-count bounds.
        # Purpose: even diagnostic execution must stop before accepting extra work.
        provider = FakeProvider(1)
        with self.assertRaises(CandidateError):
            provider.complete("synthetic", model="gpt-5.6-sol", timeout=181)
        with self.assertRaises(CandidateError):
            provider.complete("synthetic", model="other")
        provider.complete("synthetic", model="gpt-5.6-sol", timeout=1)
        self.assertEqual(len(provider.calls), 1)
        with self.assertRaises(CandidateError):
            provider.complete("extra", model="gpt-5.6-sol", timeout=1)

    def test_UnitT60_raw_graph_retains_suppressed_disposition(self):
        # Scenario: report state has a finding removed from its visible filtered set.
        # Purpose: raw and suppressed records must remain available for review.
        state = {"findings": [{"finding_id": "synthetic-1"}], "filtered_findings": [],
                 "suppressed_findings": [{"finding_id": "synthetic-1", "reason": "synthetic baseline"}],
                 "analysis_completeness": {"is_complete": True}, "execution_successful": True}
        graph = capture_graph_state(state, "example", self.revision, 3)
        self.assertEqual(graph["rawFindings"], [{"finding_id": "synthetic-1"}])
        self.assertEqual(graph["suppressedFindings"], [{"finding_id": "synthetic-1", "reason": "synthetic baseline"}])
        self.assertEqual(graph["filteredFindings"], [])

    def test_UnitT70_unlisted_prompt_directory_entry_fails_closed(self):
        # Scenario: a file not listed in the signed-off local prompt manifest appears.
        # Purpose: no unreviewed prompt or sidecar can be silently included.
        (self.prompts / "extra.txt").write_text("synthetic extra", encoding="utf-8")
        with self.assertRaises(CandidateError):
            preflight(self.inventory, self.prompts, self.repo, maximum_calls=3)

    def build_fake_receipt(self):
        prepared = preflight(self.inventory, self.prompts, self.repo, maximum_calls=3)
        preflight_path = self.root / "preflight.json"
        preflight_path.write_text(json.dumps(prepared), encoding="utf-8")
        graph_dir = self.root / "graph"
        graph_dir.mkdir()
        response = FakeProvider.RESPONSE
        calls = []
        for number, call in enumerate(prepared["calls"], 1):
            data = (self.prompts / call["promptFile"]).read_bytes()
            name = f"prompt-{number:03d}.txt"
            (graph_dir / name).write_bytes(data)
            calls.append({"sequence": number, "promptSha256": call["promptSha256"],
                          "promptBytes": len(data), "responseSha256": hashlib.sha256(response).hexdigest(),
                          "responseBytes": len(response), "model": "gpt-5.6-sol",
                          "maximumOutputTokens": 2048, "timeoutSecondsRequested": 1,
                          "status": "FAKE_RESPONSE", "analyzerId": call["analyzerId"],
                          "sourcePath": call["sourcePath"], "sourceSha256": call["sourceSha256"],
                          "rawPromptFile": name, "responseBase64": __import__("base64").b64encode(response).decode("ascii")})
        graph = {"skill": "example", "sourceRevision": self.revision, "calls": 3,
                 "analyzerStatusEvents": [{"analyzer_id": a, "status": "completed"} for a in ("semantic_developer_intent", "semantic_quality_policy", "semantic_security_discovery")],
                 "analysisCompleteness": {"is_complete": True}, "executionSuccessful": True,
                 "inspectionLedger": [{"synthetic": True}], "rawFindings": [{"finding_id": "synthetic-1"}],
                 "filteredFindings": [], "suppressedFindings": [{"finding_id": "synthetic-1", "reason": "synthetic"}],
                 "llmCallLog": [], "reportBody": "Synthetic only"}
        raw = json.dumps(graph).encode()
        (graph_dir / "graph-example.json").write_bytes(raw)
        manifest = {"schemaVersion": 1, "artifactType": "routine-semantic-fake-graph-v1",
                    "sourceRevision": self.revision, "preflightPromptManifestSha256": prepared["promptManifestSha256"],
                    "requiredCalls": 3, "actualFakeCalls": 3, "maximumCalls": 3,
                    "promptSetExact": True, "graphComplete": True,
                    "graphs": [{"skill": "example", "file": "graph-example.json", "sha256": hashlib.sha256(raw).hexdigest(),
                                "rawFindings": 1, "filteredFindings": 0, "suppressedFindings": 1, "analysisComplete": True}],
                    "calls": calls, "realProviderCalls": 0, "egressAuthorized": False,
                    "ciAdmission": "BLOCKED", "releaseEligible": False, "status": "FAKE_COMPLETE"}
        (graph_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return preflight_path, graph_dir

    def test_UnitT80_inactive_receipt_binds_all_raw_graph_and_suppressed_findings(self):
        # Scenario: complete fake calls and a suppressed synthetic finding are retained.
        # Purpose: the transport candidate binds all evidence while keeping admission blocked.
        preflight_path, graph_dir = self.build_fake_receipt()
        result = verify_inactive(preflight_path, graph_dir)
        self.assertEqual(result["verifiedFakeCalls"], 3)
        self.assertEqual(result["suppressedFindings"], 1)
        self.assertEqual(result["ciAdmission"], "BLOCKED")
        self.assertFalse(result["releaseEligible"])

    def test_UnitT90_inactive_receipt_rejects_tampered_response_and_graph(self):
        # Scenario: a raw response or graph changes after the fake run.
        # Purpose: the candidate must not create an apparently complete receipt.
        preflight_path, graph_dir = self.build_fake_receipt()
        manifest_path = graph_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        original = manifest_path.read_text()
        manifest["calls"][0]["responseBase64"] = "e30="
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaises(CandidateError):
            verify_inactive(preflight_path, graph_dir)
        manifest_path.write_text(original, encoding="utf-8")
        graph_path = graph_dir / "graph-example.json"
        graph_path.write_bytes(graph_path.read_bytes() + b"\n")
        with self.assertRaises(CandidateError):
            verify_inactive(preflight_path, graph_dir)


if __name__ == "__main__":
    unittest.main()
