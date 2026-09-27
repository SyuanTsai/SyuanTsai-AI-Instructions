"""Offline stub-ledger to existing synthetic-bundle binding tests."""

import base64
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))
from routine_semantic_ledger_bridge import bridge  # noqa: E402
from routine_semantic_provider_invocation import (  # noqa: E402
    DESTINATION, PURPOSE, DATA_CATEGORY, MAX_OUTPUT_TOKENS,
    OfflineResponsesStub, canonical, digest,
)
import test_routine_semantic_offline as fixture_module  # noqa: E402


class LedgerBridgeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture_module.RoutineSemanticOfflineTests(
            "test_InterT10_verifies_complete_synthetic_bundle_with_dual_identity")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.consumer = self.fixture.consumer
        self.bundle = copy.deepcopy(self.fixture.bundle)
        calls = []
        for sequence, item in enumerate(self.bundle["workItems"], 1):
            prompt = base64.b64decode(item["promptBase64"])
            body = canonical({"model": "candidate-model",
                "input": [{"role": "user", "content": [{"type": "input_text",
                    "text": prompt.decode("utf-8")}]}],
                "tools": [], "tool_choice": "none", "max_output_tokens": MAX_OUTPUT_TOKENS,
                "truncation": "disabled", "store": False})
            response = OfflineResponsesStub().respond(call_id=item["id"], request_body=body)
            item["responseBase64"] = base64.b64encode(response).decode("ascii")
            item["responseSha256"] = digest(response)
            calls.append({"sequence": sequence, "callId": item["id"],
                "analyzerId": item["analyzerId"], "sourcePath": item["path"],
                "sourceSha256": item["selectedBlobSha256"],
                "promptSha256": item["promptSha256"], "promptBytes": len(prompt),
                "requestBodySha256": digest(body), "requestBodyBytes": len(body),
                "requestBodyBase64": base64.b64encode(body).decode("ascii"),
                "rawResponseSha256": digest(response), "rawResponseBytes": len(response),
                "rawResponseBase64": item["responseBase64"],
                "status": "STUB_RESPONSE_ONLY"})
        self.ledger = {"schemaVersion": 1,
            "artifactType": "routine-semantic-stub-invocation-ledger-v1",
            "status": "STUB_ONLY", "destination": DESTINATION,
            "httpMethodCandidate": "POST", "purpose": PURPOSE,
            "dataCategory": DATA_CATEGORY, "requestedModel": "candidate-model",
            "sourceRevision": self.consumer["source"]["revision"],
            "sourceInventorySha256": "0" * 64, "promptManifestSha256": "0" * 64,
            "preflightSha256": "0" * 64, "maximumCalls": 3, "requestCount": 3,
            "maximumOutputTokensPerCall": MAX_OUTPUT_TOKENS,
            "maximumOutputTokensTotal": 3 * MAX_OUTPUT_TOKENS,
            "requestBodyBytesTotal": sum(x["requestBodyBytes"] for x in calls),
            "rawResponseBytesTotal": sum(x["rawResponseBytes"] for x in calls),
            "calls": calls, "realProviderCalls": 0, "scanExecuted": False,
            "networkTransportPresent": False, "actualOutboundContextVerified": False,
            "modelAvailabilityVerified": False, "credentialAvailableVerified": False,
            "costVerified": False, "egressAuthorized": False,
            "authorizationStatus": "not-evaluated", "trustStatus": "unverified",
            "ciAdmission": "BLOCKED", "releaseEligible": False}

    def convert(self, *, bundle=None, ledger=None):
        consumer_bytes = canonical(self.consumer)
        material = copy.deepcopy(bundle if bundle is not None else self.bundle)
        material["producerPlan"]["consumerBinding"]["consumerPlanSha256"] = digest(consumer_bytes)
        material["consumerPlanSha256"] = digest(consumer_bytes)
        bundle_bytes = canonical(material)
        raw = copy.deepcopy(ledger if ledger is not None else self.ledger)
        ledger_bytes = canonical(raw)
        return bridge(self.consumer, consumer_bytes, material, bundle_bytes, raw, ledger_bytes)

    def test_UnitT10_exact_raw_request_response_work_binding_stays_blocked(self):
        # Scenario: Every stub call has one exact synthetic work item and raw byte match.
        # Purpose: Bind reviewable bytes while retaining an explicit formal admission block.
        result = self.convert()
        self.assertEqual(result["workItemCount"], 3)
        self.assertEqual({x["workItemId"] for x in result["bindings"]},
                         {x["id"] for x in self.bundle["workItems"]})
        self.assertEqual(result["scanStatus"], "SYNTHETIC")
        self.assertEqual(result["realProviderCalls"], 0)
        self.assertFalse(result["graphResponseBindingVerified"])
        self.assertEqual(result["ciAdmission"], "BLOCKED")

    def test_UnitT20_missing_call_or_wrong_raw_response_fails(self):
        # Scenario: One call is removed or the bundle response changes independently.
        # Purpose: Reject partial coverage and cross-ledger response substitution.
        missing = copy.deepcopy(self.ledger)
        missing["calls"].pop()
        missing["requestCount"] = 2
        missing["requestBodyBytesTotal"] = sum(x["requestBodyBytes"] for x in missing["calls"])
        missing["rawResponseBytesTotal"] = sum(x["rawResponseBytes"] for x in missing["calls"])
        missing["maximumOutputTokensTotal"] = 2 * MAX_OUTPUT_TOKENS
        with self.assertRaisesRegex(ValueError, "LEDGER_COVERAGE_INCOMPLETE"):
            self.convert(ledger=missing)
        changed = copy.deepcopy(self.bundle)
        changed["workItems"][0]["responseBase64"] = base64.b64encode(b"changed").decode("ascii")
        changed["workItems"][0]["responseSha256"] = digest(b"changed")
        with self.assertRaisesRegex(ValueError, "LEDGER_WORK_BINDING_MISMATCH"):
            self.convert(bundle=changed)

    def test_UnitT30_changed_prompt_or_work_identity_fails(self):
        # Scenario: An independently changed prompt or selected source path is supplied.
        # Purpose: Prevent a ledger from being attached to another analyzer input.
        changed = copy.deepcopy(self.bundle)
        prompt = b"different synthetic prompt"
        changed["workItems"][0]["promptBase64"] = base64.b64encode(prompt).decode("ascii")
        changed["workItems"][0]["promptSha256"] = digest(prompt)
        with self.assertRaisesRegex(ValueError, "LEDGER_WORK_BINDING_MISMATCH"):
            self.convert(bundle=changed)
        changed = copy.deepcopy(self.ledger)
        changed["calls"][0]["sourcePath"] = "skills/other/SKILL.md"
        with self.assertRaisesRegex(ValueError, "LEDGER_WORK_BINDING_MISMATCH"):
            self.convert(ledger=changed)

    def test_InterT10_cli_writes_blocked_bridge_only(self):
        # Scenario: The CLI receives three valid fixture inputs and a new output path.
        # Purpose: Persist only a synthetic, untrusted bridge artifact.
        consumer_bytes = canonical(self.consumer)
        self.bundle["producerPlan"]["consumerBinding"]["consumerPlanSha256"] = digest(consumer_bytes)
        self.bundle["consumerPlanSha256"] = digest(consumer_bytes)
        plan = self.fixture.root / "bridge-plan.json"
        bundle = self.fixture.root / "bridge-bundle.json"
        ledger = self.fixture.root / "bridge-ledger.json"
        output = self.fixture.root / "bridge-output.json"
        for path, value in ((plan, self.consumer), (bundle, self.bundle), (ledger, self.ledger)):
            path.write_bytes(canonical(value))
        run = subprocess.run([sys.executable, str(ROOT / "scripts" / "routine_semantic_ledger_bridge.py"),
            "--plan", str(plan), "--bundle", str(bundle), "--ledger", str(ledger),
            "--output", str(output)], capture_output=True, text=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["ciAdmission"], "BLOCKED")

    def test_InterT20_cli_rejects_duplicate_ledger_key_without_output(self):
        # Scenario: A ledger repeats its schemaVersion JSON key.
        # Purpose: Refuse ambiguous raw evidence before writing a bridge artifact.
        plan = self.fixture.root / "duplicate-plan.json"
        bundle = self.fixture.root / "duplicate-bundle.json"
        ledger = self.fixture.root / "duplicate-ledger.json"
        output = self.fixture.root / "duplicate-output.json"
        consumer_bytes = canonical(self.consumer)
        self.bundle["producerPlan"]["consumerBinding"]["consumerPlanSha256"] = digest(consumer_bytes)
        self.bundle["consumerPlanSha256"] = digest(consumer_bytes)
        plan.write_bytes(consumer_bytes)
        bundle.write_bytes(canonical(self.bundle))
        ledger.write_bytes(b'{"schemaVersion":1,"schemaVersion":1}')
        run = subprocess.run([sys.executable, str(ROOT / "scripts" / "routine_semantic_ledger_bridge.py"),
            "--plan", str(plan), "--bundle", str(bundle), "--ledger", str(ledger),
            "--output", str(output)], capture_output=True, text=True, timeout=20)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
