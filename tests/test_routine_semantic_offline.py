"""Development-only offline routine semantic receipt contract tests."""

from __future__ import annotations

import base64
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "routine_semantic_offline.py"
ENTRYPOINT = Path(__file__).resolve().parents[1] / "scripts" / "Invoke-RoutineSemanticScan.ps1"
ANALYZERS = (
    "semantic_developer_intent",
    "semantic_quality_policy",
    "semantic_security_discovery",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def payload(text: str) -> tuple[str, str]:
    data = text.encode("utf-8")
    return base64.b64encode(data).decode("ascii"), digest(data)


class RoutineSemanticOfflineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plan_path = self.root / "consumer-plan.json"
        self.prepared_path = self.root / "prepared-plan.json"
        self.bundle_path = self.root / "synthetic-bundle.json"
        self.output_path = self.root / "verified.json"
        self.consumer = {
            "schemaVersion": 1,
            "artifactType": "standard-validation-consumer-run-plan-v1",
            "runId": "a" * 32,
            "source": {"repository": "https://example.test/repo.git", "revision": "b" * 40},
            "candidate": {"candidateId": "c" * 64, "contentSha256": "d" * 64},
        }
        self.plan_path.write_text(json.dumps(self.consumer), encoding="utf-8")
        file = {"path": "skills/example/SKILL.md", "gitBlobSha1": "e" * 40, "bytes": 7, "sha256": "f" * 64}
        inventory_text = "\n".join(("routine-semantic-git-inventory-v1", self.consumer["source"]["revision"], f'{file["path"]}\t{file["gitBlobSha1"]}\t{file["bytes"]}\t{file["sha256"]}'))
        inventory_sha = digest(inventory_text.encode("utf-8"))
        self.producer = {
            "schemaVersion": 1,
            "artifactType": "routine-semantic-prepared-plan-v1",
            "candidateId": "1" * 64,
            "authority": {"repository": self.consumer["source"]["repository"], "sourceRevision": self.consumer["source"]["revision"], "root": None, "rootIsTrustedInput": False},
            "sourceInventory": {"sourceRevision": self.consumer["source"]["revision"], "files": [file], "sourceBytes": 7, "inputInventorySha256": inventory_sha},
            "decision": {"candidateId": "1" * 64, "inputInventorySha256": inventory_sha, "status": "PREPARED_FIXTURE_ONLY", "scopeAllowed": True, "egressAuthorized": False},
            "consumerBinding": {"runId": self.consumer["runId"], "candidateId": self.consumer["candidate"]["candidateId"], "contentSha256": self.consumer["candidate"]["contentSha256"], "sourceRevision": self.consumer["source"]["revision"], "consumerPlanSha256": digest(self.plan_path.read_bytes())},
            "payloadComplete": False,
            "scanStatus": "NOT_RUN",
            "ciAdmission": "BLOCKED",
            "releaseEligible": False,
        }
        self.bundle = {
            "schemaVersion": 1,
            "artifactType": "routine-semantic-synthetic-bundle-v1",
            "consumerPlanSha256": digest(self.plan_path.read_bytes()),
            "producerPlan": self.producer,
            "requiredAnalyzerIds": list(ANALYZERS),
            "workItems": [],
        }
        self.prepared_path.write_text(json.dumps(self.producer), encoding="utf-8")
        for analyzer in ANALYZERS:
            work_id = digest((analyzer + "\n" + file["path"] + "\n" + file["sha256"]).encode())
            prompt64, prompt_sha = payload("synthetic prompt for " + analyzer)
            response64, response_sha = payload("synthetic response for " + analyzer)
            graph64, graph_sha = payload(json.dumps({"artifactType": "synthetic-raw-graph-v1", "workItemId": work_id, "analyzerId": analyzer}))
            findings64, findings_sha = payload(json.dumps({"workItemId": work_id, "findings": []}))
            self.bundle["workItems"].append({
                "id": work_id, "analyzerId": analyzer, "path": file["path"], "selectedBlobSha256": file["sha256"],
                "promptBase64": prompt64, "promptSha256": prompt_sha,
                "responseBase64": response64, "responseSha256": response_sha,
                "rawGraphBase64": graph64, "rawGraphSha256": graph_sha,
                "rawFindingsBase64": findings64, "rawFindingsSha256": findings_sha,
            })

    def verify(self, bundle=None, consumer=None):
        self.plan_path.write_text(json.dumps(consumer or self.consumer), encoding="utf-8")
        self.bundle_path.write_text(json.dumps(bundle or self.bundle), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(SCRIPT), "verify", "--plan", str(self.plan_path), "--prepared", str(self.prepared_path), "--bundle", str(self.bundle_path), "--output", str(self.output_path)],
            capture_output=True, text=True, timeout=20,
        )

    # Scenario: A complete synthetic ledger binds both consumer and producer candidate namespaces.
    # Purpose: Offline integration can verify all raw work without claiming a real semantic scan.
    def test_InterT10_verifies_complete_synthetic_bundle_with_dual_identity(self):
        result = self.verify()
        self.assertEqual(0, result.returncode, result.stderr)
        verified = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual(self.consumer["candidate"]["candidateId"], verified["candidateId"])
        self.assertEqual(self.producer["candidateId"], verified["producerCandidateId"])
        self.assertEqual("SYNTHETIC", verified["scanStatus"])
        self.assertEqual("BLOCKED", verified["ciAdmission"])
        self.assertEqual(3, verified["plannedWorkItemCount"])
        self.assertFalse(verified["releaseEligible"])

    # Scenario: Every planned work item returns zero findings with complete raw coverage.
    # Purpose: Successful fixture validity stays separate from consent, review, HRA and release.
    def test_InterT12_zero_findings_complete_coverage_keeps_formal_gates_separate(self):
        result = self.verify()
        self.assertEqual(0, result.returncode, result.stderr)
        verified = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual("VERIFIED_FIXTURE_ONLY", verified["semanticValidity"])
        self.assertEqual("complete", verified["coverageStatus"])
        self.assertEqual([], verified["normalizedFindings"])
        self.assertEqual(digest(b"[]"), verified["normalizedFindingsSha256"])
        self.assertEqual(3, len(verified["rawResultBindings"]))
        schema = json.loads((SCRIPT.parents[1] / "tests" / "fixtures" /
                             "routine-semantic-synthetic" / "verification.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(set(schema["properties"]), set(verified))
        self.assertTrue(set(schema["required"]).issubset(verified))
        for key in ("consentGranted", "egressAuthorized", "releaseEligible"):
            self.assertIs(False, verified[key], key)
        for key in ("aiReviewStatus", "dispositionStatus", "humanReleaseApprovalStatus"):
            self.assertEqual("not-evaluated", verified[key], key)
        self.assertEqual("unverified", verified["trustStatus"])
        self.assertEqual("BLOCKED", verified["ciAdmission"])

    # Scenario: A canonical finding belongs to one exact analyzer/path raw result.
    # Purpose: Preserve raw association and schema-valid output without granting admission.
    def test_InterT14_nonempty_findings_retain_exact_raw_result_binding(self):
        bundle = copy.deepcopy(self.bundle)
        work = bundle["workItems"][0]
        finding = {"severity": "low", "fingerprint": "fixture-1", "ruleId": "fixture-rule",
                   "message": "Synthetic finding.", "path": work["path"], "analyzerId": work["analyzerId"]}
        work["rawFindingsBase64"], work["rawFindingsSha256"] = payload(
            json.dumps({"workItemId": work["id"], "findings": [finding]}))
        result = self.verify(bundle)
        self.assertEqual(0, result.returncode, result.stderr)
        verified = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual([finding], verified["normalizedFindings"])
        canonical = {name: finding[name] for name in
                     ("severity", "fingerprint", "ruleId", "message", "path", "analyzerId")}
        self.assertEqual(digest(json.dumps([canonical], ensure_ascii=False, separators=(",", ":")).encode()),
                         verified["normalizedFindingsSha256"])
        binding = verified["rawResultBindings"][0]
        self.assertEqual(work["id"], binding["workItemId"])
        self.assertEqual(1, binding["findingCount"])
        for stem in ("prompt", "response", "rawGraph", "rawFindings"):
            self.assertEqual(work[stem + "Sha256"], binding[stem + "Sha256"])
        self.assertFalse(verified["releaseEligible"])
        # Use PowerShell's real JSON Schema validator; no extra Python package is required.
        schema = SCRIPT.parents[1] / "tests" / "fixtures" / "routine-semantic-synthetic" / "verification.schema.json"
        checker = self.root / "check-schema.ps1"
        checker.write_text("param($ResultPath, $SchemaPath)\n"
                           "if (Test-Json -Json (Get-Content -Raw -LiteralPath $ResultPath) -SchemaFile $SchemaPath) { exit 0 }; exit 10\n",
                           encoding="utf-8")
        command = ["pwsh", "-NoProfile", "-File", str(checker), str(self.output_path), str(schema)]
        accepted = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(0, accepted.returncode, accepted.stderr)
        verified["releaseEligible"] = True
        self.output_path.write_text(json.dumps(verified), encoding="utf-8")
        rejected = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(10, rejected.returncode, rejected.stderr)

    # Scenario: Correctly hashed raw findings contain malformed or out-of-work findings.
    # Purpose: Raw digest validity alone cannot hide invalid normalized schema/type/scope.
    def test_InterT16_rejects_malformed_or_unbound_normalized_findings(self):
        first = self.bundle["workItems"][0]
        valid = {"severity": "low", "fingerprint": "fixture-1", "ruleId": "fixture-rule",
                 "message": "Synthetic finding.", "path": first["path"], "analyzerId": first["analyzerId"]}
        invalid = [None, 1, "finding", [], {}, {**valid, "severity": "LOW"},
                   {**valid, "message": True}, {**valid, "message": "bad\nmessage"},
                   {**valid, "path": "skills/other/SKILL.md"},
                   {**valid, "analyzerId": ANALYZERS[1]}, {**valid, "override": True}]
        for finding in invalid:
            with self.subTest(finding=finding):
                self.output_path.unlink(missing_ok=True)
                bundle = copy.deepcopy(self.bundle)
                work = bundle["workItems"][0]
                work["rawFindingsBase64"], work["rawFindingsSha256"] = payload(
                    json.dumps({"workItemId": work["id"], "findings": [finding]}))
                result = self.verify(bundle)
                self.assertEqual(10, result.returncode, result.stderr)
                self.assertFalse(self.output_path.exists())

    # Scenario: The bundle changes either identity, the selected blob, or a raw payload hash.
    # Purpose: A caller cannot replay or mix candidate and work evidence.
    def test_InterT20_rejects_candidate_blob_and_raw_hash_mismatch(self):
        for change in ("consumer", "producer", "blob", "raw"):
            bundle = copy.deepcopy(self.bundle)
            if change == "consumer":
                bundle["producerPlan"]["consumerBinding"]["candidateId"] = "9" * 64
            elif change == "producer":
                bundle["producerPlan"]["decision"]["candidateId"] = "9" * 64
            elif change == "blob":
                bundle["workItems"][0]["selectedBlobSha256"] = "9" * 64
            else:
                bundle["workItems"][0]["responseSha256"] = "9" * 64
            result = self.verify(bundle)
            self.assertNotEqual(0, result.returncode, change)
            self.assertFalse(self.output_path.exists(), change)

    # Scenario: An analyzer or one planned work item is missing.
    # Purpose: Partial synthetic graph coverage cannot produce a verified ledger.
    def test_InterT30_rejects_missing_analyzer_or_work_item(self):
        for change in ("analyzer", "work"):
            bundle = copy.deepcopy(self.bundle)
            if change == "analyzer":
                bundle["requiredAnalyzerIds"].pop()
            else:
                bundle["workItems"].pop()
            result = self.verify(bundle)
            self.assertEqual(10, result.returncode, change)
            self.assertIn("ANALYZER_SET_INCOMPLETE" if change == "analyzer" else "WORK_COUNT_INCOMPLETE", result.stderr)
            self.assertFalse(self.output_path.exists(), change)

    # Scenario: A second consumer plan with another run ID reuses the earlier bundle.
    # Purpose: The verifier rejects replay against another protected run.
    def test_InterT40_rejects_replay_against_new_consumer_plan(self):
        changed = copy.deepcopy(self.consumer)
        changed["runId"] = "8" * 32
        result = self.verify(consumer=changed)
        self.assertNotEqual(0, result.returncode)

    # Scenario: The protected consumer invokes the central PowerShell CLI, not the Python helper directly.
    # Purpose: The published Verify entrypoint produces the same blocked synthetic result.
    def test_InterT50_central_powershell_verify_entrypoint_runs(self):
        self.bundle_path.write_text(json.dumps(self.bundle), encoding="utf-8")
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ENTRYPOINT), "-Mode", "Verify", "-PlanPath", str(self.plan_path), "-PreparedPath", str(self.prepared_path), "-BundlePath", str(self.bundle_path), "-OutputPath", str(self.output_path)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("BLOCKED", json.loads(self.output_path.read_text(encoding="utf-8"))["ciAdmission"])

    # Scenario: Each file passed to public Verify is independently missing or replaced.
    # Purpose: Prove plan/prepared/bundle/output forwarding and fail-closed type validation.
    def test_InterT55_public_verify_forwards_all_files_and_rejects_invalid_inputs(self):
        self.bundle_path.write_text(json.dumps(self.bundle), encoding="utf-8")
        command = ["pwsh", "-NoProfile", "-File", str(ENTRYPOINT), "-Mode", "Verify",
                   "-PlanPath", str(self.plan_path), "-PreparedPath", str(self.prepared_path),
                   "-BundlePath", str(self.bundle_path), "-OutputPath", str(self.output_path)]
        for label, changed in (("plan", self.plan_path), ("prepared", self.prepared_path),
                               ("bundle", self.bundle_path)):
            with self.subTest(missing=label):
                original = changed.read_bytes()
                changed.unlink()
                try:
                    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                    self.assertEqual(10, result.returncode, result.stderr)
                    self.assertIn("MISSING_OR_UNSAFE", result.stderr)
                    self.assertFalse(self.output_path.exists())
                finally:
                    changed.write_bytes(original)
        for label, changed, value, code in (
            ("plan-type", self.plan_path, {**self.consumer, "schemaVersion": True}, "CONSUMER_VERSION"),
            ("bundle-type", self.bundle_path, {**self.bundle, "schemaVersion": True}, "BUNDLE_VERSION"),
            ("prepared", self.prepared_path, {}, "PREPARED_PLAN_MISMATCH"),
        ):
            with self.subTest(substitution=label):
                original = changed.read_bytes()
                changed.write_text(json.dumps(value), encoding="utf-8")
                try:
                    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                    self.assertEqual(10, result.returncode, result.stderr)
                    self.assertIn(code, result.stderr)
                    self.assertFalse(self.output_path.exists())
                finally:
                    changed.write_bytes(original)

    # Scenario: A signed-looking JSON bundle repeats a decoded key or drops raw graph bytes.
    # Purpose: JSON parser ambiguity and hidden raw-work omissions fail before a result is written.
    def test_InterT60_rejects_duplicate_keys_and_missing_raw_graph(self):
        self.bundle_path.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
        duplicate = subprocess.run(
            [sys.executable, str(SCRIPT), "verify", "--plan", str(self.plan_path), "--prepared", str(self.prepared_path), "--bundle", str(self.bundle_path), "--output", str(self.output_path)],
            capture_output=True, text=True, timeout=20,
        )
        self.assertNotEqual(0, duplicate.returncode)
        self.assertIn("BUNDLE_DUPLICATE_PROPERTY", duplicate.stderr)
        self.assertFalse(self.output_path.exists())
        bundle = copy.deepcopy(self.bundle)
        del bundle["workItems"][0]["rawGraphBase64"]
        missing = self.verify(bundle)
        self.assertNotEqual(0, missing.returncode)
        self.assertIn("WORK_FIELDS", missing.stderr)
        self.assertFalse(self.output_path.exists())

    # Scenario: The CLI Prepare entrypoint is called without the explicit fixture boundary.
    # Purpose: No ordinary caller can convert this local fixture into a production decision.
    def test_InterT70_prepare_production_mode_fails_closed(self):
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ENTRYPOINT), "-Mode", "Prepare", "-PlanPath", str(self.plan_path), "-OutputPath", str(self.output_path)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("TRUST_POLICY_REVIEW_REQUIRED", result.stderr)
        self.assertFalse(self.output_path.exists())

    # Scenario: The bundle embeds a producer plan different from the saved Prepare output.
    # Purpose: Offline Verify must consume the actual prepared artifact, including its trust decision.
    def test_InterT80_rejects_missing_or_substituted_prepared_plan(self):
        self.bundle_path.write_text(json.dumps(self.bundle), encoding="utf-8")
        self.prepared_path.unlink()
        missing = self.verify()
        self.assertNotEqual(0, missing.returncode)
        self.assertFalse(self.output_path.exists())
        changed = copy.deepcopy(self.producer)
        changed["decision"]["egressAuthorized"] = True
        self.prepared_path.write_text(json.dumps(changed), encoding="utf-8")
        substituted = self.verify()
        self.assertNotEqual(0, substituted.returncode)
        self.assertIn("PREPARED_PLAN_MISMATCH", substituted.stderr)
        self.assertFalse(self.output_path.exists())

    # Scenario: A caller omits the saved Prepare output from the public Verify entrypoint.
    # Purpose: The wrapper cannot silently fall back to the bundle's self-asserted plan.
    def test_InterT90_entrypoint_requires_prepared_plan(self):
        self.bundle_path.write_text(json.dumps(self.bundle), encoding="utf-8")
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ENTRYPOINT), "-Mode", "Verify", "-PlanPath", str(self.plan_path), "-BundlePath", str(self.bundle_path), "-OutputPath", str(self.output_path)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("PREPARED_MISSING", result.stderr)
        self.assertFalse(self.output_path.exists())

    # Scenario: A fixture issuer changes both saved plan and bundle consistently.
    # Purpose: Even a matching fixture cannot claim provider egress or CI admission.
    def test_InterT100_matching_fixture_cannot_promote(self):
        changed = copy.deepcopy(self.producer)
        changed["decision"]["egressAuthorized"] = True
        self.prepared_path.write_text(json.dumps(changed), encoding="utf-8")
        bundle = copy.deepcopy(self.bundle)
        bundle["producerPlan"] = changed
        result = self.verify(bundle)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("FIXTURE_DECISION_REQUIRED", result.stderr)
        self.assertFalse(self.output_path.exists())


if __name__ == "__main__":
    unittest.main()
