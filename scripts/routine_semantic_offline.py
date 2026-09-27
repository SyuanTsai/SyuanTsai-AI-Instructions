"""Offline verification of development-only routine semantic fixture bundles.

This verifier checks two candidate identity namespaces and complete synthetic
work coverage. It never grants production CI admission or release eligibility.
It does not verify a protected signer, effective model context, or real scan.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


ANALYZERS = (
    "semantic_developer_intent",
    "semantic_quality_policy",
    "semantic_security_discovery",
)
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX32 = re.compile(r"[0-9a-f]{32}\Z")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require(condition: bool, code: str) -> None:
    if not condition:
        raise ValueError(code)


def exact_keys(value: Any, names: set[str], code: str) -> dict[str, Any]:
    require(type(value) is dict and set(value) == names, code)
    return value


def strict_json_bytes(data: bytes, code: str) -> dict[str, Any]:
    def unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        seen: set[str] = set()
        for key, value in pairs:
            folded = key.casefold()
            if folded in seen:
                raise ValueError(code + "_DUPLICATE_PROPERTY")
            seen.add(folded)
            result[key] = value
        return result

    def reject_constant(_: str) -> None:
        raise ValueError(code + "_NONFINITE_NUMBER")

    try:
        value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique_pairs, parse_constant=reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(code + "_INVALID_JSON") from error
    require(type(value) is dict, code + "_NOT_OBJECT")
    return value


def read_json(path: Path, code: str) -> tuple[dict[str, Any], bytes]:
    require(path.is_file() and not path.is_symlink(), code + "_MISSING_OR_UNSAFE")
    data = path.read_bytes()
    require(0 < len(data) <= 16777216, code + "_SIZE")
    return strict_json_bytes(data, code), data


def hex_value(value: Any, pattern: re.Pattern[str], code: str) -> str:
    require(type(value) is str and pattern.fullmatch(value) is not None, code)
    return value


def raw_payload(item: dict[str, Any], stem: str) -> bytes:
    encoded = item[stem + "Base64"]
    expected = hex_value(item[stem + "Sha256"], HEX64, "RAW_HASH_INVALID")
    require(type(encoded) is str and len(encoded) <= 1048576, "RAW_BASE64_INVALID")
    try:
        data = base64.b64decode(encoded, validate=True)
        require(base64.b64encode(data).decode("ascii") == encoded, "RAW_BASE64_NONCANONICAL")
        data.decode("utf-8", errors="strict")
    except (ValueError, UnicodeDecodeError) as error:
        raise ValueError("RAW_BYTES_INVALID") from error
    require(0 < len(data) <= 524288 and sha256(data) == expected, "RAW_HASH_MISMATCH")
    return data


def verify(consumer: dict[str, Any], consumer_bytes: bytes, prepared: dict[str, Any], bundle: dict[str, Any], bundle_bytes: bytes) -> dict[str, Any]:
    require(consumer.get("schemaVersion") == 1 and type(consumer.get("schemaVersion")) is int, "CONSUMER_VERSION")
    require(consumer.get("artifactType") == "standard-validation-consumer-run-plan-v1", "CONSUMER_TYPE")
    run_id = hex_value(consumer.get("runId"), HEX32, "CONSUMER_RUN_ID")
    source = consumer.get("source")
    candidate = consumer.get("candidate")
    require(type(source) is dict and type(candidate) is dict, "CONSUMER_BINDINGS")
    revision = hex_value(source.get("revision"), HEX40, "CONSUMER_REVISION")
    repository = source.get("repository")
    require(type(repository) is str and repository.startswith("https://") and repository.endswith(".git"), "CONSUMER_REPOSITORY")
    consumer_id = hex_value(candidate.get("candidateId"), HEX64, "CONSUMER_CANDIDATE_ID")
    consumer_content = hex_value(candidate.get("contentSha256"), HEX64, "CONSUMER_CONTENT_SHA")
    consumer_sha = sha256(consumer_bytes)

    exact_keys(bundle, {"schemaVersion", "artifactType", "consumerPlanSha256", "producerPlan", "requiredAnalyzerIds", "workItems"}, "BUNDLE_FIELDS")
    require(bundle["schemaVersion"] == 1 and type(bundle["schemaVersion"]) is int, "BUNDLE_VERSION")
    require(bundle["artifactType"] == "routine-semantic-synthetic-bundle-v1", "BUNDLE_TYPE")
    require(bundle["consumerPlanSha256"] == consumer_sha, "CONSUMER_PLAN_REPLAY")
    producer = bundle["producerPlan"]
    # Compare decoded JSON with types preserved. Formatting may differ when a
    # synthetic bundle embeds the saved Prepare output; its decision may not.
    canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    require(canonical(prepared) == canonical(producer), "PREPARED_PLAN_MISMATCH")
    require(type(producer) is dict and producer.get("artifactType") == "routine-semantic-prepared-plan-v1", "PRODUCER_PLAN_TYPE")
    require(producer.get("schemaVersion") == 1 and type(producer.get("schemaVersion")) is int, "PRODUCER_PLAN_VERSION")
    producer_id = hex_value(producer.get("candidateId"), HEX64, "PRODUCER_CANDIDATE_ID")
    authority = producer.get("authority")
    inventory = producer.get("sourceInventory")
    decision = producer.get("decision")
    binding = producer.get("consumerBinding")
    require(all(type(value) is dict for value in (authority, inventory, decision, binding)), "PRODUCER_BINDINGS")
    require(authority.get("repository") == repository and authority.get("sourceRevision") == revision, "SOURCE_BINDING_MISMATCH")
    require(inventory.get("sourceRevision") == revision, "INVENTORY_REVISION_MISMATCH")
    require(binding.get("runId") == run_id and binding.get("candidateId") == consumer_id and binding.get("contentSha256") == consumer_content and binding.get("sourceRevision") == revision and binding.get("consumerPlanSha256") == consumer_sha, "CONSUMER_IDENTITY_MISMATCH")
    require(decision.get("candidateId") == producer_id and decision.get("inputInventorySha256") == inventory.get("inputInventorySha256"), "PRODUCER_IDENTITY_MISMATCH")
    require(decision.get("status") == "PREPARED_FIXTURE_ONLY" and decision.get("scopeAllowed") is True and decision.get("egressAuthorized") is False, "FIXTURE_DECISION_REQUIRED")
    require(producer.get("payloadComplete") is False and producer.get("scanStatus") == "NOT_RUN" and producer.get("ciAdmission") == "BLOCKED" and producer.get("releaseEligible") is False, "PREPARED_STATUS_INVALID")

    files = inventory.get("files")
    require(type(files) is list and len(files) > 0, "INVENTORY_EMPTY")
    selected: dict[str, str] = {}
    total = 0
    lines = ["routine-semantic-git-inventory-v1", revision]
    for item in files:
        exact_keys(item, {"path", "gitBlobSha1", "bytes", "sha256"}, "INVENTORY_FILE_FIELDS")
        path = item["path"]
        require(type(path) is str and path.startswith("skills/") and path not in selected and ".." not in path.split("/") and "\x00" not in path, "INVENTORY_FILE_PATH")
        blob = hex_value(item["gitBlobSha1"], HEX40, "INVENTORY_BLOB_ID")
        file_sha = hex_value(item["sha256"], HEX64, "INVENTORY_FILE_SHA")
        size = item["bytes"]
        require(type(size) is int and size >= 0, "INVENTORY_FILE_SIZE")
        total += size
        selected[path] = file_sha
        lines.append(f"{path}\t{blob}\t{size}\t{file_sha}")
    require(total == inventory.get("sourceBytes") and type(inventory.get("sourceBytes")) is int, "INVENTORY_TOTAL_MISMATCH")
    require(list(selected) == sorted(selected), "INVENTORY_ORDER_INVALID")
    inventory_sha = sha256("\n".join(lines).encode("utf-8"))
    require(inventory.get("inputInventorySha256") == inventory_sha, "INVENTORY_SHA_MISMATCH")

    required = bundle["requiredAnalyzerIds"]
    require(type(required) is list and set(required) == set(ANALYZERS) and len(required) == len(ANALYZERS), "ANALYZER_SET_INCOMPLETE")
    work = bundle["workItems"]
    require(type(work) is list and len(work) == len(ANALYZERS) * len(selected), "WORK_COUNT_INCOMPLETE")
    seen: set[tuple[str, str]] = set()
    for item in work:
        exact_keys(item, {"id", "analyzerId", "path", "selectedBlobSha256", "promptBase64", "promptSha256", "responseBase64", "responseSha256", "rawGraphBase64", "rawGraphSha256", "rawFindingsBase64", "rawFindingsSha256"}, "WORK_FIELDS")
        analyzer = item["analyzerId"]
        path = item["path"]
        require(analyzer in ANALYZERS and path in selected and (analyzer, path) not in seen, "WORK_SCOPE_INVALID")
        seen.add((analyzer, path))
        require(item["selectedBlobSha256"] == selected[path], "WORK_BLOB_MISMATCH")
        expected_id = sha256(f"{analyzer}\n{path}\n{selected[path]}".encode("utf-8"))
        require(item["id"] == expected_id, "WORK_ID_MISMATCH")
        raw_payload(item, "prompt")
        raw_payload(item, "response")
        graph = strict_json_bytes(raw_payload(item, "rawGraph"), "RAW_GRAPH")
        findings = strict_json_bytes(raw_payload(item, "rawFindings"), "RAW_FINDINGS")
        require(graph.get("artifactType") == "synthetic-raw-graph-v1" and graph.get("workItemId") == expected_id and graph.get("analyzerId") == analyzer, "RAW_GRAPH_BINDING")
        require(findings.get("workItemId") == expected_id and type(findings.get("findings")) is list, "RAW_FINDINGS_BINDING")
    require(seen == {(analyzer, path) for analyzer in ANALYZERS for path in selected}, "WORK_COVERAGE_INCOMPLETE")

    return {
        "schemaVersion": 1,
        "artifactType": "routine-semantic-ci-verification-v1",
        "sourceRevision": revision,
        "candidateId": consumer_id,
        "candidateInventorySha256": consumer_content,
        "resolutionRunId": run_id,
        "producerCandidateId": producer_id,
        "selectedBlobInventorySha256": inventory_sha,
        "receiptBundleSha256": sha256(bundle_bytes),
        "authorizationStatus": "fixture-only",
        "scanStatus": "SYNTHETIC",
        "trustStatus": "unverified",
        "ciAdmission": "BLOCKED",
        "plannedWorkItemCount": len(work),
        "successfulProviderCallCount": 0,
        "analyzers": [{"id": analyzer, "status": "synthetic", "workItemCount": len(selected)} for analyzer in ANALYZERS],
        "releaseEligible": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("verify",))
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--prepared", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        require(not args.output.exists() and not args.output.is_symlink(), "OUTPUT_EXISTS")
        consumer, consumer_bytes = read_json(args.plan, "CONSUMER_PLAN")
        prepared, _ = read_json(args.prepared, "PREPARED_PLAN")
        bundle, bundle_bytes = read_json(args.bundle, "BUNDLE")
        result = verify(consumer, consumer_bytes, prepared, bundle, bundle_bytes)
        encoded = (json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with args.output.open("xb") as stream:
            stream.write(encoded)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
