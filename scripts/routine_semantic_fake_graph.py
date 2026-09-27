"""Development-only complete SkillSpector graph run with an in-process fake provider.

The candidate never invokes Codex, HTTP, or another model. Its output remains
untrusted, blocked evidence and cannot be used for production CI admission.
"""

from __future__ import annotations

import argparse
import base64
from collections import Counter
from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
from enum import Enum
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
from unittest.mock import patch

from routine_semantic_candidate import CandidateError, preflight


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode(value):
    if value is None or type(value) in (str, int, float, bool):
        return value
    if isinstance(value, Enum):
        return encode(value.value)
    if isinstance(value, bytes):
        return {"base64": base64.b64encode(value).decode("ascii"), "sha256": digest(value)}
    if isinstance(value, Path):
        return str(value)
    if is_dataclass(value):
        return encode(asdict(value))
    if hasattr(value, "model_dump"):
        return encode(value.model_dump(mode="json"))
    if isinstance(value, dict):
        return {str(key): encode(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [encode(item) for item in value]
    if hasattr(value, "to_dict"):
        return encode(value.to_dict())
    raise CandidateError("GRAPH_SERIALIZATION_UNSUPPORTED:" + type(value).__name__)


class FakeProvider:
    RESPONSE = b'{"findings":[],"overall_assessment":{"risk_level":"LOW","summary":"Synthetic only."}}'

    def __init__(self, maximum_calls: int):
        self.maximum_calls = maximum_calls
        self.calls: list[dict] = []
        self.raw_prompts: list[bytes] = []
        self.lock = threading.Lock()

    def is_available(self):
        return True, None

    def resolve_credentials(self):
        return None

    def resolve_model(self, slot="default"):
        return "gpt-5.6-sol"

    def get_context_length(self, model):
        return 128000

    def get_max_output_tokens(self, model):
        return 2048

    def complete(self, prompt, *, model, max_output_tokens=2048, timeout=None):
        data = prompt.encode("utf-8", errors="strict")
        with self.lock:
            if len(self.calls) >= self.maximum_calls:
                raise CandidateError("FAKE_CALL_CAP_EXCEEDED")
            if model != "gpt-5.6-sol" or max_output_tokens != 2048 or len(data) > 524288:
                raise CandidateError("FAKE_ROUTE_OR_PROMPT_BOUND")
            if timeout is not None and (type(timeout) not in (int, float)
                                        or not math.isfinite(timeout) or not 0 < timeout <= 180):
                raise CandidateError("FAKE_TIMEOUT_BOUND")
            number = len(self.calls) + 1
            self.raw_prompts.append(data)
            self.calls.append({"sequence": number, "promptSha256": digest(data),
                               "promptBytes": len(data), "responseSha256": digest(self.RESPONSE),
                               "responseBytes": len(self.RESPONSE), "model": model,
                               "maximumOutputTokens": max_output_tokens,
                               "timeoutSecondsRequested": timeout, "status": "FAKE_RESPONSE"})
        return self.RESPONSE.decode("ascii")


def capture_graph_state(state: dict, group: str, revision: str, calls: int) -> dict:
    """Preserve raw and filtered findings plus every suppressed disposition."""
    return {
        "skill": group, "sourceRevision": revision, "calls": calls,
        "analyzerStatusEvents": encode(state.get("analyzer_status_events", [])),
        "analysisCompleteness": encode(state.get("analysis_completeness", {})),
        "executionSuccessful": state.get("execution_successful"),
        "inspectionLedger": encode(state.get("inspection_ledger", [])),
        "rawFindings": encode(state.get("findings", [])),
        "filteredFindings": encode(state.get("filtered_findings", [])),
        "suppressedFindings": encode(state.get("suppressed_findings", [])),
        "llmCallLog": encode(state.get("llm_call_log", [])),
        "reportBody": state.get("report_body", ""),
    }


def run(inventory_path: Path, prompt_directory: Path, source_repo: Path,
        output_directory: Path, maximum_calls: int) -> dict:
    reviewed = preflight(inventory_path, prompt_directory, source_repo, maximum_calls)
    if reviewed["status"] != "READY_FAKE_ONLY":
        raise CandidateError("PREFLIGHT_CALL_CAP_BLOCKED")
    if output_directory.exists() or output_directory.is_symlink():
        raise CandidateError("OUTPUT_EXISTS")
    from skillspector.graph import create_graph
    from skillspector.providers import use_provider, reset_provider

    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    groups = sorted({item["path"].split("/")[1] for item in inventory["items"]})
    env = dict(os.environ)
    env.update({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory",
                "GIT_CONFIG_VALUE_0": str(source_repo).replace("\\", "/")})
    provider = FakeProvider(maximum_calls)
    graph_results = []
    with tempfile.TemporaryDirectory(prefix="routine-fake-graph-") as scratch:
        root = Path(scratch)
        for item in inventory["items"]:
            data = subprocess.check_output(
                ["git", "--no-replace-objects", "cat-file", "blob", item["gitBlobSha1"]],
                cwd=source_repo, env=env, timeout=30)
            if len(data) != item["bytes"] or digest(data) != item["sha256"]:
                raise CandidateError("SOURCE_BLOB_CHANGED")
            target = root / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

        original_connect = socket.socket.connect
        original_socketpair = socket.socketpair
        socketpair_scope = threading.local()

        def event_loop_socketpair(*args, **kwargs):
            socketpair_scope.active = True
            try:
                return original_socketpair(*args, **kwargs)
            finally:
                socketpair_scope.active = False

        def loopback_only(sock, address):
            # Windows asyncio uses a local socketpair for its own event loop.
            if getattr(socketpair_scope, "active", False) and isinstance(address, tuple):
                try:
                    if ipaddress.ip_address(address[0]).is_loopback:
                        return original_connect(sock, address)
                except ValueError:
                    pass
            raise CandidateError("OFFLINE_NETWORK_DENIED")

        def no_network(*_args, **_kwargs):
            raise CandidateError("OFFLINE_NETWORK_DENIED")

        with patch.object(socket, "socketpair", event_loop_socketpair), \
             patch.object(socket.socket, "connect", loopback_only), \
             patch.object(socket, "create_connection", no_network):
            for group in groups:
                from_group = len(provider.calls)
                token = use_provider(provider)
                try:
                    state = create_graph().invoke({
                        "skill_path": str(root / "skills" / group),
                        "use_llm": True, "llm_requested": True, "output_format": "json",
                        "model_config": {"default": "gpt-5.6-sol"},
                    }, config={"recursion_limit": 64})
                finally:
                    reset_provider(token)
                graph = capture_graph_state(state, group, inventory["candidate"],
                                            len(provider.calls) - from_group)
                graph_results.append(graph)
    expected = Counter(item["promptSha256"] for item in reviewed["calls"])
    if len(expected) != len(reviewed["calls"]):
        raise CandidateError("PREFLIGHT_PROMPT_HASH_DUPLICATE")
    observed = Counter(item["promptSha256"] for item in provider.calls)
    complete = len(provider.calls) == reviewed["requiredCalls"] and expected == observed
    for graph in graph_results:
        statuses = {event.get("analyzer_id"): event.get("status")
                    for event in graph["analyzerStatusEvents"] if type(event) is dict}
        complete &= all(statuses.get(analyzer) == "completed" for analyzer in (
            "semantic_developer_intent", "semantic_quality_policy", "semantic_security_discovery"))
        complete &= graph["analysisCompleteness"].get("is_complete") is True
        complete &= graph["executionSuccessful"] is True
    output_directory.mkdir()
    call_records = []
    expected_by_sha = {item["promptSha256"]: item for item in reviewed["calls"]}
    for record, data in zip(provider.calls, provider.raw_prompts):
        name = f"prompt-{record['sequence']:03d}-{record['promptSha256'][:12]}.txt"
        (output_directory / name).write_bytes(data)
        planned = expected_by_sha.get(record["promptSha256"], {})
        call_records.append({**record, "analyzerId": planned.get("analyzerId"),
                             "sourcePath": planned.get("sourcePath"),
                             "sourceSha256": planned.get("sourceSha256"),
                             "rawPromptFile": name,
                             "responseBase64": base64.b64encode(provider.RESPONSE).decode("ascii")})
    graph_records = []
    for graph in graph_results:
        name = "graph-" + graph["skill"] + ".json"
        raw = (json.dumps(graph, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        (output_directory / name).write_bytes(raw)
        graph_records.append({"skill": graph["skill"], "file": name, "sha256": digest(raw),
                              "rawFindings": len(graph["rawFindings"]),
                              "filteredFindings": len(graph["filteredFindings"]),
                              "suppressedFindings": len(graph["suppressedFindings"]),
                              "analysisComplete": graph["analysisCompleteness"].get("is_complete")})
    result = {"schemaVersion": 1, "artifactType": "routine-semantic-fake-graph-v1",
              "observedAtUtc": datetime.now(timezone.utc).isoformat(),
              "sourceRevision": inventory["candidate"],
              "preflightPromptManifestSha256": reviewed["promptManifestSha256"],
              "requiredCalls": reviewed["requiredCalls"], "actualFakeCalls": len(provider.calls),
              "maximumCalls": maximum_calls, "promptSetExact": expected == observed,
              "graphComplete": bool(complete), "graphs": graph_records,
              "calls": call_records, "realProviderCalls": 0,
              "egressAuthorized": False, "ciAdmission": "BLOCKED", "releaseEligible": False,
              "status": "FAKE_COMPLETE" if complete else "BLOCKED"}
    (output_directory / "manifest.json").write_text(
        json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--prompt-directory", type=Path, required=True)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--maximum-calls", type=int, default=48)
    args = parser.parse_args()
    try:
        result = run(args.inventory, args.prompt_directory, args.source_repo,
                     args.output_directory, args.maximum_calls)
        print(json.dumps({"status": result["status"], "calls": result["actualFakeCalls"],
                          "graphs": result["graphs"], "promptSetExact": result["promptSetExact"]},
                         ensure_ascii=False))
    except (CandidateError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 0 if result["status"] == "FAKE_COMPLETE" else 10


if __name__ == "__main__":
    raise SystemExit(main())
