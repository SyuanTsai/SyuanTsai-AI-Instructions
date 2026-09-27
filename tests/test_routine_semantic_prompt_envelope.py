"""Exact outbound request bytes for an offline-only semantic scan candidate."""
import hashlib
import json
from pathlib import Path
import base64
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from routine_semantic_candidate import CandidateError, preflight  # noqa: E402
from routine_semantic_prompt_envelope import build_envelopes  # noqa: E402
from routine_semantic_provider_invocation import invoke_stub_only, verify_stub_ledger  # noqa: E402


class PromptEnvelopeTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        source = self.repo / "skills/example/SKILL.md"
        source.parent.mkdir(parents=True)
        source.write_text("---\nname: example\n---\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.repo), "add", "skills"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test",
                        "-c", "user.email=test@example.test", "commit", "-qm", "fixture"], check=True)
        revision = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        blob = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD:skills/example/SKILL.md"], text=True).strip()
        body = subprocess.check_output(["git", "-C", str(self.repo), "cat-file", "blob", blob])
        self.inventory = self.root / "inventory.json"
        self.inventory.write_text(json.dumps({"candidate": revision, "items": [{"path": "skills/example/SKILL.md",
            "gitBlobSha1": blob, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(),
            "changed": True, "skillInstructions": True}]}), encoding="utf-8")
        self.prompts = self.root / "prompts"
        self.prompts.mkdir()
        items = []
        for analyzer in ("semantic_developer_intent", "semantic_quality_policy", "semantic_security_discovery"):
            data = ("Synthetic only\n## File: SKILL.md\n" + analyzer).encode()
            name = analyzer + ".txt"
            (self.prompts / name).write_bytes(data)
            items.append({"file": name, "skill": "example", "analyzerId": analyzer,
                          "promptSha256": hashlib.sha256(data).hexdigest(), "promptBytes": len(data),
                          "model": "diagnostic-local", "maxOutputTokensRequested": 32000})
        (self.prompts / "manifest.json").write_text(json.dumps({"schemaVersion": 1,
            "sourceRevision": revision, "sourceInventorySha256": hashlib.sha256(self.inventory.read_bytes()).hexdigest(),
            "sourceFileCount": 1, "sourceBytes": len(body), "promptCandidates": items,
            "realProviderCalls": 0, "egressAuthorized": False}), encoding="utf-8")
        self.preflight = self.root / "preflight.json"
        self.preflight.write_text(json.dumps(preflight(self.inventory, self.prompts, self.repo, 3)), encoding="utf-8")

    def test_UnitT10_three_exact_no_tool_request_bodies_stay_offline(self):
        result = build_envelopes(self.inventory, self.preflight, self.prompts, self.repo,
                                 model="candidate-model", maximum_calls=3)
        self.assertEqual(result["status"], "OFFLINE_ENVELOPE_ONLY")
        self.assertEqual(result["requestCount"], 3)
        self.assertEqual(result["realProviderCalls"], 0)
        self.assertFalse(result["egressAuthorized"])
        self.assertEqual(result["ciAdmission"], "BLOCKED")
        for request in result["requests"]:
            body = json.loads(bytes.fromhex(request["bodyHex"]))
            self.assertEqual(body["tools"], [])
            self.assertEqual(body["tool_choice"], "none")
            self.assertEqual(body["max_output_tokens"], 2048)
            self.assertEqual(body["truncation"], "disabled")
            self.assertIs(body["store"], False)
            self.assertEqual(set(body), {"model", "input", "tools", "tool_choice",
                                         "max_output_tokens", "truncation", "store"})
            self.assertEqual(hashlib.sha256(bytes.fromhex(request["bodyHex"])).hexdigest(), request["bodySha256"])

    def test_UnitT20_budget_and_changed_source_or_preflight_rejected(self):
        with self.assertRaises(CandidateError):
            build_envelopes(self.inventory, self.preflight, self.prompts, self.repo,
                            model="candidate-model", maximum_calls=2)
        data = json.loads(self.preflight.read_text(encoding="utf-8"))
        data["calls"][0]["promptSha256"] = "0" * 64
        self.preflight.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaises(CandidateError):
            build_envelopes(self.inventory, self.preflight, self.prompts, self.repo,
                            model="candidate-model", maximum_calls=3)
        data = preflight(self.inventory, self.prompts, self.repo, 3)
        data["maximumCalls"] = 3.0
        self.preflight.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaises(CandidateError):
            build_envelopes(self.inventory, self.preflight, self.prompts, self.repo,
                            model="candidate-model", maximum_calls=3)

    def test_UnitT30_route_and_extra_prompt_rejected(self):
        with self.assertRaises(CandidateError):
            build_envelopes(self.inventory, self.preflight, self.prompts, self.repo,
                            model="invalid model", maximum_calls=3)
        (self.prompts / "extra.txt").write_text("unreviewed", encoding="utf-8")
        with self.assertRaises(CandidateError):
            build_envelopes(self.inventory, self.preflight, self.prompts, self.repo,
                            model="candidate-model", maximum_calls=3)

    def test_UnitT40_stub_invocation_has_exact_destination_cap_and_raw_ledger(self):
        # Scenario: Three immutable fixture prompts are passed to the bounded local stub.
        # Purpose: Inspect every candidate outbound body and keep a raw, blocked ledger.
        result = invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                                  model="candidate-model", maximum_calls=3)
        self.assertEqual(result["destination"], "https://api.openai.com/v1/responses")
        self.assertEqual(result["httpMethodCandidate"], "POST")
        self.assertEqual(result["purpose"], "routine semantic review")
        self.assertEqual(result["status"], "STUB_ONLY")
        self.assertEqual(result["realProviderCalls"], 0)
        self.assertEqual(result["ciAdmission"], "BLOCKED")
        self.assertFalse(result["networkTransportPresent"])
        self.assertFalse(result["costVerified"])
        self.assertEqual(len(result["calls"]), 3)
        self.assertTrue(verify_stub_ledger(result))
        for entry in result["calls"]:
            body = base64.b64decode(entry["requestBodyBase64"], validate=True)
            self.assertEqual(hashlib.sha256(body).hexdigest(), entry["requestBodySha256"])
            parsed = json.loads(body)
            self.assertEqual(set(parsed), {"model", "input", "tools", "tool_choice",
                                           "max_output_tokens", "truncation", "store"})
            self.assertEqual(parsed["tools"], [])
            self.assertEqual(parsed["tool_choice"], "none")
            self.assertEqual(parsed["max_output_tokens"], 2048)
            self.assertEqual(parsed["truncation"], "disabled")
            self.assertIs(parsed["store"], False)
            self.assertEqual(entry["sourcePath"], "skills/example/SKILL.md")

    def test_UnitT50_stub_ledger_rejects_mutation_and_budget_increase(self):
        # Scenario: A raw response changes, or caller asks above the 78-call candidate cap.
        # Purpose: Keep local evidence immutable and avoid a silent scope expansion.
        result = invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                                  model="candidate-model", maximum_calls=3)
        result["calls"][0]["rawResponseBase64"] = "e30="
        with self.assertRaises(CandidateError):
            verify_stub_ledger(result)
        result = invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                                  model="candidate-model", maximum_calls=3)
        first = result["calls"][0]
        body = json.loads(base64.b64decode(first["requestBodyBase64"]))
        body["tools"] = [{"type": "file_search"}]
        changed = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
        first["requestBodyBase64"] = base64.b64encode(changed).decode("ascii")
        first["requestBodySha256"] = hashlib.sha256(changed).hexdigest()
        first["requestBodyBytes"] = len(changed)
        result["requestBodyBytesTotal"] = sum(x["requestBodyBytes"] for x in result["calls"])
        with self.assertRaisesRegex(CandidateError, "REQUEST_ROUTE_OR_CAPABILITY"):
            verify_stub_ledger(result)
        result = invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                                  model="candidate-model", maximum_calls=3)
        result["costVerified"] = True
        with self.assertRaisesRegex(CandidateError, "STUB_LEDGER_STATUS"):
            verify_stub_ledger(result)
        with self.assertRaises(CandidateError):
            invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                             model="candidate-model", maximum_calls=79)

    def test_UnitT55_full_coverage_candidate_cap_remains_offline_and_blocked(self):
        # Scenario: The candidate budget allows the 78 calls required by the frozen inventory.
        # Purpose: A complete offline candidate is possible without granting real egress or CI admission.
        self.preflight.write_text(json.dumps(preflight(self.inventory, self.prompts, self.repo, 78)), encoding="utf-8")
        result = invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                                  model="candidate-model", maximum_calls=78)
        self.assertEqual(result["maximumCalls"], 78)
        self.assertEqual(result["requestCount"], 3)
        self.assertTrue(verify_stub_ledger(result))
        self.assertEqual(result["realProviderCalls"], 0)
        self.assertEqual(result["ciAdmission"], "BLOCKED")

    def test_InterT20_seventy_eight_stub_calls_cover_every_synthetic_work_item(self):
        # Scenario: Twenty-six frozen files each have all three analyzer prompts.
        # Purpose: Exercise the complete candidate call count without a real transport or admission.
        files = [self.repo / "skills/example/SKILL.md"]
        for number in range(25):
            path = self.repo / f"skills/example/file-{number:02}.txt"
            path.write_text(f"synthetic source {number}\n", encoding="utf-8")
            files.append(path)
        subprocess.run(["git", "-C", str(self.repo), "add", "skills"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test",
                        "-c", "user.email=test@example.test", "commit", "-qm", "complete fixture"], check=True)
        revision = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        inventory_items = []
        prompt_items = []
        for source in sorted(files):
            relative = source.relative_to(self.repo).as_posix()
            blob = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse",
                                            f"HEAD:{relative}"], text=True).strip()
            raw = subprocess.check_output(["git", "-C", str(self.repo), "cat-file", "blob", blob])
            inventory_items.append({"path": relative, "gitBlobSha1": blob, "bytes": len(raw),
                                    "sha256": hashlib.sha256(raw).hexdigest(),
                                    "changed": True, "skillInstructions": source.name == "SKILL.md"})
        for old in self.prompts.iterdir():
            old.unlink()
        for analyzer in ("semantic_developer_intent", "semantic_quality_policy",
                         "semantic_security_discovery"):
            for source in sorted(files):
                name = f"{analyzer}-{source.name}.txt"
                raw = f"Synthetic only\n## File: {source.name}\n{analyzer}".encode("utf-8")
                (self.prompts / name).write_bytes(raw)
                prompt_items.append({"file": name, "skill": "example", "analyzerId": analyzer,
                                     "promptSha256": hashlib.sha256(raw).hexdigest(),
                                     "promptBytes": len(raw), "model": "diagnostic-local",
                                     "maxOutputTokensRequested": 2048})
        self.inventory.write_text(json.dumps({"candidate": revision, "items": inventory_items}), encoding="utf-8")
        self.prompts.joinpath("manifest.json").write_text(json.dumps({"schemaVersion": 1,
            "sourceRevision": revision, "sourceInventorySha256": hashlib.sha256(self.inventory.read_bytes()).hexdigest(),
            "sourceFileCount": 26, "sourceBytes": sum(item["bytes"] for item in inventory_items),
            "promptCandidates": prompt_items, "realProviderCalls": 0,
            "egressAuthorized": False}), encoding="utf-8")
        self.preflight.write_text(json.dumps(preflight(self.inventory, self.prompts, self.repo, 78)), encoding="utf-8")
        result = invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                                  model="candidate-model", maximum_calls=78)
        self.assertEqual(result["requestCount"], 78)
        self.assertEqual(len({(call["analyzerId"], call["sourcePath"]) for call in result["calls"]}), 78)
        self.assertTrue(verify_stub_ledger(result))
        self.assertEqual(result["realProviderCalls"], 0)
        self.assertEqual(result["ciAdmission"], "BLOCKED")

    def test_UnitT60_stub_path_never_opens_network_socket(self):
        # Scenario: The local stub candidate executes with socket connections forbidden.
        # Purpose: Prove fixture invocation stays offline even when three calls are processed.
        with patch("socket.socket.connect", side_effect=AssertionError("network used")):
            result = invoke_stub_only(self.inventory, self.preflight, self.prompts, self.repo,
                                      model="candidate-model", maximum_calls=3)
        self.assertEqual(result["requestCount"], 3)
        self.assertFalse(result["networkTransportPresent"])

    def test_InterT10_cli_writes_only_blocked_stub_ledger(self):
        # Scenario: The executable candidate CLI runs against immutable local fixture files.
        # Purpose: Keep its raw ledger inspectable without creating a provider call.
        output = self.root / "stub-ledger.json"
        script = Path(__file__).resolve().parents[1] / "scripts" / "routine_semantic_provider_invocation.py"
        run = subprocess.run([sys.executable, str(script), "--inventory", str(self.inventory),
                              "--preflight", str(self.preflight), "--prompt-directory", str(self.prompts),
                              "--source-repo", str(self.repo), "--model", "candidate-model",
                              "--maximum-calls", "3", "--output", str(output)],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)
        ledger = json.loads(output.read_text(encoding="utf-8"))
        self.assertTrue(verify_stub_ledger(ledger))
        self.assertEqual(ledger["realProviderCalls"], 0)
        self.assertEqual(ledger["ciAdmission"], "BLOCKED")


if __name__ == "__main__":
    unittest.main()
