"""Exact outbound request bytes for an offline-only semantic scan candidate."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from routine_semantic_candidate import CandidateError, preflight  # noqa: E402
from routine_semantic_prompt_envelope import build_envelopes  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
