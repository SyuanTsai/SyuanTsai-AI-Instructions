"""Version-independent contract tests for the installed scanner inventory probe."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


PROBE = Path(__file__).resolve().parents[1] / "scripts" / "Inspect-InstalledSemanticScanner.py"
SPEC = importlib.util.spec_from_file_location("standard_semantic_inventory_probe", PROBE)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class InstalledSemanticInventoryContract(unittest.TestCase):
    def test_UnitT05_rejects_nonisolated_runtime_before_scanner_import(self) -> None:
        with self.assertRaisesRegex(ValueError, "isolated"):
            module.validate_runtime_isolation("/system/python", "/system/python", 0)

    # Scenario: Every registered semantic module was actually wired into the frozen graph.
    # Purpose: Permit a ready pre-scan probe only for the exact resolved analyzer set.
    def test_UnitT10_accepts_complete_registered_and_wired_set(self) -> None:
        ids = ["semantic_alpha", "semantic_beta"]
        hashes = {identity: "a" * 64 for identity in ids}
        result = module.evaluate_inventory("2.11.2", "2.11.2", ids, ids, hashes)
        self.assertTrue(result["scannerReady"])
        self.assertEqual(result["registeredSemanticAnalyzerIds"], ids)
        self.assertEqual(result["missingWiredAnalyzerIds"], [])

    # Scenario: One registered semantic module was skipped while a static graph could report global complete.
    # Purpose: Stop semantic preparation before mistaking static completeness for full analyzer execution.
    def test_UnitT20_marks_a_skipped_semantic_node_unready(self) -> None:
        ids = ["semantic_alpha", "semantic_beta"]
        hashes = {identity: "b" * 64 for identity in ids}
        result = module.evaluate_inventory("2.11.2", "2.11.2", ids, ["semantic_alpha"], hashes)
        self.assertFalse(result["scannerReady"])
        self.assertEqual(result["missingWiredAnalyzerIds"], ["semantic_beta"])

    # Scenario: The installed distribution differs from the resolver-frozen version, or the registry repeats an ID.
    # Purpose: Prevent a stale or ambiguous graph from being promoted into candidate evidence.
    def test_UnitT30_rejects_version_mismatch_and_duplicate_registration(self) -> None:
        with self.assertRaises(ValueError):
            module.evaluate_inventory("2.11.2", "2.11.3", ["semantic_alpha"], ["semantic_alpha"], {"semantic_alpha": "c" * 64})
        with self.assertRaises(ValueError):
            module.evaluate_inventory("2.11.2", "2.11.2", ["semantic_alpha", "semantic_alpha"], ["semantic_alpha"], {"semantic_alpha": "c" * 64})

    # Scenario: An observer points the probe output at the authority checkout.
    # Purpose: Keep unsigned scanner intermediates outside source and avoid dirtying the candidate.
    def test_UnitT40_rejects_authority_source_as_output_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "authority"
            source.mkdir()
            with self.assertRaises(ValueError):
                module.validate_output_path(source / "probe.json", source)

    # Scenario: PYTHONPATH shadows an installed semantic module with code outside the isolated venv.
    # Purpose: Bind the probe's source hashes to the frozen tool installation rather than import order alone.
    def test_UnitT50_rejects_shadowed_semantic_module_outside_install_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prefix = root / "venv"
            prefix.mkdir()
            shadow = root / "semantic_alpha.py"
            shadow.write_text("ANALYZER_ID = 'semantic_alpha'\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                module.validate_module_source(shadow, prefix)


if __name__ == "__main__":
    unittest.main(verbosity=2)
