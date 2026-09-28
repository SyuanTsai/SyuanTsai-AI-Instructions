"""Bind a stub raw-call ledger to the existing synthetic bundle contract.

This is an offline consistency check, not a scan executor or trust decision.
It cannot promote fixture responses or synthetic graphs to real evidence.
"""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import sys
from typing import Any

from routine_semantic_candidate import CandidateError, _require
from routine_semantic_offline import read_json, sha256, strict_json_bytes, verify as verify_bundle
from routine_semantic_provider_invocation import canonical, verify_stub_ledger


def bridge(consumer: dict[str, Any], consumer_bytes: bytes,
           prepared: dict[str, Any], prepared_bytes: bytes,
           bundle: dict[str, Any], bundle_bytes: bytes,
           ledger: dict[str, Any], ledger_bytes: bytes) -> dict[str, Any]:
    for document, raw, code in ((consumer, consumer_bytes, "CONSUMER_PLAN"),
                                (prepared, prepared_bytes, "PREPARED_PLAN"),
                                (bundle, bundle_bytes, "BUNDLE"), (ledger, ledger_bytes, "LEDGER")):
        saved = strict_json_bytes(raw, code)
        _require(canonical(saved) == canonical(document), code + "_BYTES_MISMATCH")
    verified = verify_bundle(consumer, consumer_bytes, prepared, bundle, bundle_bytes)
    _require(verify_stub_ledger(ledger), "LEDGER_INVALID")
    _require(ledger["sourceRevision"] == verified["sourceRevision"], "LEDGER_REVISION_MISMATCH")
    if "executionPlan" in prepared:
        execution = prepared["executionPlan"]
        _require(type(execution) is dict and
                 execution.get("workManifestSha256") == ledger["preflightSha256"] and
                 type(execution.get("plannedCalls")) is int and
                 execution["plannedCalls"] == ledger["requestCount"], "PREPARED_WORK_MANIFEST_MISMATCH")
    work = bundle["workItems"]
    _require(len(ledger["calls"]) == len(work), "LEDGER_COVERAGE_INCOMPLETE")
    by_work = {(item["analyzerId"], item["path"]): item for item in work}
    _require(len(by_work) == len(work), "BUNDLE_WORK_DUPLICATE")
    seen: set[tuple[str, str]] = set()
    bindings: list[dict[str, Any]] = []
    for call in ledger["calls"]:
        # Producer call IDs bind prompt bytes; bundle work IDs bind source bytes.
        # Join the analyzer/source pair, then require all raw hashes and bytes.
        key = (call["analyzerId"], call["sourcePath"])
        _require(key in by_work and key not in seen, "LEDGER_WORK_ID_UNKNOWN_OR_DUPLICATE")
        seen.add(key)
        item = by_work[key]
        _require(call["analyzerId"] == item["analyzerId"] and
                 call["sourcePath"] == item["path"] and
                 call["sourceSha256"] == item["selectedBlobSha256"] and
                 call["promptSha256"] == item["promptSha256"] and
                 call["rawResponseSha256"] == item["responseSha256"],
                 "LEDGER_WORK_BINDING_MISMATCH")
        request = json.loads(base64.b64decode(call["requestBodyBase64"], validate=True))
        prompt = request["input"][0]["content"][0]["text"].encode("utf-8")
        _require(base64.b64encode(prompt).decode("ascii") == item["promptBase64"] and
                 call["promptBytes"] == len(prompt) and
                 call["rawResponseBase64"] == item["responseBase64"],
                 "LEDGER_RAW_BYTES_MISMATCH")
        bindings.append({"workItemId": item["id"], "callId": call["callId"], "sequence": call["sequence"],
                         "requestBodySha256": call["requestBodySha256"],
                         "rawResponseSha256": call["rawResponseSha256"],
                         "rawGraphSha256": item["rawGraphSha256"],
                         "rawFindingsSha256": item["rawFindingsSha256"]})
    _require(seen == set(by_work), "LEDGER_WORK_COVERAGE_MISMATCH")
    return {"schemaVersion": 1,
            "artifactType": "routine-semantic-stub-bundle-bridge-v1",
            "consumerPlanSha256": sha256(consumer_bytes),
            "preparedPlanSha256": sha256(prepared_bytes),
            "syntheticBundleSha256": sha256(bundle_bytes),
            "stubLedgerSha256": sha256(ledger_bytes),
            "sourceRevision": verified["sourceRevision"],
            "workItemCount": len(bindings), "bindings": bindings,
            "graphResponseBindingVerified": False,
            "authorizationStatus": "not-evaluated", "scanStatus": "SYNTHETIC",
            "realProviderCalls": 0, "trustStatus": "unverified",
            "ciAdmission": "BLOCKED", "releaseEligible": False}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--prepared", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        _require(not args.output.exists() and not args.output.is_symlink(), "OUTPUT_EXISTS")
        paths = [args.plan, args.prepared, args.bundle, args.ledger, args.output]
        _require(len({str(path.resolve(strict=False)) for path in paths}) == len(paths),
                 "INPUT_OUTPUT_PATH_COLLISION")
        consumer, consumer_bytes = read_json(args.plan, "PLAN")
        prepared, prepared_bytes = read_json(args.prepared, "PREPARED_PLAN")
        bundle, bundle_bytes = read_json(args.bundle, "BUNDLE")
        ledger, ledger_bytes = read_json(args.ledger, "LEDGER")
        result = bridge(consumer, consumer_bytes, prepared, prepared_bytes, bundle, bundle_bytes, ledger, ledger_bytes)
        with args.output.open("xb") as stream:
            stream.write(canonical(result) + b"\n")
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
