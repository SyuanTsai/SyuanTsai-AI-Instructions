"""Normalize frozen SkillSpector raw graph states into an unsigned scan input.

This pure adapter neither invokes a provider nor authenticates candidate, tool,
scope, consent or signer. A protected supervisor must supply and verify those
inputs and retain the raw graph states before any formal receipt is considered.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping, Sequence
from hashlib import sha256
import json
from pathlib import Path
import re
from typing import Any


SHA256 = re.compile(r"^[0-9a-f]{64}$")
SKILL_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ANALYZER_ID = re.compile(r"^semantic_[a-z0-9_]+$")
SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL"}


def _identities(values: Sequence[str], pattern: re.Pattern[str], context: str) -> list[str]:
    if isinstance(values, (str, bytes)) or not isinstance(values, Sequence) or not values:
        raise ValueError(f"{context} must be a non-empty identity list")
    items = list(values)
    if any(not isinstance(item, str) or not pattern.fullmatch(item) for item in items):
        raise ValueError(f"{context} contains an invalid identity")
    if len(items) != len(set(items)):
        raise ValueError(f"{context} contains duplicate identities")
    return sorted(items)


def _scalar(value: Any, context: str) -> str:
    if (
        not isinstance(value, str) or not value.strip() or len(value) > 4096
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError(f"{context} must be a non-empty bounded string")
    return value


def _component_paths(values: Any) -> list[str]:
    paths = _identities(
        _list(values, "LLM components"),
        re.compile(r"^[^/\\\x00-\x1f]+(?:/[^/\\\x00-\x1f]+)*$"),
        "LLM components",
    )
    if any(any(part in (".", "..") for part in path.split("/")) for path in paths):
        raise ValueError("LLM component path has ambiguous or parent segments")
    return paths


def _list(value: Any, context: str) -> list[Any]:
    if not isinstance(value, list):
        raise ValueError(f"{context} must be an explicit list")
    return value


def _mapping(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ValueError(f"{context} must be a structured map")
    return value


def _package_path(value: Any, context: str) -> Path:
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise ValueError(f"{context} must be an absolute package directory")
    path = Path(value)
    if not path.is_dir():
        raise ValueError(f"{context} does not exist as a package directory")
    for entry in (path, *path.parents):
        if entry.exists() and (
            entry.is_symlink() or (hasattr(entry, "is_junction") and entry.is_junction())
        ):
            raise ValueError(f"{context} uses a linked or junction path")
    return path.resolve(strict=True)


def _assert_source_binding(
    skill_id: str, state: Mapping[str, Any], expected_path: Any,
    expected_files: Mapping[str, Any],
) -> dict[str, bytes]:
    package = _package_path(expected_path, f"{skill_id} expected source")
    for field in ("input_path", "skill_path"):
        observed = _package_path(state.get(field), f"{skill_id} graph {field}")
        if observed != package:
            raise ValueError("raw graph was executed against a different Skill package")
    manifest = _mapping(expected_files, f"{skill_id} committed source manifest")
    paths = _component_paths(list(manifest))
    actual_files = {}
    for entry in package.rglob("*"):
        if entry.is_symlink() or (hasattr(entry, "is_junction") and entry.is_junction()):
            raise ValueError("Skill source package contains a linked or junction entry")
        if entry.is_file():
            actual_files[entry.relative_to(package).as_posix()] = entry
        elif not entry.is_dir():
            raise ValueError("Skill source package contains a non-regular entry")
    if set(actual_files) != set(paths):
        raise ValueError("Skill package files differ from committed source manifest")
    raw_cache = _mapping(state.get("raw_file_cache"), f"{skill_id} raw byte cache")
    if set(raw_cache) != set(paths):
        raise ValueError("raw graph cache differs from committed source file set")
    verified_source: dict[str, bytes] = {}
    for path in paths:
        descriptor = _mapping(manifest[path], f"{skill_id} source descriptor")
        digest, size = descriptor.get("sha256"), descriptor.get("bytes")
        if (
            set(descriptor) != {"sha256", "bytes"}
            or not isinstance(digest, str) or not SHA256.fullmatch(digest)
            or not isinstance(size, int) or isinstance(size, bool) or size < 0
            or not isinstance(raw_cache[path], bytes)
        ):
            raise ValueError("committed source descriptor or raw byte cache is invalid")
        source_bytes = actual_files[path].read_bytes()
        raw_bytes = raw_cache[path]
        if (
            len(source_bytes) != size or sha256(source_bytes).hexdigest() != digest
            or len(raw_bytes) != size or sha256(raw_bytes).hexdigest() != digest
        ):
            raise ValueError("Skill package or graph raw cache bytes differ from committed source")
        verified_source[path] = raw_bytes
    return verified_source


def _finding(item: Any, skill_id: str) -> tuple[str, dict[str, str]]:
    finding_id = _scalar(getattr(item, "finding_id", None), "raw finding ID")
    severity = _scalar(getattr(item, "severity", None), "raw finding severity").upper()
    if severity not in SEVERITIES:
        raise ValueError("raw finding has an unknown severity")
    path = _scalar(getattr(item, "file", None), "raw finding path")
    rule_id = _scalar(getattr(item, "rule_id", None), "raw finding rule ID")
    message = _scalar(getattr(item, "message", None), "raw finding message")
    canonical = {
        "severity": severity.lower(), "ruleId": rule_id,
        "message": message, "path": f"{skill_id}/{path}",
    }
    fingerprint = getattr(item, "fingerprint", None)
    if callable(fingerprint):
        value = fingerprint()
        if value is not None:
            canonical["fingerprint"] = _scalar(value, "raw finding fingerprint")
    return finding_id, canonical


def _normalize_skill(
    skill_id: str, graph_state: Mapping[str, Any], analyzer_ids: list[str],
    expected_path: Any, expected_files: Mapping[str, Any],
    expected_provider_components: Any,
) -> tuple[dict[str, list[dict[str, str]]], list[dict[str, Any]]]:
    state = _mapping(graph_state, f"{skill_id} raw graph")
    verified_source = _assert_source_binding(skill_id, state, expected_path, expected_files)
    completeness = _mapping(state.get("analysis_completeness"), "graph completeness")
    if (
        state.get("use_llm") is not True
        or state.get("execution_successful") is not True
        or completeness.get("status") != "complete"
        or completeness.get("is_complete") is not True
        or completeness.get("execution_successful") is not True
    ):
        raise ValueError("raw graph lacks successful complete LLM execution")
    for field in ("ledger_exceptions", "limitations", "scope_exclusions"):
        if completeness.get(field, []) not in ([], None):
            raise ValueError(f"raw graph contains {field}")

    expected_components = _component_paths(expected_provider_components)
    components = _component_paths(state.get("llm_components"))
    cache = _mapping(state.get("llm_file_cache"), "LLM file cache")
    if components != expected_components or set(cache) != set(components):
        raise ValueError("raw graph LLM cache differs from the authenticated provider-text inventory")
    if not set(components).issubset(verified_source):
        raise ValueError("provider-text inventory contains a path outside the committed source manifest")
    if any(not isinstance(cache[path], str) for path in components):
        raise ValueError("raw graph LLM cache contains a non-text component")
    provider_inventory: list[dict[str, Any]] = []
    for path in components:
        raw_bytes = verified_source[path]
        try:
            provider_text = raw_bytes.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise ValueError("authenticated provider component is not strict UTF-8 source") from error
        if cache[path] != provider_text:
            raise ValueError("raw graph LLM input differs from strict UTF-8 verified source bytes")
        provider_inventory.append({
            "skillId": skill_id,
            "path": path,
            "sourceSha256": sha256(raw_bytes).hexdigest(),
            "sourceBytes": len(raw_bytes),
            "transformation": "strict-utf8-v1",
            "providerTextSha256": sha256(provider_text.encode("utf-8")).hexdigest(),
        })

    statuses = _list(state.get("analyzer_status_events"), "analyzer statuses")
    semantic_statuses: dict[str, Mapping[str, Any]] = {}
    for raw in statuses:
        status = _mapping(raw, "analyzer status")
        identity = status.get("analyzer_id")
        if not isinstance(identity, str):
            raise ValueError("analyzer status has no identity")
        if identity.startswith("semantic_"):
            if identity not in analyzer_ids or identity in semantic_statuses:
                raise ValueError("raw graph has unexpected or duplicate semantic status")
            semantic_statuses[identity] = status
    if set(semantic_statuses) != set(analyzer_ids):
        raise ValueError("raw graph is missing a registered semantic status")

    planned: dict[str, tuple[str, str, Any, Any]] = {}
    for identity in analyzer_ids:
        status = semantic_statuses[identity]
        if status.get("status") != "completed":
            raise ValueError("registered semantic analyzer was not completed")
        work = _list(status.get("planned_work"), "semantic planned work")
        if not work:
            raise ValueError("semantic analyzer has no planned work")
        covered = set()
        ranges: dict[str, list[tuple[int, int]]] = defaultdict(list)
        for raw in work:
            target = _mapping(raw, "semantic planned target")
            work_id = _scalar(target.get("work_id"), "semantic work ID")
            path = _scalar(target.get("path"), "semantic work path")
            if work_id in planned or path not in components:
                raise ValueError("semantic planned work is duplicate or outside LLM inventory")
            start, end = target.get("start_line"), target.get("end_line")
            line_count = max(1, len(cache[path].splitlines()))
            if start is None and end is None:
                ranges[path].append((1, line_count))
            elif (
                not isinstance(start, int) or isinstance(start, bool)
                or not isinstance(end, int) or isinstance(end, bool)
                or start < 1 or end < start or end > line_count
            ):
                raise ValueError("semantic planned work has an invalid file interval")
            else:
                ranges[path].append((start, end))
            planned[work_id] = (identity, path, start, end)
            covered.add(path)
        if covered != set(components):
            raise ValueError("semantic planned work omits an applicable component")
        for path in components:
            next_line = 1
            for start, end in sorted(ranges[path]):
                if start > next_line:
                    raise ValueError("semantic completed chunks omit an LLM input range")
                next_line = max(next_line, end + 1)
            if next_line <= max(1, len(cache[path].splitlines())):
                raise ValueError("semantic completed chunks omit the end of an LLM input")

    ledger = _list(state.get("inspection_ledger"), "inspection ledger")
    terminal: dict[str, Mapping[str, Any]] = {}
    origins: dict[str, list[str]] = defaultdict(list)
    for raw in ledger:
        row = _mapping(raw, "inspection ledger row")
        if row.get("phase") == "ledger_output" or row.get("reason_code") == "output_limit":
            raise ValueError("raw graph inspection ledger reached an output bound")
        emitted = _list(row.get("emitted_finding_ids"), "emitted finding IDs")
        for finding_id in emitted:
            _scalar(finding_id, "ledger finding ID")
        if len(emitted) != len(set(emitted)):
            raise ValueError("inspection ledger repeats an emitted finding ID")
        for finding_id in emitted:
            if row.get("record_type") != "work_item" or row.get("phase") == "meta":
                raise ValueError("raw finding lacks a primary producer work row")
            if row.get("outcome") != "completed":
                raise ValueError("raw finding was emitted by incomplete work")
            origins[finding_id].append(_scalar(row.get("analyzer_id"), "producer analyzer ID"))
        if row.get("phase") == "semantic" or str(row.get("analyzer_id", "")).startswith("semantic_"):
            work_id = _scalar(row.get("work_id"), "semantic terminal work ID")
            if work_id not in planned or work_id in terminal:
                raise ValueError("semantic terminal row is missing, duplicate or unplanned")
            if (
                row.get("record_type") != "work_item" or row.get("phase") != "semantic"
                or row.get("outcome") != "completed"
                or row.get("analyzer_id") != planned[work_id][0]
                or row.get("path") != planned[work_id][1]
                or row.get("start_line") != planned[work_id][2]
                or row.get("end_line") != planned[work_id][3]
                or row.get("reason_code") is not None
                or row.get("input_finding_ids") != []
            ):
                raise ValueError("semantic terminal row disagrees with planned completed work")
            terminal[work_id] = row
    if set(terminal) != set(planned):
        raise ValueError("semantic planned work has no unique completed ledger row")

    calls = _list(state.get("llm_call_log"), "LLM call log")
    semantic_calls: dict[str, Mapping[str, Any]] = {}
    for raw in calls:
        call = _mapping(raw, "LLM call")
        identity = _scalar(call.get("node"), "LLM call node")
        if call.get("ok") is not True or call.get("error") is not None:
            raise ValueError("LLM call did not complete successfully")
        if identity.startswith("semantic_"):
            work_id = _scalar(call.get("work_id"), "LLM call work ID")
            if identity not in analyzer_ids or work_id not in planned or work_id in semantic_calls:
                raise ValueError("LLM call has an unexpected or duplicate semantic work item")
            expected_identity, expected_path, expected_start, expected_end = planned[work_id]
            if (
                identity != expected_identity
                or call.get("path") != expected_path
                or call.get("start_line") != expected_start
                or call.get("end_line") != expected_end
            ):
                raise ValueError("LLM provider call disagrees with its planned work item")
            semantic_calls[work_id] = call
    if set(semantic_calls) != set(planned):
        raise ValueError("semantic planned work has no unique successful provider call")

    by_analyzer: dict[str, list[dict[str, str]]] = {identity: [] for identity in analyzer_ids}
    seen_findings: set[str] = set()
    for raw in _list(state.get("findings"), "raw findings"):
        finding_id, canonical = _finding(raw, skill_id)
        if finding_id in seen_findings or len(origins.get(finding_id, [])) != 1:
            raise ValueError("raw finding has missing, duplicate or ambiguous producer")
        seen_findings.add(finding_id)
        identity = origins[finding_id][0]
        if identity in by_analyzer:
            if raw.file not in components:
                raise ValueError("semantic finding path is outside scanned LLM components")
            by_analyzer[identity].append(canonical)
    if set(origins) != seen_findings:
        raise ValueError("inspection ledger references a missing raw finding")
    return by_analyzer, provider_inventory


def normalize_candidate_scan(
    *, candidate_id: str, input_inventory_sha256: str, provider: str,
    purpose: str, scope: str, expected_active_skills: Sequence[str],
    registered_analyzer_ids: Sequence[str], wired_analyzer_ids: Sequence[str],
    graphs_by_skill: Mapping[str, Mapping[str, Any]],
    expected_skill_paths: Mapping[str, str],
    expected_committed_source_by_skill: Mapping[str, Mapping[str, Any]],
    expected_provider_components_by_skill: Mapping[str, Sequence[str]],
) -> dict[str, object]:
    """Aggregate one raw graph per active Skill without signing or provider calls."""
    if not isinstance(candidate_id, str) or not SHA256.fullmatch(candidate_id):
        raise ValueError("candidate ID is not a lowercase SHA-256 identity")
    if not isinstance(input_inventory_sha256, str) or not SHA256.fullmatch(input_inventory_sha256):
        raise ValueError("input inventory is not a lowercase SHA-256 identity")
    for value, context in ((provider, "provider"), (purpose, "purpose"), (scope, "scope")):
        _scalar(value, context)
    skills = _identities(expected_active_skills, SKILL_ID, "active Skills")
    registered = _identities(registered_analyzer_ids, ANALYZER_ID, "registered analyzers")
    wired = _identities(wired_analyzer_ids, ANALYZER_ID, "graph-wired analyzers")
    if registered != wired:
        raise ValueError("installed semantic analyzers differ from graph-wired nodes")
    graphs = _mapping(graphs_by_skill, "active Skill graph results")
    paths = _mapping(expected_skill_paths, "expected active Skill package paths")
    manifests = _mapping(expected_committed_source_by_skill, "committed active Skill source manifests")
    provider_components = _mapping(
        expected_provider_components_by_skill, "authenticated provider-text component inventories"
    )
    if (
        set(graphs) != set(skills) or set(paths) != set(skills)
        or set(manifests) != set(skills) or set(provider_components) != set(skills)
    ):
        raise ValueError("raw graph/source identities do not cover the exact active Skill set")
    all_findings: dict[str, list[dict[str, str]]] = {identity: [] for identity in registered}
    provider_inventory: list[dict[str, Any]] = []
    for skill_id in skills:
        per_skill, per_skill_provider_inventory = _normalize_skill(
            skill_id, graphs[skill_id], registered, paths[skill_id], manifests[skill_id],
            provider_components[skill_id],
        )
        provider_inventory.extend(per_skill_provider_inventory)
        for identity in registered:
            all_findings[identity].extend(per_skill[identity])
    provider_inventory_json = json.dumps(
        provider_inventory, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return {
        "schemaVersion": 1, "resultType": "standard-semantic-scan-result-v1",
        "candidateId": candidate_id, "inputInventorySha256": input_inventory_sha256,
        "providerTextInventorySha256": sha256(provider_inventory_json).hexdigest(),
        "provider": provider, "purpose": purpose, "scope": scope,
        "activeSkills": skills,
        "analyzers": [
            {"identity": identity, "status": "passed", "completeness": "complete",
             "coveredSkills": skills, "findings": all_findings[identity]}
            for identity in registered
        ],
    }
