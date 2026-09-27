"""Contract tests for the manual, non-required PR8 even-shard diagnostic."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/pr8-even-shard-diagnostic.yml"
EXPECTED_FILES = 32
EXPECTED_SHA = "242160f809b58b99b844c7228fce04c1c8ac876a30194544a9089c1f800b99ae"


class EvenDiagnosticContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow_text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.load(cls.workflow_text, Loader=yaml.BaseLoader)
        cls.job = cls.workflow["jobs"]["even-diagnostic"]
        cls.inventory_script = cls.job["steps"][1]["run"]
        cls.matrix = cls.job["strategy"]["matrix"]["include"]

    # Scenario: A draft diagnostic is accidentally wired to automatic or required CI.
    # Purpose: Keep the existing protected check surface and credentials unchanged.
    def test_UnitT10_remains_manual_bounded_and_low_privilege(self):
        self.assertEqual(["workflow_dispatch"], list(self.workflow["on"]))
        self.assertEqual({"contents": "read"}, self.workflow["permissions"])
        self.assertEqual("false", self.workflow["concurrency"]["cancel-in-progress"])
        self.assertEqual("45", self.job["timeout-minutes"])
        self.assertEqual("false", self.job["strategy"]["fail-fast"])
        steps = self.job["steps"]
        self.assertEqual(5, len(steps))
        self.assertEqual("actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", steps[0]["uses"].split()[0])
        self.assertEqual("false", steps[0]["with"]["persist-credentials"])
        self.assertEqual("always()", steps[-1]["if"])
        self.assertEqual("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02", steps[-1]["uses"].split()[0])
        self.assertEqual("7", steps[-1]["with"]["retention-days"])
        self.assertIn("pester-shard-*.json", steps[-1]["with"]["path"])
        self.assertIn("DIAGNOSTIC_PARTITION_START", steps[3]["run"])
        self.assertIn("DIAGNOSTIC_PARTITION_END", steps[3]["run"])
        self.assertIn("DIAGNOSTIC_PARTITION_EXIT", steps[3]["run"])
        self.assertIn("ShardPartitionCount = 8", steps[3]["run"])
        self.assertIn("ExpectedFullShardCount = 32", steps[3]["run"])
        self.assertIn("OuterTimeoutSeconds = 2400", steps[3]["run"])

    # Scenario: GitHub expands static matrix values into the PowerShell steps.
    # Purpose: A YAML-valid workflow must also contain parsable scripts before dispatch.
    def test_UnitT20_embedded_powershell_steps_parse(self):
        with tempfile.TemporaryDirectory() as directory:
            for position in (1, 2, 3):
                script = self.job["steps"][position]["run"]
                for key, value in {"shell": "pwsh", "pester": "4.10.1", "runtime": "ps7",
                                   "index": "0", "total": "181"}.items():
                    script = script.replace("${{ matrix." + key + " }}", value)
                path = Path(directory) / f"step-{position}.ps1"
                path.write_text(script, encoding="utf-8")
                source = str(path).replace("'", "''")
                parser = ("$t=$null;$e=$null;"
                          f"[System.Management.Automation.Language.Parser]::ParseFile('{source}',[ref]$t,[ref]$e)|Out-Null;"
                          "if($e.Count){$e|ForEach-Object{Write-Error $_.Message};exit 1}")
                result = subprocess.run(["pwsh", "-NoProfile", "-Command", parser],
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(0, result.returncode, f"step {position}: {result.stderr}")

    # Scenario: The exact Git test roster is absent, duplicated, or changed.
    # Purpose: Fail before running the executor with stale split counts.
    def test_InterT10_recomputes_exact_candidate_inventory_and_partitions(self):
        names = sorted("tests/" + path.name for path in (ROOT / "tests").glob("*.Tests.ps1"))
        self.assertEqual(EXPECTED_FILES, len(names))
        self.assertEqual(EXPECTED_SHA, hashlib.sha256("\n".join(names).encode()).hexdigest())
        self.assertEqual(
            [("ps51", "powershell", "3.4.0", "0", "181"),
             ("ps51", "powershell", "3.4.0", "4", "40"),
             ("ps7", "pwsh", "4.10.1", "0", "181"),
             ("ps7", "pwsh", "4.10.1", "4", "40")],
            [(item["runtime"], item["shell"], item["pester"], item["index"], item["total"]) for item in self.matrix],
        )
        self.assertIn(EXPECTED_SHA, self.inventory_script)
        for runtime, index, total in (("ps51", 0, 181), ("ps51", 4, 40), ("ps7", 0, 181), ("ps7", 4, 40)):
            result = self.run_inventory(runtime, index, total)
            self.assertEqual(0, result.returncode, result.stderr + result.stdout)
            self.assertIn(f"index={index}/8 files=4 total={total} skipped=0", result.stdout)
        for changed in (names[:-1], names + ["tests/extra.Tests.ps1"], names + [names[0]], names[:-1] + ["tests/changed.Tests.ps1"]):
            result = self.run_inventory("ps7", 0, 181, fake_git_names=changed)
            self.assertNotEqual(0, result.returncode, result.stdout)

    @classmethod
    def run_inventory(cls, runtime: str, index: int, total: int, fake_git_names: list[str] | None = None):
        script = cls.inventory_script
        for key, value in {"shell": "pwsh", "pester": "4.10.1", "runtime": runtime,
                           "index": str(index), "total": str(total)}.items():
            script = script.replace("${{ matrix." + key + " }}", value)
        if fake_git_names is not None:
            names = ",".join("'" + name + "'" for name in fake_git_names)
            script = "function git { $global:LASTEXITCODE = 0; @(" + names + ") }\n" + script
        return subprocess.run(["pwsh", "-NoProfile", "-Command", script], cwd=ROOT,
                              capture_output=True, text=True, timeout=20)


if __name__ == "__main__":
    unittest.main()
