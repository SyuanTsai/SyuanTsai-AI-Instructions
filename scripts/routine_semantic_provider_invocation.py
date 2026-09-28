"""Stub-only provider invocation candidate for frozen SkillSpector prompts.

This module has no network, credential, subprocess transport, or Codex CLI
invocation. It records the exact candidate Responses bodies and local stub
bytes; the ledger cannot establish real model execution or protected custody.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

from routine_semantic_candidate import ANALYZERS, HEX40, HEX64, CandidateError, _require
from routine_semantic_prompt_envelope import build_envelopes


DESTINATION = "https://api.openai.com/v1/responses"
PURPOSE = "routine semantic review"
DATA_CATEGORY = "skill-instructions"
# Offline candidate budget covers the complete 26-file, three-analyzer inventory.
# It is not a grant to send any source content to a provider.
MAX_CALLS = 78
MAX_OUTPUT_TOKENS = 2048
BODY_FIELDS = {"model", "input", "tools", "tool_choice", "max_output_tokens", "truncation", "store"}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def decode_base64(value: Any, maximum: int, code: str) -> bytes:
    _require(type(value) is str and 0 < len(value) <= maximum * 2, code + "_INVALID")
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise CandidateError(code + "_INVALID") from error
    _require(len(raw) <= maximum and base64.b64encode(raw).decode("ascii") == value,
             code + "_NONCANONICAL_OR_OVERSIZE")
    return raw


def inspect_body(body: bytes, *, model: str, prompt_sha256: str) -> None:
    try:
        value = json.loads(body.decode("utf-8", errors="strict"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CandidateError("REQUEST_JSON_INVALID") from error
    _require(type(value) is dict and set(value) == BODY_FIELDS and canonical(value) == body,
             "REQUEST_FIELDS_OR_ENCODING")
    _require(value["model"] == model and value["tools"] == [] and
             value["tool_choice"] == "none" and
             value["max_output_tokens"] == MAX_OUTPUT_TOKENS and
             type(value["max_output_tokens"]) is int and
             value["truncation"] == "disabled" and value["store"] is False,
             "REQUEST_ROUTE_OR_CAPABILITY")
    messages = value["input"]
    _require(type(messages) is list and len(messages) == 1 and
             type(messages[0]) is dict and set(messages[0]) == {"role", "content"} and
             messages[0]["role"] == "user", "REQUEST_MESSAGE_SCOPE")
    content = messages[0]["content"]
    _require(type(content) is list and len(content) == 1 and
             type(content[0]) is dict and set(content[0]) == {"type", "text"} and
             content[0]["type"] == "input_text" and type(content[0]["text"]) is str and
             digest(content[0]["text"].encode("utf-8")) == prompt_sha256,
             "REQUEST_PROMPT_SCOPE")


class OfflineResponsesStub:
    """Concrete local fixture response; it cannot delegate to a network client."""

    def respond(self, *, call_id: str, request_body: bytes) -> bytes:
        return canonical({"fixtureOnly": True, "callId": call_id,
                          "requestBodySha256": digest(request_body),
                          "outputText": "offline stub; no model inference"})


def invoke_stub_only(inventory_path: Path, preflight_path: Path, prompt_directory: Path,
                     source_repo: Path, *, model: str, maximum_calls: int) -> dict[str, Any]:
    _require(type(maximum_calls) is int and 1 <= maximum_calls <= MAX_CALLS,
             "STUB_CALL_CAP_INVALID")
    envelope = build_envelopes(inventory_path, preflight_path, prompt_directory,
                               source_repo, model=model, maximum_calls=maximum_calls)
    _require(envelope["endpointCandidate"] == DESTINATION and
             envelope["status"] == "OFFLINE_ENVELOPE_ONLY" and
             envelope["egressAuthorized"] is False and
             envelope["realProviderCalls"] == 0 and
             envelope["networkTransportPresent"] is False,
             "STUB_ENVELOPE_INVALID")
    stub = OfflineResponsesStub()
    calls: list[dict[str, Any]] = []
    for item in envelope["requests"]:
        body = bytes.fromhex(item["bodyHex"])
        _require(len(body) == item["bodyBytes"] and digest(body) == item["bodySha256"],
                 "STUB_BODY_CHANGED")
        inspect_body(body, model=model, prompt_sha256=item["promptSha256"])
        response = stub.respond(call_id=item["callId"], request_body=body)
        _require(len(response) <= 65536, "STUB_RESPONSE_OVERSIZE")
        calls.append({
            "sequence": item["sequence"], "callId": item["callId"],
            "analyzerId": item["analyzerId"], "sourcePath": item["sourcePath"],
            "sourceSha256": item["sourceSha256"], "promptSha256": item["promptSha256"],
            "promptBytes": item["promptBytes"], "requestBodySha256": digest(body),
            "requestBodyBytes": len(body), "requestBodyBase64": base64.b64encode(body).decode("ascii"),
            "rawResponseSha256": digest(response), "rawResponseBytes": len(response),
            "rawResponseBase64": base64.b64encode(response).decode("ascii"),
            "status": "STUB_RESPONSE_ONLY",
        })
    return {
        "schemaVersion": 1, "artifactType": "routine-semantic-stub-invocation-ledger-v1",
        "status": "STUB_ONLY", "destination": DESTINATION, "httpMethodCandidate": "POST",
        "purpose": PURPOSE, "dataCategory": DATA_CATEGORY, "requestedModel": model,
        "sourceRevision": envelope["sourceRevision"],
        "sourceInventorySha256": envelope["sourceInventorySha256"],
        "promptManifestSha256": envelope["promptManifestSha256"],
        "preflightSha256": envelope["preflightSha256"],
        "maximumCalls": maximum_calls, "requestCount": len(calls),
        "maximumOutputTokensPerCall": MAX_OUTPUT_TOKENS,
        "maximumOutputTokensTotal": len(calls) * MAX_OUTPUT_TOKENS,
        "requestBodyBytesTotal": sum(item["requestBodyBytes"] for item in calls),
        "rawResponseBytesTotal": sum(item["rawResponseBytes"] for item in calls),
        "calls": calls, "realProviderCalls": 0, "scanExecuted": False,
        "networkTransportPresent": False, "actualOutboundContextVerified": False,
        "modelAvailabilityVerified": False, "credentialAvailableVerified": False,
        "costVerified": False, "costUnknownReason": "No authenticated API route, billing context or real token usage was verified.",
        "egressAuthorized": False, "authorizationStatus": "not-evaluated",
        "trustStatus": "unverified", "ciAdmission": "BLOCKED", "releaseEligible": False,
    }


def verify_stub_ledger(ledger: dict[str, Any]) -> bool:
    _require(type(ledger) is dict and ledger.get("artifactType") == "routine-semantic-stub-invocation-ledger-v1"
             and ledger.get("schemaVersion") == 1 and type(ledger.get("schemaVersion")) is int
             and ledger.get("status") == "STUB_ONLY" and ledger.get("destination") == DESTINATION
             and ledger.get("httpMethodCandidate") == "POST" and ledger.get("purpose") == PURPOSE
             and ledger.get("dataCategory") == DATA_CATEGORY and
             ledger.get("networkTransportPresent") is False and
             ledger.get("actualOutboundContextVerified") is False and
             ledger.get("modelAvailabilityVerified") is False and
             ledger.get("credentialAvailableVerified") is False and
             ledger.get("costVerified") is False and
             ledger.get("egressAuthorized") is False and
             ledger.get("authorizationStatus") == "not-evaluated" and
             ledger.get("trustStatus") == "unverified" and
             ledger.get("realProviderCalls") == 0 and ledger.get("scanExecuted") is False and
             ledger.get("ciAdmission") == "BLOCKED" and ledger.get("releaseEligible") is False,
             "STUB_LEDGER_STATUS")
    integer_fields = ("maximumCalls", "requestCount", "realProviderCalls", "maximumOutputTokensPerCall",
                      "maximumOutputTokensTotal", "requestBodyBytesTotal", "rawResponseBytesTotal")
    _require(all(type(ledger.get(field)) is int and ledger[field] >= 0 for field in integer_fields),
             "STUB_LEDGER_INTEGER_TYPE")
    _require(type(ledger.get("sourceRevision")) is str and HEX40.fullmatch(ledger["sourceRevision"]) is not None
             and all(type(ledger.get(field)) is str and HEX64.fullmatch(ledger[field]) is not None
                     for field in ("sourceInventorySha256", "promptManifestSha256", "preflightSha256")),
             "STUB_LEDGER_SOURCE_BINDING")
    calls = ledger.get("calls")
    _require(type(calls) is list and len(calls) == ledger.get("requestCount") and
             0 < len(calls) <= MAX_CALLS and ledger.get("maximumCalls") >= len(calls) and
             ledger.get("maximumCalls") <= MAX_CALLS, "STUB_LEDGER_CALLS")
    seen: set[str] = set()
    body_total = response_total = 0
    for sequence, item in enumerate(calls, 1):
        _require(type(item) is dict and item.get("sequence") == sequence and
                 type(item.get("callId")) is str and item["callId"] not in seen and
                 item.get("status") == "STUB_RESPONSE_ONLY", "STUB_LEDGER_ORDER")
        _require(all(type(item.get(field)) is int and item[field] > 0
                     for field in ("sequence", "promptBytes", "requestBodyBytes", "rawResponseBytes")),
                 "STUB_LEDGER_INTEGER_TYPE")
        path = item.get("sourcePath")
        _require(type(item.get("analyzerId")) is str and item["analyzerId"] in ANALYZERS and
                 type(path) is str and path.startswith("skills/") and len(path.split("/")) >= 3 and
                 all(part not in ("", ".", "..") for part in path.split("/")) and
                 "\\" not in path and "\x00" not in path and
                 all(type(item.get(field)) is str and HEX64.fullmatch(item[field]) is not None
                     for field in ("sourceSha256", "promptSha256")), "STUB_LEDGER_WORK_SCOPE")
        expected_id = digest(f'{item["analyzerId"]}\n{path}\n{item["promptSha256"]}'.encode("utf-8"))
        _require(item["callId"] == expected_id, "STUB_LEDGER_CALL_ID")
        seen.add(item["callId"])
        body = decode_base64(item.get("requestBodyBase64"), 1048576, "STUB_REQUEST")
        response = decode_base64(item.get("rawResponseBase64"), 65536, "STUB_RESPONSE")
        _require(item.get("requestBodyBytes") == len(body) and
                 item.get("requestBodySha256") == digest(body) and
                 item.get("rawResponseBytes") == len(response) and
                 item.get("rawResponseSha256") == digest(response), "STUB_LEDGER_HASH")
        inspect_body(body, model=ledger["requestedModel"], prompt_sha256=item["promptSha256"])
        prompt = json.loads(body)["input"][0]["content"][0]["text"].encode("utf-8")
        _require(item["promptBytes"] == len(prompt), "STUB_LEDGER_PROMPT_BYTES")
        expected_response = OfflineResponsesStub().respond(call_id=item["callId"], request_body=body)
        _require(response == expected_response, "STUB_RESPONSE_CHANGED")
        body_total += len(body)
        response_total += len(response)
    _require(body_total == ledger.get("requestBodyBytesTotal") and
             response_total == ledger.get("rawResponseBytesTotal") and
             ledger.get("maximumOutputTokensPerCall") == MAX_OUTPUT_TOKENS and
             ledger.get("maximumOutputTokensTotal") == MAX_OUTPUT_TOKENS * len(calls),
             "STUB_LEDGER_TOTAL")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--preflight", required=True, type=Path)
    parser.add_argument("--prompt-directory", required=True, type=Path)
    parser.add_argument("--source-repo", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--maximum-calls", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = invoke_stub_only(args.inventory, args.preflight, args.prompt_directory,
                                  args.source_repo, model=args.model, maximum_calls=args.maximum_calls)
        _require(verify_stub_ledger(result), "STUB_LEDGER_INVALID")
        with args.output.open("xb") as stream:
            stream.write(canonical(result) + b"\n")
    except (CandidateError, OSError, UnicodeDecodeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
