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
    invoke_stub_only, verify_stub_ledger,
)
import test_routine_semantic_offline as fixture_module  # noqa: E402
import test_routine_semantic_prompt_envelope as prompt_fixture_module  # noqa: E402
from routine_semantic_offline import verify as verify_bundle  # noqa: E402
from routine_semantic_prompt_envelope import build_envelopes  # noqa: E402


class LedgerBridgeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture_module.RoutineSemanticOfflineTests(
            "test_InterT10_verifies_complete_synthetic_bundle_with_dual_identity")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.consumer = self.fixture.consumer
        self.prepared = copy.deepcopy(self.fixture.producer)
        self.prepared["consumerBinding"]["consumerPlanSha256"] = digest(canonical(self.consumer))
        self.bundle = copy.deepcopy(self.fixture.bundle)
        self.bundle["producerPlan"]["consumerBinding"]["consumerPlanSha256"] = digest(canonical(self.consumer))
        self.bundle["consumerPlanSha256"] = digest(canonical(self.consumer))
        calls = []
        for sequence, item in enumerate(self.bundle["workItems"], 1):
            prompt = base64.b64decode(item["promptBase64"])
            body = canonical({"model": "candidate-model",
                "input": [{"role": "user", "content": [{"type": "input_text",
                    "text": prompt.decode("utf-8")}]}],
                "tools": [], "tool_choice": "none", "max_output_tokens": MAX_OUTPUT_TOKENS,
                "truncation": "disabled", "store": False})
            call_id = digest(f'{item["analyzerId"]}\n{item["path"]}\n{item["promptSha256"]}'.encode())
            response = OfflineResponsesStub().respond(call_id=call_id, request_body=body)
            item["responseBase64"] = base64.b64encode(response).decode("ascii")
            item["responseSha256"] = digest(response)
            calls.append({"sequence": sequence, "callId": call_id,
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

    def convert(self, *, bundle=None, ledger=None, prepared=...):
        consumer_bytes = canonical(self.consumer)
        material = copy.deepcopy(bundle if bundle is not None else self.bundle)
        material["producerPlan"]["consumerBinding"]["consumerPlanSha256"] = digest(consumer_bytes)
        material["consumerPlanSha256"] = digest(consumer_bytes)
        bundle_bytes = canonical(material)
        raw = copy.deepcopy(ledger if ledger is not None else self.ledger)
        ledger_bytes = canonical(raw)
        saved = copy.deepcopy(self.prepared if prepared is ... else prepared)
        return bridge(self.consumer, consumer_bytes, saved, canonical(saved), material, bundle_bytes, raw, ledger_bytes)

    def test_UnitT05_rejects_missing_substituted_or_inconsistent_prepared_plan(self):
        # Scenario: The independent Prepare document is missing, substituted, or disagrees with its raw bytes.
        # Purpose: Keep the ledger bridge on the same mandatory prepared-plan verification boundary.
        changed = copy.deepcopy(self.prepared)
        changed["decision"]["egressAuthorized"] = True
        for saved in (None, changed):
            with self.subTest(saved=saved), self.assertRaisesRegex(ValueError, "PREPARED"):
                self.convert(prepared=saved)
        with self.assertRaisesRegex(ValueError, "PREPARED_PLAN_BYTES_MISMATCH"):
            bridge(self.consumer, canonical(self.consumer), self.prepared, canonical(changed),
                   self.bundle, canonical(self.bundle), self.ledger, canonical(self.ledger))

    def test_UnitT10_exact_raw_request_response_work_binding_stays_blocked(self):
        # Scenario: Every stub call has one exact synthetic work item and raw byte match.
        # Purpose: Bind reviewable bytes while retaining an explicit formal admission block.
        result = self.convert()
        self.assertEqual(result["workItemCount"], 3)
        self.assertEqual({x["workItemId"] for x in result["bindings"]},
                         {x["id"] for x in self.bundle["workItems"]})
        self.assertEqual(result["scanStatus"], "SYNTHETIC")
        self.assertEqual(result["realProviderCalls"], 0)
        self.assertEqual(result["preparedPlanSha256"], digest(canonical(self.prepared)))
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
        with self.assertRaisesRegex(ValueError, "STUB_LEDGER_CALL_ID"):
            self.convert(ledger=changed)

    def test_InterT05_frozen_source_prepare_actual_producer_and_bridge_remain_blocked(self):
        # Scenario: Real frozen Git blobs, signed fixture Prepare, envelope and unmodified stub producer feed the bridge.
        # Purpose: Exercise both distinct identity namespaces without rekeying producer evidence to make a fixture pass.
        frozen = prompt_fixture_module.PromptEnvelopeTests("test_UnitT10_three_exact_no_tool_request_bodies_stay_offline")
        frozen.setUp()
        self.addCleanup(frozen.doCleanups)
        subprocess.run(["git", "-C", str(frozen.repo), "remote", "add", "origin", "https://example.test/repo.git"], check=True)
        inventory = json.loads(frozen.inventory.read_bytes())
        consumer = copy.deepcopy(self.consumer)
        consumer["source"]["revision"] = inventory["candidate"]
        plan_path = frozen.root / "consumer.json"
        plan_path.write_bytes(canonical(consumer))
        signing = frozen.root / "sign-fixture.ps1"
        signing.write_text(r'''param([string]$Root)
$ErrorActionPreference = 'Stop'
$key = [Security.Cryptography.RSACryptoServiceProvider]::new(2048)
try {
    $now = [DateTime]::UtcNow
    $grant = [ordered]@{
        schemaVersion=1; grantType='routine-semantic-standing-grant-v1'; grantId='11111111-1111-4111-8111-111111111111'
        repository='https://example.test/repo.git'; pathPrefixes=@('skills/'); dataCategories=@('skill-instructions')
        provider='fixture-provider'; account='fixture-account'; modelFamily='fixture-model'; purpose='routine semantic review'
        dataHandlingSha256=('a'*64); approvalEvidenceSha256=('b'*64); maxSourceBytes=2048; maxCalls=3
        notBefore=$now.AddHours(-1).ToString('o'); expiresAt=$now.AddHours(1).ToString('o')
    }
    $registry = [ordered]@{
        schemaVersion=1; registryType='routine-semantic-revocations-v1'; sequence=1
        updatedAt=$now.AddMinutes(-1).ToString('o'); expiresAt=$now.AddMinutes(15).ToString('o'); revokedGrantIds=@()
    }
    foreach ($entry in @(@{Name='grant';Payload=$grant}, @{Name='revocations';Payload=$registry})) {
        $raw = [Text.UTF8Encoding]::new($false).GetBytes(($entry.Payload | ConvertTo-Json -Depth 12 -Compress))
        $envelope = @{schemaVersion=1;keyId='fixture';payloadBase64=[Convert]::ToBase64String($raw);signatureBase64=[Convert]::ToBase64String($key.SignData($raw,'SHA256'))}
        [IO.File]::WriteAllText((Join-Path $Root ($entry.Name+'.json')), ($envelope | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $Root 'public.xml'), $key.ToXmlString($false), [Text.UTF8Encoding]::new($false))
} finally { $key.Dispose() }
''', encoding="utf-8")
        signed = subprocess.run(["pwsh", "-NoProfile", "-File", str(signing), str(frozen.root)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        prepared_path = frozen.root / "prepared.json"
        prepare = subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/Invoke-RoutineSemanticScan.ps1"),
            "-Mode", "Prepare", "-PlanPath", str(plan_path), "-OutputPath", str(prepared_path),
            "-SourceRoot", str(frozen.repo), "-GrantPath", str(frozen.root / "grant.json"),
            "-RevocationPath", str(frozen.root / "revocations.json"), "-FixturePublicKeyPath", str(frozen.root / "public.xml"),
            "-PathPrefixes", "skills/", "-DataCategory", "skill-instructions", "-Provider", "fixture-provider",
            "-Account", "fixture-account", "-ModelFamily", "fixture-model", "-Purpose", "routine semantic review",
            "-DataHandlingSha256", "a" * 64, "-ToolReceiptSha256", "f" * 64, "-PlannedCalls", "3",
            "-MaximumBytes", "2048", "-WorkManifestPath", str(frozen.preflight), "-DevelopmentHarness"],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(prepare.returncode, 0, prepare.stderr)
        prepared_bytes = prepared_path.read_bytes()
        prepared = json.loads(prepared_bytes)
        self.assertEqual(prepared["executionPlan"]["workManifestSha256"], digest(frozen.preflight.read_bytes()))
        envelope = build_envelopes(frozen.inventory, frozen.preflight, frozen.prompts, frozen.repo,
                                   model="candidate-model", maximum_calls=3)
        ledger = invoke_stub_only(frozen.inventory, frozen.preflight, frozen.prompts, frozen.repo,
                                  model="candidate-model", maximum_calls=3)
        self.assertTrue(verify_stub_ledger(ledger))
        self.assertEqual([call["callId"] for call in ledger["calls"]], [item["callId"] for item in envelope["requests"]])
        bundle = {"schemaVersion":1, "artifactType":"routine-semantic-synthetic-bundle-v1",
                  "consumerPlanSha256":digest(plan_path.read_bytes()), "producerPlan":prepared,
                  "requiredAnalyzerIds":list(fixture_module.ANALYZERS), "workItems":[]}
        for call in ledger["calls"]:
            work_id = digest(f'{call["analyzerId"]}\n{call["sourcePath"]}\n{call["sourceSha256"]}'.encode())
            self.assertNotEqual(call["callId"], work_id)
            request = json.loads(base64.b64decode(call["requestBodyBase64"]))
            prompt = request["input"][0]["content"][0]["text"].encode()
            graph = canonical({"artifactType":"synthetic-raw-graph-v1", "workItemId":work_id, "analyzerId":call["analyzerId"]})
            findings = canonical({"workItemId":work_id, "findings":[]})
            bundle["workItems"].append({"id":work_id, "analyzerId":call["analyzerId"], "path":call["sourcePath"],
                "selectedBlobSha256":call["sourceSha256"], "promptBase64":base64.b64encode(prompt).decode("ascii"),
                "promptSha256":call["promptSha256"], "responseBase64":call["rawResponseBase64"], "responseSha256":call["rawResponseSha256"],
                "rawGraphBase64":base64.b64encode(graph).decode("ascii"), "rawGraphSha256":digest(graph),
                "rawFindingsBase64":base64.b64encode(findings).decode("ascii"), "rawFindingsSha256":digest(findings)})
        self.assertEqual(verify_bundle(consumer, plan_path.read_bytes(), prepared, bundle, canonical(bundle))["scanStatus"], "SYNTHETIC")
        result = bridge(consumer, plan_path.read_bytes(), prepared, prepared_bytes, bundle, canonical(bundle), ledger, canonical(ledger))
        self.assertEqual({(item["callId"], item["workItemId"]) for item in result["bindings"]},
                         {(call["callId"], work["id"]) for call,work in zip(ledger["calls"], bundle["workItems"])})
        self.assertEqual(result["scanStatus"], "SYNTHETIC")
        self.assertEqual(result["ciAdmission"], "BLOCKED")
        self.assertIs(result["releaseEligible"], False)
        self.assertEqual(result["realProviderCalls"], 0)

        changed = copy.deepcopy(ledger)
        changed["preflightSha256"] = "0" * 64
        self.assertTrue(verify_stub_ledger(changed))
        with self.assertRaisesRegex(ValueError, "PREPARED_WORK_MANIFEST_MISMATCH"):
            bridge(consumer, plan_path.read_bytes(), prepared, prepared_bytes, bundle, canonical(bundle), changed, canonical(changed))

    def test_UnitT35_duplicate_work_call_alias_and_raw_document_substitution_reject(self):
        # Scenario: Valid ledger calls repeat an analyzer/source pair with distinct prompt IDs, alias an ID, or substitute raw evidence.
        # Purpose: The cross-namespace join must retain exact one-to-one coverage and raw-byte custody.
        repeated = copy.deepcopy(self.ledger)
        call = copy.deepcopy(repeated["calls"][0])
        call["sequence"] = 2
        body = json.loads(base64.b64decode(call["requestBodyBase64"]))
        body["input"][0]["content"][0]["text"] += " additional prompt"
        prompt = body["input"][0]["content"][0]["text"].encode()
        body_bytes = canonical(body)
        call["promptSha256"] = digest(prompt)
        call["promptBytes"] = len(prompt)
        call["callId"] = digest(f'{call["analyzerId"]}\n{call["sourcePath"]}\n{call["promptSha256"]}'.encode())
        response = OfflineResponsesStub().respond(call_id=call["callId"], request_body=body_bytes)
        for stem, raw in (("requestBody", body_bytes), ("rawResponse", response)):
            call[stem + "Base64"] = base64.b64encode(raw).decode("ascii")
            call[stem + "Sha256"] = digest(raw)
            call[stem + "Bytes"] = len(raw)
        repeated["calls"][1] = call
        for stem in ("requestBody", "rawResponse"):
            repeated[stem + "BytesTotal"] = sum(item[stem + "Bytes"] for item in repeated["calls"])
        self.assertTrue(verify_stub_ledger(repeated))
        with self.assertRaisesRegex(ValueError, "LEDGER_WORK_ID_UNKNOWN_OR_DUPLICATE"):
            self.convert(ledger=repeated)
        alias = copy.deepcopy(self.ledger)
        alias["calls"][0]["callId"] = self.bundle["workItems"][0]["id"]
        with self.assertRaisesRegex(ValueError, "STUB_LEDGER_CALL_ID"):
            self.convert(ledger=alias)
        wrong_source = copy.deepcopy(self.ledger)
        wrong_source["calls"][0]["sourceSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "LEDGER_WORK_BINDING_MISMATCH"):
            self.convert(ledger=wrong_source)
        documents = [self.consumer, self.prepared, self.bundle, self.ledger]
        for index, code in ((0,"CONSUMER_PLAN"), (1,"PREPARED_PLAN"), (2,"BUNDLE"), (3,"LEDGER")):
            raw = [canonical(item) for item in documents]
            substituted = copy.deepcopy(documents[index])
            substituted["schemaVersion"] = 2
            raw[index] = canonical(substituted)
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, code + "_BYTES_MISMATCH"):
                bridge(documents[0], raw[0], documents[1], raw[1], documents[2], raw[2], documents[3], raw[3])

    def test_InterT10_cli_writes_blocked_bridge_only(self):
        # Scenario: The CLI receives four valid fixture inputs and a new output path.
        # Purpose: Persist only a synthetic, untrusted bridge artifact.
        consumer_bytes = canonical(self.consumer)
        self.bundle["producerPlan"]["consumerBinding"]["consumerPlanSha256"] = digest(consumer_bytes)
        self.bundle["consumerPlanSha256"] = digest(consumer_bytes)
        plan = self.fixture.root / "bridge-plan.json"
        prepared = self.fixture.root / "bridge-prepared.json"
        bundle = self.fixture.root / "bridge-bundle.json"
        ledger = self.fixture.root / "bridge-ledger.json"
        output = self.fixture.root / "bridge-output.json"
        for path, value in ((plan, self.consumer), (prepared, self.prepared), (bundle, self.bundle), (ledger, self.ledger)):
            path.write_bytes(canonical(value))
        run = subprocess.run([sys.executable, str(ROOT / "scripts" / "routine_semantic_ledger_bridge.py"),
            "--plan", str(plan), "--prepared", str(prepared), "--bundle", str(bundle), "--ledger", str(ledger),
            "--output", str(output)], capture_output=True, text=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["ciAdmission"], "BLOCKED")

    def test_InterT15_cli_rejects_absent_substituted_or_colliding_prepared_input(self):
        # Scenario: A CLI caller omits Prepare, supplies a different saved decision, or aliases a bundle path.
        # Purpose: Reject before create-only output instead of deriving Prepare from the bundle being checked.
        plan = self.fixture.root / "missing-plan.json"
        prepared = self.fixture.root / "wrong-prepared.json"
        bundle = self.fixture.root / "missing-bundle.json"
        ledger = self.fixture.root / "missing-ledger.json"
        output = self.fixture.root / "missing-output.json"
        changed = copy.deepcopy(self.prepared)
        changed["decision"]["egressAuthorized"] = True
        for path, value in ((plan, self.consumer), (prepared, changed), (bundle, self.bundle), (ledger, self.ledger)):
            path.write_bytes(canonical(value))
        command = [sys.executable, str(ROOT / "scripts" / "routine_semantic_ledger_bridge.py"),
                   "--plan", str(plan), "--bundle", str(bundle), "--ledger", str(ledger), "--output", str(output)]
        for extra, reason in (([], "--prepared"), (["--prepared", str(prepared)], "PREPARED_PLAN_MISMATCH"),
                              (["--prepared", str(bundle)], "INPUT_OUTPUT_PATH_COLLISION")):
            with self.subTest(extra=extra):
                run = subprocess.run(command + extra, capture_output=True, text=True, timeout=20)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn(reason, run.stderr)
                self.assertFalse(output.exists())

    def test_InterT20_cli_rejects_duplicate_ledger_key_without_output(self):
        # Scenario: A ledger repeats its schemaVersion JSON key.
        # Purpose: Refuse ambiguous raw evidence before writing a bridge artifact.
        plan = self.fixture.root / "duplicate-plan.json"
        prepared = self.fixture.root / "duplicate-prepared.json"
        bundle = self.fixture.root / "duplicate-bundle.json"
        ledger = self.fixture.root / "duplicate-ledger.json"
        output = self.fixture.root / "duplicate-output.json"
        consumer_bytes = canonical(self.consumer)
        self.bundle["producerPlan"]["consumerBinding"]["consumerPlanSha256"] = digest(consumer_bytes)
        self.bundle["consumerPlanSha256"] = digest(consumer_bytes)
        plan.write_bytes(consumer_bytes)
        prepared.write_bytes(canonical(self.prepared))
        bundle.write_bytes(canonical(self.bundle))
        ledger.write_bytes(b'{"schemaVersion":1,"schemaVersion":1}')
        run = subprocess.run([sys.executable, str(ROOT / "scripts" / "routine_semantic_ledger_bridge.py"),
            "--plan", str(plan), "--prepared", str(prepared), "--bundle", str(bundle), "--ledger", str(ledger),
            "--output", str(output)], capture_output=True, text=True, timeout=20)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("LEDGER_DUPLICATE_PROPERTY", run.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
