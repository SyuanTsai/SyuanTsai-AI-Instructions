"""Build exact, offline-only Responses request bodies from frozen prompts.

There is deliberately no HTTP, credential, Codex CLI, or process transport here.
This candidate does not prove model availability or the effective network envelope.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

from routine_semantic_candidate import CandidateError, _read_json, _require, preflight

MODEL_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}\Z")


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def build_envelopes(inventory_path: Path, preflight_path: Path, prompt_directory: Path,
                    source_repo: Path, *, model: str, maximum_calls: int) -> dict:
    """Recheck frozen Git blobs and return a blocked, byte-exact request candidate."""
    _require(type(model) is str and MODEL_NAME.fullmatch(model) is not None,
             "REQUEST_MODEL_INVALID")
    observed, preflight_bytes = _read_json(preflight_path, "PREFLIGHT")
    regenerated = preflight(inventory_path, prompt_directory, source_repo, maximum_calls)
    _require(_canonical(observed) == _canonical(regenerated)
             and regenerated["status"] == "READY_FAKE_ONLY"
             and regenerated["egressAuthorized"] is False,
             "REQUEST_PREFLIGHT_CHANGED_OR_BLOCKED")
    requests = []
    for sequence, call in enumerate(regenerated["calls"], 1):
        prompt_path = prompt_directory / call["promptFile"]
        prompt = prompt_path.read_bytes()
        _require(_digest(prompt) == call["promptSha256"]
                 and len(prompt) == call["promptBytes"], "REQUEST_PROMPT_CHANGED")
        body = _canonical({
            "model": model,
            "input": [{"role": "user", "content": [{"type": "input_text",
                                                        "text": prompt.decode("utf-8", errors="strict")}]}],
            "tools": [], "tool_choice": "none", "max_output_tokens": 2048,
            "truncation": "disabled", "store": False,
        })
        _require(len(body) <= 1048576, "REQUEST_BODY_TOO_LARGE")
        requests.append({"sequence": sequence, "callId": call["id"],
                         "analyzerId": call["analyzerId"], "sourcePath": call["sourcePath"],
                         "sourceSha256": call["sourceSha256"],
                         "promptSha256": call["promptSha256"], "promptBytes": len(prompt),
                         "bodySha256": _digest(body), "bodyBytes": len(body),
                         "bodyHex": body.hex()})
    _require(len(requests) == regenerated["requiredCalls"]
             and len(requests) <= maximum_calls, "REQUEST_CALL_COVERAGE")
    return {"schemaVersion": 1, "artifactType": "routine-semantic-offline-request-envelope-v1",
            "status": "OFFLINE_ENVELOPE_ONLY", "sourceRevision": regenerated["sourceRevision"],
            "sourceInventorySha256": regenerated["sourceInventorySha256"],
            "promptManifestSha256": regenerated["promptManifestSha256"],
            "preflightSha256": _digest(preflight_bytes), "requestedModel": model,
            "modelAvailabilityVerified": False, "endpointCandidate": "https://api.openai.com/v1/responses",
            "requestCount": len(requests), "requestBodyBytes": sum(x["bodyBytes"] for x in requests),
            "maximumCalls": maximum_calls, "maximumOutputTokensPerCall": 2048,
            "maximumOutputTokensTotal": 2048 * len(requests), "requests": requests,
            "realProviderCalls": 0, "networkTransportPresent": False,
            "actualOutboundContextVerified": False, "egressAuthorized": False,
            "authorizationStatus": "not-evaluated", "trustStatus": "unverified",
            "ciAdmission": "BLOCKED", "releaseEligible": False}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--preflight", required=True, type=Path)
    parser.add_argument("--prompt-directory", required=True, type=Path)
    parser.add_argument("--source-repo", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--maximum-calls", required=True, type=int)
    parser.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = build_envelopes(args.inventory, args.preflight, args.prompt_directory,
                                 args.source_repo, model=args.model, maximum_calls=args.maximum_calls)
        args.output_directory.mkdir(parents=False, exist_ok=False)
        public = {key: value for key, value in result.items() if key != "requests"}
        public["requests"] = []
        for item in result["requests"]:
            name = f"request-{item['sequence']:03d}.json"
            with (args.output_directory / name).open("xb") as stream:
                stream.write(bytes.fromhex(item["bodyHex"]))
            public["requests"].append({key: value for key, value in item.items()
                                       if key != "bodyHex"} | {"file": name})
        with (args.output_directory / "manifest.json").open("xb") as stream:
            stream.write(_canonical(public) + b"\n")
    except (CandidateError, OSError, UnicodeDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
