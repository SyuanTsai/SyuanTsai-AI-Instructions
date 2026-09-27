"""Fixture contract for the inactive routine semantic delivery boundary."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from scripts import routine_semantic_delivery as delivery


def write_json(path: Path, value: dict) -> bytes:
    data = delivery.canonical(value) + b"\n"
    path.write_bytes(data)
    return data


class DeliveryFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.plan_path = self.root / "consumer-plan.json"
        self.prepared_path = self.root / "prepared.json"
        self.bundle_path = self.root / "bundle.json"
        self.manifest_path = self.root / "manifest.json"
        self.expected_path = self.root / "protected-expected.json"
        self.claim_path = self.root / "delivery-claim.json"
        self.artifact_paths = {key: self.root / (key + ".json") for key in delivery.ARTIFACT_KEYS}
        for key, path in self.artifact_paths.items():
            path.write_text('fixture-' + key, encoding="utf-8")
        self.bundle_path.write_text("fixture-bundle", encoding="utf-8")
        self.plan = {
            "schemaVersion": 1, "artifactType": "standard-validation-consumer-run-plan-v1",
            "runId": "a" * 32,
            "source": {"repository": "https://example.test/source.git", "revision": "b" * 40,
                       "baseRevision": "c" * 40, "tree": "d" * 40},
            "candidate": {"candidateId": "e" * 64, "contentSha256": "f" * 64},
            "authority": {"revision": "1" * 40, "archivePath": str(self.root / "authority.zip"),
                          "archiveSha256": "2" * 64, "runnerPath": str(self.root / "runner.ps1"),
                          "runnerSha256": "3" * 64},
            "tools": {"policyReceiptPath": str(self.root / "tool-receipt.json"),
                      "policyReceiptSha256": "4" * 64},
            "semantic": {**{key: str(path) for key, path in self.artifact_paths.items()},
                         "publicKeyId": "fixture-key"},
        }
        plan_bytes = write_json(self.plan_path, self.plan)
        self.prepared = {
            "schemaVersion": 1, "artifactType": "routine-semantic-prepared-plan-v1",
            "candidateId": "5" * 64,
            "sourceInventory": {"inputInventorySha256": "6" * 64},
            "authority": {"repository": self.plan["source"]["repository"],
                          "sourceRevision": self.plan["source"]["revision"]},
            "consumerBinding": {"runId": self.plan["runId"],
                                "candidateId": self.plan["candidate"]["candidateId"],
                                "contentSha256": self.plan["candidate"]["contentSha256"],
                                "sourceRevision": self.plan["source"]["revision"],
                                "consumerPlanSha256": delivery.digest(plan_bytes)},
            "deliveryBinding": {
                "runId": self.plan["runId"], "consumerPlanSha256": delivery.digest(plan_bytes),
                "sourceRevision": self.plan["source"]["revision"],
                "sourceBaseRevision": self.plan["source"]["baseRevision"],
                "sourceTree": self.plan["source"]["tree"],
                "consumerCandidateId": self.plan["candidate"]["candidateId"],
                "consumerContentSha256": self.plan["candidate"]["contentSha256"],
                "authorityArchiveSha256": self.plan["authority"]["archiveSha256"],
                "authorityRunnerSha256": self.plan["authority"]["runnerSha256"],
                "toolPolicyReceiptSha256": self.plan["tools"]["policyReceiptSha256"],
                "publicKeyId": self.plan["semantic"]["publicKeyId"],
                "artifacts": {key: str(path) for key, path in self.artifact_paths.items()},
            },
            "ciAdmission": "BLOCKED", "releaseEligible": False,
        }
        write_json(self.prepared_path, self.prepared)
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.issued = (self.now - timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.expires = (self.now + timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def manifest(self) -> dict:
        value = delivery.build(self.plan_path, self.prepared_path, self.bundle_path, self.issued, self.expires)
        manifest_bytes = write_json(self.manifest_path, value)
        write_json(self.expected_path, {
            "schemaVersion": 1, "artifactType": "routine-semantic-protected-expected-v1",
            "runId": self.plan["runId"], "consumerPlanSha256": delivery.digest(self.plan_path.read_bytes()),
            "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
        })
        return value

    def verify(self) -> dict:
        return delivery.verify(self.plan_path, self.prepared_path, self.bundle_path,
                               self.manifest_path, self.expected_path, self.claim_path, self.now)

    def test_UnitT10_complete_fixture_is_bound_but_blocked(self) -> None:
        # Scenario: Every frozen path and hash matches a separately supplied expected digest.
        # Purpose: Exercise the delivery contract without implying protected trust or admission.
        self.manifest()
        result = self.verify()
        self.assertEqual(result["bindingStatus"], "MATCHED_LOCAL_CANDIDATE")
        self.assertEqual(result["ciAdmission"], "BLOCKED")
        self.assertEqual(result["trustStatus"], "unverified")
        self.assertFalse(result["releaseEligible"])
        self.assertTrue(self.claim_path.is_file())

    def test_UnitT20_missing_or_partial_artifact_rejects(self) -> None:
        # Scenario: A required delivered file is absent or omitted from the manifest.
        # Purpose: Prevent partial four-file handoff from being accepted.
        self.manifest()
        self.artifact_paths["evidencePath"].unlink()
        with self.assertRaises(ValueError):
            self.verify()
        self.assertFalse(self.claim_path.exists())
        self.artifact_paths["evidencePath"].write_text("restored", encoding="utf-8")
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        del manifest["artifacts"]["publicKeyPath"]
        manifest_bytes = write_json(self.manifest_path, manifest)
        expected = json.loads(self.expected_path.read_text(encoding="utf-8"))
        expected["manifestSha256"] = delivery.digest(manifest_bytes)
        write_json(self.expected_path, expected)
        with self.assertRaises(ValueError):
            self.verify()
        self.assertFalse(self.claim_path.exists())

    def test_UnitT30_tamper_and_cross_run_reject(self) -> None:
        # Scenario: Delivered bytes change or the protected expected run differs.
        # Purpose: Detect changed artifacts and cross-run substitutions before a claim.
        self.manifest()
        self.artifact_paths["consentDecisionPath"].write_text("tampered", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "DELIVERY_BINDING_MISMATCH"):
            self.verify()
        self.assertFalse(self.claim_path.exists())
        self.artifact_paths["consentDecisionPath"].write_text("fixture-consentDecisionPath", encoding="utf-8")
        expected = json.loads(self.expected_path.read_text(encoding="utf-8"))
        expected["runId"] = "9" * 32
        write_json(self.expected_path, expected)
        with self.assertRaisesRegex(ValueError, "PROTECTED_RUN_MISMATCH"):
            self.verify()

    def test_UnitT40_expiry_and_replay_reject(self) -> None:
        # Scenario: A lease expires or a delivered manifest has already been claimed.
        # Purpose: Keep fixture receipt use bounded to one run and one claim.
        self.manifest()
        with self.assertRaisesRegex(ValueError, "DELIVERY_EXPIRED_OR_FUTURE"):
            delivery.verify(self.plan_path, self.prepared_path, self.bundle_path,
                            self.manifest_path, self.expected_path, self.claim_path,
                            self.now + timedelta(hours=1))
        self.assertFalse(self.claim_path.exists())
        self.verify()
        with self.assertRaisesRegex(ValueError, "DELIVERY_REPLAY"):
            self.verify()

    def test_UnitT45_authority_tamper_and_resume_claim_collision_reject(self) -> None:
        # Scenario: The plan's authority closure changes or delivery targets Resume's claim.
        # Purpose: Bind executable closure and preserve the consumer's atomic Resume claim.
        self.manifest()
        changed = json.loads(self.plan_path.read_text(encoding="utf-8"))
        changed["authority"]["runnerSha256"] = "0" * 64
        write_json(self.plan_path, changed)
        with self.assertRaises(ValueError):
            self.verify()
        self.assertFalse(self.claim_path.exists())
        write_json(self.plan_path, self.plan)
        self.plan["execution"] = {"consumptionClaimPath": str(self.claim_path)}
        plan_bytes = write_json(self.plan_path, self.plan)
        self.prepared["consumerBinding"]["consumerPlanSha256"] = delivery.digest(plan_bytes)
        self.prepared["deliveryBinding"]["consumerPlanSha256"] = delivery.digest(plan_bytes)
        write_json(self.prepared_path, self.prepared)
        self.manifest()
        with self.assertRaisesRegex(ValueError, "DELIVERY_CLAIM_COLLIDES_WITH_RESUME"):
            self.verify()

    def test_UnitT50_independent_expected_digest_is_required(self) -> None:
        # Scenario: The expected input is missing or differs from manifest bytes.
        # Purpose: Avoid accepting a bundle or manifest that vouches for itself.
        self.manifest()
        self.expected_path.unlink()
        with self.assertRaises(ValueError):
            self.verify()
        self.assertFalse(self.claim_path.exists())
        self.manifest()
        expected = json.loads(self.expected_path.read_text(encoding="utf-8"))
        expected["manifestSha256"] = "0" * 64
        write_json(self.expected_path, expected)
        with self.assertRaisesRegex(ValueError, "MANIFEST_PROTECTED_DIGEST_MISMATCH"):
            self.verify()

    def test_InterT10_existing_cli_builds_and_verifies_blocked_delivery(self) -> None:
        # Scenario: The existing PowerShell CLI calls both inactive delivery surfaces.
        # Purpose: Check a real callable route and its fail-closed output contract.
        if shutil.which("pwsh") is None or shutil.which("python") is None:
            self.skipTest("CLI runtimes unavailable")
        cli = Path(__file__).resolve().parents[1] / "scripts" / "Invoke-RoutineSemanticScan.ps1"
        build_args = ["pwsh", "-NoProfile", "-File", str(cli), "-Mode", "BuildDelivery",
                      "-PlanPath", str(self.plan_path), "-PreparedPath", str(self.prepared_path),
                      "-BundlePath", str(self.bundle_path), "-OutputPath", str(self.manifest_path),
                      "-IssuedAtUtc", self.issued, "-ExpiresAtUtc", self.expires]
        built = subprocess.run(build_args, capture_output=True, text=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stderr)
        manifest_bytes = self.manifest_path.read_bytes()
        write_json(self.expected_path, {
            "schemaVersion": 1, "artifactType": "routine-semantic-protected-expected-v1",
            "runId": self.plan["runId"], "consumerPlanSha256": delivery.digest(self.plan_path.read_bytes()),
            "manifestSha256": delivery.digest(manifest_bytes),
        })
        output = self.root / "delivery-verification.json"
        verify_args = ["pwsh", "-NoProfile", "-File", str(cli), "-Mode", "VerifyDelivery",
                       "-PlanPath", str(self.plan_path), "-PreparedPath", str(self.prepared_path),
                       "-BundlePath", str(self.bundle_path), "-ManifestPath", str(self.manifest_path),
                       "-ProtectedExpectedPath", str(self.expected_path),
                       "-DeliveryClaimPath", str(self.claim_path), "-OutputPath", str(output)]
        verified = subprocess.run(verify_args, capture_output=True, text=True, timeout=30)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        result = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(result["ciAdmission"], "BLOCKED")
        self.assertTrue(self.claim_path.is_file())

    def test_InterT20_module_binds_full_consumer_closure(self) -> None:
        # Scenario: The existing PowerShell module receives a full General plan.
        # Purpose: Confirm Prepare's binding helper carries both identities and artifact paths.
        if shutil.which("pwsh") is None:
            self.skipTest("PowerShell unavailable")
        module = Path(__file__).resolve().parents[1] / "scripts" / "RoutineSemanticScan.psm1"
        script = self.root / "check-binding.ps1"
        script.write_text(
            "param([string] $ModulePath, [string] $PlanPath, [string] $PlanSha)\n"
            "Import-Module $ModulePath -Force\n"
            "$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json\n"
            "Get-RoutineSemanticDeliveryPlanBinding -Consumer $plan -ConsumerPlanSha256 $PlanSha | ConvertTo-Json -Depth 10\n",
            encoding="utf-8",
        )
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(script),
                                 "-ModulePath", str(module), "-PlanPath", str(self.plan_path),
                                 "-PlanSha", delivery.digest(self.plan_path.read_bytes())],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        binding = json.loads(result.stdout)
        self.assertEqual(binding, self.prepared["deliveryBinding"])


if __name__ == "__main__":
    unittest.main()
