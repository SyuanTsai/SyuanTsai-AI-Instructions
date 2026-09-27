"""Regenerate deterministic development-only consumer and raw bundle fixtures."""

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from test_routine_semantic_offline import RoutineSemanticOfflineTests  # noqa: E402

case = RoutineSemanticOfflineTests("test_InterT10_verifies_complete_synthetic_bundle_with_dual_identity")
case.setUp()
try:
    target = Path(__file__).resolve().parent
    (target / "consumer-plan.json").write_bytes(case.plan_path.read_bytes())
    (target / "synthetic-bundle.json").write_text(json.dumps(case.bundle), encoding="utf-8")
finally:
    case.doCleanups()
