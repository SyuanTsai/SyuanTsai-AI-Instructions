"""Verify an offline fake graph bundle and emit a permanently blocked receipt.

This is a candidate evidence interface, not a protected verifier or transport.
It checks complete local bytes but has no trusted signer or CI admission route.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import sys

from routine_semantic_candidate import ANALYZERS, CandidateError, _read_json, _require


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def index_semantic_work(graph: dict, skill: str) -> dict[tuple[str, str], str]:
    """Bind scanner work, terminal rows, calls, and unfiltered findings."""
    completeness = graph.get("analysisCompleteness")
    _require(type(completeness) is dict and completeness.get("status") == "complete"
             and completeness.get("is_complete") is True
             and completeness.get("execution_successful") is True, "RAW_GRAPH_COMPLETENESS")
    for field in ("ledger_exceptions", "limitations", "scope_exclusions"):
        _require(type(completeness.get(field)) is list and not completeness[field],
                 "RAW_GRAPH_COMPLETENESS_EXCEPTION")
    statuses = graph.get("analyzerStatusEvents")
    _require(type(statuses) is list, "RAW_GRAPH_STATUS_LIST")
    semantic_statuses: dict[str, dict] = {}
    for status in statuses:
        _require(type(status) is dict, "RAW_GRAPH_STATUS_INVALID")
        identity = status.get("analyzer_id")
        if type(identity) is str and identity.startswith("semantic_"):
            _require(identity in ANALYZERS and identity not in semantic_statuses,
                     "RAW_GRAPH_STATUS_DUPLICATE_OR_UNKNOWN")
            semantic_statuses[identity] = status
    _require(set(semantic_statuses) == set(ANALYZERS), "RAW_GRAPH_ANALYZER_INCOMPLETE")
    planned: dict[str, tuple[str, str, object, object]] = {}
    work_index: dict[tuple[str, str], str] = {}
    for identity in ANALYZERS:
        status = semantic_statuses[identity]
        work = status.get("planned_work")
        _require(status.get("status") == "completed" and type(work) is list and work,
                 "RAW_GRAPH_WORK_INCOMPLETE")
        for row in work:
            _require(type(row) is dict and type(row.get("work_id")) is str
                     and row["work_id"] and type(row.get("path")) is str
                     and row["path"] and row["path"] == Path(row["path"]).as_posix()
                     and not row["path"].startswith("/")
                     and all(part not in ("", ".", "..") for part in row["path"].split("/")),
                     "RAW_GRAPH_WORK_INVALID")
            work_id = row["work_id"]
            source_path = "skills/" + skill + "/" + row["path"]
            key = (identity, source_path)
            _require(work_id not in planned and key not in work_index,
                     "RAW_GRAPH_WORK_DUPLICATE")
            planned[work_id] = (identity, row["path"], row.get("start_line"), row.get("end_line"))
            work_index[key] = work_id
    ledger = graph.get("inspectionLedger")
    _require(type(ledger) is list and ledger, "RAW_GRAPH_LEDGER_MISSING")
    terminal: set[str] = set()
    emitted: list[str] = []
    for row in ledger:
        _require(type(row) is dict and row.get("phase") != "ledger_output"
                 and row.get("reason_code") != "output_limit", "RAW_GRAPH_LEDGER_TRUNCATED")
        finding_ids = row.get("emitted_finding_ids")
        _require(type(finding_ids) is list and all(type(value) is str and value for value in finding_ids),
                 "RAW_GRAPH_LEDGER_FINDINGS")
        if finding_ids:
            _require(row.get("record_type") == "work_item" and row.get("outcome") == "completed",
                     "RAW_GRAPH_FINDING_PRODUCER")
            emitted.extend(finding_ids)
        if row.get("phase") == "semantic" or str(row.get("analyzer_id", "")).startswith("semantic_"):
            work_id = row.get("work_id")
            _require(type(work_id) is str and work_id in planned and work_id not in terminal
                     and row.get("record_type") == "work_item" and row.get("phase") == "semantic"
                     and row.get("outcome") == "completed" and row.get("reason_code") is None
                     and row.get("input_finding_ids") == []
                     and (row.get("analyzer_id"), row.get("path"), row.get("start_line"),
                          row.get("end_line")) == planned[work_id], "RAW_GRAPH_TERMINAL_WORK")
            terminal.add(work_id)
    _require(terminal == set(planned), "RAW_GRAPH_TERMINAL_COVERAGE")
    calls = graph.get("llmCallLog")
    _require(type(calls) is list, "RAW_GRAPH_CALL_LOG")
    called: set[str] = set()
    aggregate_nodes: set[str] = set()
    for call in calls:
        _require(type(call) is dict and call.get("ok") is True and call.get("error") is None,
                 "RAW_GRAPH_CALL_FAILED")
        identity = call.get("node")
        if type(identity) is str and identity.startswith("semantic_"):
            # SkillSpector 2.12.0's complete graph exposes a node-level LLM
            # outcome; newer graph contracts may include per-work telemetry.
            if "work_id" not in call:
                _require(identity in ANALYZERS and identity not in aggregate_nodes
                         and not any(planned[work_id][0] == identity for work_id in called)
                         and not any(key in call for key in ("path", "start_line", "end_line")),
                         "RAW_GRAPH_CALL_NODE")
                aggregate_nodes.add(identity)
                continue
            work_id = call.get("work_id")
            _require(type(work_id) is str and work_id in planned and work_id not in called
                     and identity not in aggregate_nodes
                     and (identity, call.get("path"), call.get("start_line"),
                          call.get("end_line")) == planned[work_id], "RAW_GRAPH_CALL_WORK")
            called.add(work_id)
    _require(all(identity in aggregate_nodes or
                 {work_id for work_id, value in planned.items() if value[0] == identity}.issubset(called)
                 for identity in ANALYZERS)
             and all(planned[work_id][0] not in aggregate_nodes for work_id in called),
             "RAW_GRAPH_CALL_COVERAGE")
    raw = graph.get("rawFindings")
    _require(type(raw) is list and all(type(item) is dict and type(item.get("finding_id")) is str
                                      and item["finding_id"] for item in raw), "RAW_GRAPH_FINDINGS_INVALID")
    raw_ids = [item["finding_id"] for item in raw]
    _require(len(raw_ids) == len(set(raw_ids)) and len(emitted) == len(set(emitted))
             and set(raw_ids) == set(emitted), "RAW_GRAPH_FINDINGS_UNACCOUNTED")
    for field in ("filteredFindings", "suppressedFindings"):
        view = graph.get(field)
        _require(type(view) is list and all(type(item) is dict and
                 type(item.get("finding_id")) is str and item["finding_id"] in raw_ids
                 for item in view), "RAW_GRAPH_FINDING_VIEW_UNBOUND")
    return work_index


def verify_inactive(preflight_path: Path, graph_directory: Path) -> dict:
    """Independently bind every fake call, graph and finding; never return PASS."""
    preflight, preflight_bytes = _read_json(preflight_path, "PREFLIGHT")
    _require(preflight.get("artifactType") == "routine-semantic-fake-preflight-v1"
             and preflight.get("status") == "READY_FAKE_ONLY"
             and preflight.get("egressAuthorized") is False
             and preflight.get("ciAdmission") == "BLOCKED"
             and preflight.get("releaseEligible") is False, "PREFLIGHT_NOT_FAKE_ONLY")
    expected_calls = preflight.get("calls")
    _require(type(expected_calls) is list and len(expected_calls) == preflight.get("requiredCalls")
             and len(expected_calls) > 0, "PREFLIGHT_CALLS_INVALID")
    expected_by_hash = {item["promptSha256"]: item for item in expected_calls}
    _require(len(expected_by_hash) == len(expected_calls), "PREFLIGHT_PROMPT_DUPLICATE")
    _require(graph_directory.is_dir() and not graph_directory.is_symlink(), "GRAPH_DIR_INVALID")
    manifest_path = graph_directory / "manifest.json"
    manifest, manifest_bytes = _read_json(manifest_path, "GRAPH_MANIFEST")
    _require(manifest.get("schemaVersion") == 2 and type(manifest.get("schemaVersion")) is int
             and manifest.get("artifactType") == "routine-semantic-fake-graph-v2"
             and manifest.get("status") == "FAKE_COMPLETE"
             and manifest.get("sourceRevision") == preflight.get("sourceRevision")
             and manifest.get("preflightPromptManifestSha256") == preflight.get("promptManifestSha256")
             and manifest.get("requiredCalls") == len(expected_calls)
             and manifest.get("actualFakeCalls") == len(expected_calls)
             and type(manifest.get("maximumCalls")) is int
             and manifest.get("maximumCalls") >= len(expected_calls)
             and manifest.get("promptSetExact") is True
             and manifest.get("graphComplete") is True
             and manifest.get("realProviderCalls") == 0
             and manifest.get("egressAuthorized") is False
             and manifest.get("ciAdmission") == "BLOCKED"
             and manifest.get("releaseEligible") is False, "GRAPH_MANIFEST_BINDING")

    actual_calls = manifest.get("calls")
    _require(type(actual_calls) is list and len(actual_calls) == len(expected_calls), "GRAPH_CALL_COUNT")
    seen: set[str] = set()
    filenames = {"manifest.json"}
    for number, call in enumerate(actual_calls, 1):
        _require(type(call) is dict and call.get("sequence") == number
                 and call.get("status") == "FAKE_RESPONSE"
                 and call.get("model") == "gpt-5.6-sol"
                 and call.get("maximumOutputTokens") == 2048, "FAKE_CALL_ROUTE")
        prompt_sha = call.get("promptSha256")
        planned = expected_by_hash.get(prompt_sha)
        _require(planned is not None and prompt_sha not in seen, "FAKE_CALL_SCOPE")
        seen.add(prompt_sha)
        _require(all(call.get(key) == planned.get(match) for key, match in (
            ("promptBytes", "promptBytes"), ("analyzerId", "analyzerId"),
            ("sourcePath", "sourcePath"), ("sourceSha256", "sourceSha256"))),
            "FAKE_CALL_BINDING")
        timeout = call.get("timeoutSecondsRequested")
        _require(timeout is None or (type(timeout) in (int, float)
                                  and math.isfinite(timeout) and 0 < timeout <= 180),
                 "FAKE_CALL_TIMEOUT")
        name = call.get("rawPromptFile")
        _require(type(name) is str and name.startswith("prompt-") and name.endswith(".txt")
                 and name == Path(name).name and name not in filenames, "FAKE_PROMPT_PATH")
        filenames.add(name)
        prompt_path = graph_directory / name
        _require(prompt_path.is_file() and not prompt_path.is_symlink(), "FAKE_PROMPT_MISSING")
        prompt_bytes = prompt_path.read_bytes()
        _require(len(prompt_bytes) == call["promptBytes"] and digest(prompt_bytes) == prompt_sha,
                 "FAKE_PROMPT_CHANGED")
        encoded = call.get("responseBase64")
        _require(type(encoded) is str and 0 < len(encoded) <= 1048576, "FAKE_RESPONSE_BASE64")
        try:
            response = base64.b64decode(encoded, validate=True)
        except (ValueError, base64.binascii.Error) as error:
            raise CandidateError("FAKE_RESPONSE_BASE64") from error
        _require(base64.b64encode(response).decode("ascii") == encoded
                 and len(response) == call.get("responseBytes")
                 and digest(response) == call.get("responseSha256"), "FAKE_RESPONSE_CHANGED")
    _require(seen == set(expected_by_hash), "FAKE_CALL_COVERAGE")

    graphs = manifest.get("graphs")
    _require(type(graphs) is list and len(graphs) > 0, "GRAPH_LIST_EMPTY")
    expected_skills = {item["sourcePath"].split("/")[1] for item in expected_calls}
    _require(len(graphs) == len(expected_skills), "GRAPH_SKILL_COUNT")
    seen_skills: set[str] = set()
    graph_hashes = []
    all_findings = []
    suppressed_count = 0
    graph_call_count = 0
    all_work: dict[tuple[str, str], str] = {}
    for item in graphs:
        _require(type(item) is dict and item.get("skill") in expected_skills
                 and item["skill"] not in seen_skills, "GRAPH_SKILL_SCOPE")
        skill = item["skill"]
        seen_skills.add(skill)
        name = item.get("file")
        _require(name == "graph-" + skill + ".json" and name not in filenames, "GRAPH_PATH_INVALID")
        filenames.add(name)
        graph, raw = _read_json(graph_directory / name, "RAW_GRAPH")
        _require(digest(raw) == item.get("sha256")
                 and graph.get("skill") == skill
                 and graph.get("sourceRevision") == preflight["sourceRevision"]
                 and graph.get("executionSuccessful") is True
                 and type(graph.get("analysisCompleteness")) is dict
                 and graph["analysisCompleteness"].get("is_complete") is True
                 and item.get("analysisComplete") is True, "RAW_GRAPH_INCOMPLETE")
        statuses = {event.get("analyzer_id"): event.get("status")
                    for event in graph.get("analyzerStatusEvents", []) if type(event) is dict}
        _require(all(statuses.get(analyzer) == "completed" for analyzer in ANALYZERS),
                 "RAW_GRAPH_ANALYZER_INCOMPLETE")
        _require(type(graph.get("inspectionLedger")) is list and len(graph["inspectionLedger"]) > 0,
                 "RAW_GRAPH_LEDGER_MISSING")
        work_index = index_semantic_work(graph, skill)
        _require(not set(all_work).intersection(work_index), "GRAPH_WORK_DUPLICATE")
        all_work.update(work_index)
        for key, count_key in (("rawFindings", "rawFindings"),
                               ("filteredFindings", "filteredFindings"),
                               ("suppressedFindings", "suppressedFindings")):
            _require(type(graph.get(key)) is list and len(graph[key]) == item.get(count_key),
                     "RAW_GRAPH_FINDINGS_CHANGED")
        _require(type(graph.get("calls")) is int and graph["calls"] >= 0,
                 "RAW_GRAPH_CALLS")
        graph_call_count += graph["calls"]
        suppressed_count += len(graph["suppressedFindings"])
        graph_hashes.append((name, digest(raw)))
        all_findings.append({"skill": skill, "raw": graph["rawFindings"],
                             "filtered": graph["filteredFindings"],
                             "suppressed": graph["suppressedFindings"]})
    _require(seen_skills == expected_skills and graph_call_count == len(actual_calls),
             "GRAPH_CALL_COVERAGE")
    _require(set(all_work) == {(call["analyzerId"], call["sourcePath"]) for call in actual_calls}
             and len(all_work) == len(actual_calls), "GRAPH_WORK_CALL_COVERAGE")
    _require(all(type(call.get("workId")) is str and
                 call["workId"] == all_work[(call["analyzerId"], call["sourcePath"])]
                 for call in actual_calls), "GRAPH_CALL_WORK_BINDING")
    _require({path.name for path in graph_directory.iterdir()} == filenames
             and all(path.is_file() and not path.is_symlink() for path in graph_directory.iterdir()),
             "GRAPH_DIRECTORY_EXTRA_OR_MISSING")
    return {
        "schemaVersion": 1, "artifactType": "routine-semantic-inactive-receipt-v1",
        "sourceRevision": preflight["sourceRevision"],
        "sourceInventorySha256": preflight["sourceInventorySha256"],
        "promptManifestSha256": preflight["promptManifestSha256"],
        "preflightSha256": digest(preflight_bytes),
        "fakeGraphManifestSha256": digest(manifest_bytes),
        "graphSetSha256": digest(canonical(sorted(graph_hashes))),
        "allFindingsSha256": digest(canonical(sorted(all_findings, key=lambda x: x["skill"]))),
        "verifiedFakeCalls": len(actual_calls), "verifiedGraphs": len(graphs),
        "suppressedFindings": suppressed_count,
        "protectedSignaturePresent": False, "authenticatedTransport": False,
        "authorizationStatus": "fixture-only", "scanStatus": "SYNTHETIC",
        "trustStatus": "unverified", "ciAdmission": "BLOCKED",
        "releaseEligible": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight", type=Path, required=True)
    parser.add_argument("--graph-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify_inactive(args.preflight, args.graph_directory)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, ensure_ascii=False, separators=(",", ":"))
            stream.write("\n")
    except (CandidateError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
