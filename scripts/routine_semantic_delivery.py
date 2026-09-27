"""Inactive routine semantic delivery manifest and fail-closed verifier.

The expected manifest digest is an independent input supplied by a protected
caller. This module cannot issue that input or authenticate its custody.
Successful local verification is therefore never CI admission.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


HEX32 = re.compile(r"[0-9a-f]{32}\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
ARTIFACT_KEYS = ("consentRequestPath", "consentDecisionPath", "evidencePath", "publicKeyPath")
MAX_INPUT = 16 * 1024 * 1024
MAX_CLOSURE_FILE = 256 * 1024 * 1024
TOOL_STEMS = ("policyReceipt", "toolchain", "childRunner", "preparationHelper", "preparation", "adapter")


def require(condition: bool, code: str) -> None:
    if not condition:
        raise ValueError(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def read_bytes(path: Path, code: str) -> bytes:
    require(path.is_file() and not path.is_symlink(), code + "_MISSING_OR_UNSAFE")
    size = path.stat().st_size
    require(0 < size <= MAX_INPUT, code + "_SIZE")
    return path.read_bytes()


def read_json(path: Path, code: str) -> tuple[dict[str, Any], bytes]:
    data = read_bytes(path, code)

    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        seen: set[str] = set()
        for key, value in pairs:
            folded = key.casefold()
            require(folded not in seen, code + "_DUPLICATE_KEY")
            seen.add(folded)
            result[key] = value
        return result

    def invalid_constant(_: str) -> None:
        raise ValueError(code + "_NONFINITE")

    try:
        value = json.loads(data.decode("utf-8", "strict"), object_pairs_hook=unique, parse_constant=invalid_constant)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(code + "_INVALID_JSON") from error
    require(type(value) is dict, code + "_NOT_OBJECT")
    return value, data


def exact(value: Any, keys: set[str], code: str) -> dict[str, Any]:
    require(type(value) is dict and set(value) == keys, code)
    return value


def hexdigest(value: Any, pattern: re.Pattern[str], code: str) -> str:
    require(type(value) is str and pattern.fullmatch(value) is not None, code)
    return value


def utc(value: Any, code: str) -> datetime:
    require(type(value) is str and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value) is not None, code)
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise ValueError(code) from error


def absolute_file(path_text: Any, code: str) -> Path:
    require(type(path_text) is str and path_text and "\x00" not in path_text, code)
    path = Path(path_text)
    require(path.is_absolute(), code + "_NOT_ABSOLUTE")
    return path


def verify_file_hash(path_text: Any, expected: Any, code: str) -> None:
    path = absolute_file(path_text, code + "_PATH")
    expected_sha = hexdigest(expected, HEX64, code + "_SHA256")
    require(path.is_file() and not path.is_symlink() and path.resolve(strict=True) == path,
            code + "_MISSING_OR_UNSAFE")
    size = path.stat().st_size
    require(0 < size <= MAX_CLOSURE_FILE, code + "_SIZE")
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    require(hasher.hexdigest() == expected_sha, code + "_HASH_MISMATCH")


def prepare_bindings(plan: dict[str, Any], plan_data: bytes, prepared: dict[str, Any], prepared_data: bytes,
                     bundle_path: Path) -> dict[str, Any]:
    require(plan.get("schemaVersion") == 1 and type(plan.get("schemaVersion")) is int and
            plan.get("artifactType") == "standard-validation-consumer-run-plan-v1", "PLAN_TYPE")
    require(prepared.get("schemaVersion") == 1 and type(prepared.get("schemaVersion")) is int and
            prepared.get("artifactType") == "routine-semantic-prepared-plan-v1", "PREPARED_TYPE")
    source, candidate, authority, tools, semantic = (plan.get(key) for key in
        ("source", "candidate", "authority", "tools", "semantic"))
    require(all(type(value) is dict for value in (source, candidate, authority, tools, semantic)), "PLAN_CLOSURE_MISSING")
    run_id = hexdigest(plan.get("runId"), HEX32, "RUN_ID")
    revision = hexdigest(source.get("revision"), HEX40, "SOURCE_REVISION")
    base = hexdigest(source.get("baseRevision"), HEX40, "SOURCE_BASE")
    tree = hexdigest(source.get("tree"), HEX40, "SOURCE_TREE")
    consumer_id = hexdigest(candidate.get("candidateId"), HEX64, "CONSUMER_ID")
    content = hexdigest(candidate.get("contentSha256"), HEX64, "CONSUMER_CONTENT")
    producer_id = hexdigest(prepared.get("candidateId"), HEX64, "PRODUCER_ID")
    inventory = prepared.get("sourceInventory")
    binding = prepared.get("consumerBinding")
    delivery_binding = prepared.get("deliveryBinding")
    require(type(inventory) is dict and type(binding) is dict and type(delivery_binding) is dict,
            "PRODUCER_BINDING_MISSING")
    inventory_sha = hexdigest(inventory.get("inputInventorySha256"), HEX64, "PRODUCER_INVENTORY")
    require(binding.get("runId") == run_id and binding.get("candidateId") == consumer_id and
            binding.get("contentSha256") == content and binding.get("sourceRevision") == revision and
            binding.get("consumerPlanSha256") == digest(plan_data), "PRODUCER_CONSUMER_MISMATCH")
    require(prepared.get("ciAdmission") == "BLOCKED" and prepared.get("releaseEligible") is False,
            "PREPARED_MUST_BE_BLOCKED")
    require(prepared.get("authority", {}).get("sourceRevision") == revision and
            prepared.get("authority", {}).get("repository") == source.get("repository"), "PRODUCER_SOURCE_MISMATCH")
    archive_sha = hexdigest(authority.get("archiveSha256"), HEX64, "AUTHORITY_ARCHIVE")
    runner_sha = hexdigest(authority.get("runnerSha256"), HEX64, "AUTHORITY_RUNNER")
    for name in ("archivePath", "runnerPath"):
        absolute_file(authority.get(name), "AUTHORITY_" + name.upper())
    verify_file_hash(authority.get("archivePath"), archive_sha, "AUTHORITY_ARCHIVE")
    verify_file_hash(authority.get("runnerPath"), runner_sha, "AUTHORITY_RUNNER")
    require(type(authority.get("revision")) is str and authority["revision"], "AUTHORITY_REVISION")
    required_tool_fields = {name for stem in TOOL_STEMS for name in (stem + "Path", stem + "Sha256")}
    required_tool_fields.add("receipts")
    require(set(tools) == required_tool_fields, "TOOLS_FIELDS")
    tool_receipt_sha = hexdigest(tools.get("policyReceiptSha256"), HEX64, "TOOL_POLICY_RECEIPT")
    for stem in TOOL_STEMS:
        verify_file_hash(tools.get(stem + "Path"), tools.get(stem + "Sha256"), "TOOL_" + stem.upper())
    receipts = tools.get("receipts")
    require(type(receipts) is list and len(receipts) == 4, "TOOL_RECEIPTS_MISSING")
    seen_tools: set[str] = set()
    for receipt in receipts:
        require(type(receipt) is dict and set(receipt) == {"tool", "path", "sha256"} and
                type(receipt["tool"]) is str and receipt["tool"] and receipt["tool"] not in seen_tools,
                "TOOL_RECEIPT_FIELDS")
        seen_tools.add(receipt["tool"])
        verify_file_hash(receipt["path"], receipt["sha256"], "TOOL_RECEIPT")
    require(seen_tools == {"skillspector", "skill-validator", "skill-tools", "pester"}, "TOOL_RECEIPTS_SCOPE")
    expected_binding = {
        "runId": run_id, "consumerPlanSha256": digest(plan_data), "sourceRevision": revision,
        "sourceBaseRevision": base, "sourceTree": tree, "consumerCandidateId": consumer_id,
        "consumerContentSha256": content, "authorityArchiveSha256": archive_sha,
        "authorityRunnerSha256": runner_sha, "toolPolicyReceiptSha256": tool_receipt_sha,
        "publicKeyId": semantic.get("publicKeyId"),
        "artifacts": {key: semantic.get(key) for key in ARTIFACT_KEYS},
    }
    require(delivery_binding == expected_binding, "PREPARED_DELIVERY_BINDING_MISMATCH")
    artifacts: dict[str, dict[str, str]] = {}
    paths: set[Path] = set()
    for name in ARTIFACT_KEYS:
        path = absolute_file(semantic.get(name), "SEMANTIC_" + name.upper())
        require(path.is_file() and not path.is_symlink(), "ARTIFACT_" + name.upper() + "_MISSING_OR_UNSAFE")
        resolved = path.resolve(strict=True)
        require(resolved == path and resolved not in paths, "ARTIFACT_PATH_UNSAFE_OR_DUPLICATE")
        paths.add(resolved)
        artifacts[name] = {"path": str(path), "sha256": digest(read_bytes(path, "ARTIFACT_" + name.upper()))}
    require(type(semantic.get("publicKeyId")) is str and semantic["publicKeyId"], "PUBLIC_KEY_ID")
    require(bundle_path.is_file() and not bundle_path.is_symlink(), "BUNDLE_MISSING_OR_UNSAFE")
    bundle = bundle_path.resolve(strict=True)
    require(bundle == bundle_path and bundle not in paths, "BUNDLE_PATH_UNSAFE")
    return {
        "runId": run_id,
        "consumerPlanSha256": digest(plan_data),
        "source": {"repository": source.get("repository"), "revision": revision, "baseRevision": base, "tree": tree},
        "consumerCandidate": {"candidateId": consumer_id, "contentSha256": content},
        "producerCandidate": {"candidateId": producer_id, "inputInventorySha256": inventory_sha,
                              "preparedPlanSha256": digest(prepared_data)},
        "closure": {"authorityRevision": authority["revision"], "authorityArchivePath": authority["archivePath"],
                    "authorityArchiveSha256": archive_sha, "runnerPath": authority["runnerPath"],
                    "runnerSha256": runner_sha, "authoritySha256": digest(canonical(authority)),
                    "toolsSha256": digest(canonical(tools))},
        "bundle": {"path": str(bundle_path), "sha256": digest(read_bytes(bundle_path, "BUNDLE"))},
        "publicKeyId": semantic["publicKeyId"],
        "artifacts": artifacts,
    }


def build(plan_path: Path, prepared_path: Path, bundle_path: Path, issued: str, expires: str) -> dict[str, Any]:
    plan, plan_data = read_json(plan_path, "PLAN")
    prepared, prepared_data = read_json(prepared_path, "PREPARED")
    start, end = utc(issued, "ISSUED_AT"), utc(expires, "EXPIRES_AT")
    require(start < end and (end - start).total_seconds() <= 3600, "DELIVERY_LEASE_INVALID")
    result = prepare_bindings(plan, plan_data, prepared, prepared_data, bundle_path)
    return {"schemaVersion": 1, "artifactType": "routine-semantic-delivery-manifest-v1",
            "issuedAtUtc": issued, "expiresAtUtc": expires, **result}


def verify(plan_path: Path, prepared_path: Path, bundle_path: Path, manifest_path: Path,
           protected_expected_path: Path, claim_path: Path, now: datetime) -> dict[str, Any]:
    inputs = [plan_path, prepared_path, bundle_path, manifest_path, protected_expected_path, claim_path]
    require(len({str(path.resolve(strict=False)) for path in inputs}) == len(inputs), "INPUT_PATH_COLLISION")
    require(claim_path.is_absolute() and claim_path.parent.is_dir() and not claim_path.parent.is_symlink(),
            "DELIVERY_CLAIM_PATH_UNSAFE")
    consumer, _ = read_json(plan_path, "PLAN")
    execution = consumer.get("execution")
    if type(execution) is dict and execution.get("consumptionClaimPath") is not None:
        resume_claim = absolute_file(execution["consumptionClaimPath"], "RESUME_CLAIM")
        require(claim_path.resolve(strict=False) != resume_claim.resolve(strict=False),
                "DELIVERY_CLAIM_COLLIDES_WITH_RESUME")
    expected, _ = read_json(protected_expected_path, "PROTECTED_EXPECTED")
    exact(expected, {"schemaVersion", "artifactType", "runId", "consumerPlanSha256", "manifestSha256"}, "EXPECTED_FIELDS")
    require(expected["schemaVersion"] == 1 and type(expected["schemaVersion"]) is int and
            expected["artifactType"] == "routine-semantic-protected-expected-v1", "EXPECTED_TYPE")
    expected_sha = hexdigest(expected["manifestSha256"], HEX64, "EXPECTED_DIGEST")
    manifest, manifest_data = read_json(manifest_path, "MANIFEST")
    require(digest(manifest_data) == expected_sha, "MANIFEST_PROTECTED_DIGEST_MISMATCH")
    exact(manifest, {"schemaVersion", "artifactType", "issuedAtUtc", "expiresAtUtc", "runId",
                     "consumerPlanSha256", "source", "consumerCandidate", "producerCandidate", "closure",
                     "bundle", "publicKeyId", "artifacts"}, "MANIFEST_FIELDS")
    require(manifest["schemaVersion"] == 1 and type(manifest["schemaVersion"]) is int and
            manifest["artifactType"] == "routine-semantic-delivery-manifest-v1", "MANIFEST_TYPE")
    issued, expires = utc(manifest["issuedAtUtc"], "ISSUED_AT"), utc(manifest["expiresAtUtc"], "EXPIRES_AT")
    require(issued <= now < expires and 0 < (expires - issued).total_seconds() <= 3600, "DELIVERY_EXPIRED_OR_FUTURE")
    fresh = build(plan_path, prepared_path, bundle_path, manifest["issuedAtUtc"], manifest["expiresAtUtc"])
    control_paths = {path.resolve(strict=False) for path in inputs}
    require(all(Path(item["path"]).resolve(strict=False) not in control_paths
                for item in fresh["artifacts"].values()), "ARTIFACT_CONTROL_PATH_COLLISION")
    require(manifest == fresh and canonical(manifest) == canonical(fresh), "DELIVERY_BINDING_MISMATCH")
    require(expected["runId"] == fresh["runId"] and
            expected["consumerPlanSha256"] == fresh["consumerPlanSha256"], "PROTECTED_RUN_MISMATCH")
    require(not claim_path.exists() and not claim_path.is_symlink(), "DELIVERY_REPLAY")
    claim = {"schemaVersion": 1, "artifactType": "routine-semantic-delivery-claim-v1",
             "runId": fresh["runId"], "manifestSha256": expected_sha}
    with claim_path.open("xb") as stream:
        stream.write(canonical(claim) + b"\n")
    return {"schemaVersion": 1, "artifactType": "routine-semantic-delivery-verification-v1",
            "runId": fresh["runId"], "consumerPlanSha256": fresh["consumerPlanSha256"],
            "manifestSha256": expected_sha, "bundleSha256": fresh["bundle"]["sha256"],
            "artifactSha256": {key: fresh["artifacts"][key]["sha256"] for key in ARTIFACT_KEYS},
            "bindingStatus": "MATCHED_LOCAL_CANDIDATE", "trustStatus": "unverified",
            "ciAdmission": "BLOCKED", "releaseEligible": False, "realProviderCalls": 0}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("build", "verify"))
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--prepared", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--issued-at")
    parser.add_argument("--expires-at")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--protected-expected", type=Path)
    parser.add_argument("--claim", type=Path)
    args = parser.parse_args()
    try:
        require(not args.output.exists() and not args.output.is_symlink(), "OUTPUT_EXISTS")
        control = [args.plan, args.prepared, args.bundle]
        if args.mode == "verify":
            control.extend(path for path in (args.manifest, args.protected_expected, args.claim) if path is not None)
        require(args.output.resolve(strict=False) not in {path.resolve(strict=False) for path in control},
                "OUTPUT_INPUT_PATH_COLLISION")
        if args.mode == "build":
            require(args.issued_at is not None and args.expires_at is not None, "LEASE_INPUT_MISSING")
            result = build(args.plan, args.prepared, args.bundle, args.issued_at, args.expires_at)
        else:
            require(args.manifest is not None and args.protected_expected is not None and args.claim is not None,
                    "VERIFY_INPUT_MISSING")
            result = verify(args.plan, args.prepared, args.bundle, args.manifest, args.protected_expected,
                            args.claim, datetime.now(timezone.utc))
        with args.output.open("xb") as stream:
            stream.write(canonical(result) + b"\n")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
