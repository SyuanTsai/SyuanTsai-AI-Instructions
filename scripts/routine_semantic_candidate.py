"""Offline, fail-closed SkillSpector prompt preflight; never authorizes egress.

This development candidate checks immutable source blobs and captured fake-provider
prompts. It does not run a provider, verify a protected signer, or admit CI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

ANALYZERS = (
    "semantic_developer_intent",
    "semantic_quality_policy",
    "semantic_security_discovery",
)
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
FILE_MARKER = re.compile(r"^## File: (.+)$", re.MULTILINE)


class CandidateError(ValueError):
    """A scoped input, coverage, or integrity check failed."""


def _require(condition: bool, code: str) -> None:
    if not condition:
        raise CandidateError(code)


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read_json(path: Path, code: str) -> tuple[dict[str, Any], bytes]:
    _require(path.is_file() and not path.is_symlink(), code + "_UNSAFE_OR_MISSING")
    data = path.read_bytes()
    _require(0 < len(data) <= 16777216, code + "_SIZE")

    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        seen: set[str] = set()
        for key, item in pairs:
            folded = key.casefold()
            _require(folded not in seen, code + "_DUPLICATE_KEY")
            seen.add(folded)
            value[key] = item
        return value

    try:
        value = json.loads(data.decode("utf-8", errors="strict"), object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(CandidateError(code + "_NONFINITE")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CandidateError(code + "_JSON") from error
    _require(type(value) is dict, code + "_OBJECT")
    return value, data


def _git(repo: Path, *args: str) -> bytes:
    _require(repo.is_dir() and not repo.is_symlink(), "SOURCE_REPO_INVALID")
    result = subprocess.run(["git", "--no-replace-objects", *args], cwd=repo,
                            capture_output=True, timeout=30, check=False)
    _require(result.returncode == 0 and len(result.stdout) <= 8388608, "GIT_SOURCE_INVALID")
    return result.stdout


def _source_inventory(path: Path, repo: Path) -> tuple[dict[str, Any], bytes, dict[str, dict[str, Any]]]:
    inventory, raw = _read_json(path, "INVENTORY")
    revision = inventory.get("candidate")
    _require(type(revision) is str and HEX40.fullmatch(revision) is not None, "REVISION_INVALID")
    _require(_git(repo, "cat-file", "-t", revision).strip() == b"commit", "REVISION_NOT_COMMIT")
    items = inventory.get("items")
    _require(type(items) is list and 0 < len(items) <= 10000, "SOURCE_ITEMS_INVALID")
    tree: dict[str, tuple[str, str]] = {}
    for entry in _git(repo, "ls-tree", "-r", "-z", revision, "--", "skills").split(b"\x00"):
        if not entry:
            continue
        try:
            header, name = entry.split(b"\t", 1)
            mode, kind, blob_id = header.decode("ascii").split(" ")
            filename = name.decode("utf-8", errors="strict")
        except (ValueError, UnicodeDecodeError) as error:
            raise CandidateError("TREE_ENTRY_INVALID") from error
        _require(filename not in tree, "TREE_DUPLICATE")
        tree[filename] = (mode, blob_id) if kind == "blob" else ("invalid", blob_id)
    selected: dict[str, dict[str, Any]] = {}
    total = 0
    for item in items:
        _require(type(item) is dict and set(item) == {"path", "gitBlobSha1", "bytes", "sha256", "changed", "skillInstructions"}
                 and type(item["changed"]) is bool and type(item["skillInstructions"]) is bool,
                 "SOURCE_ITEM_FIELDS")
        name = item["path"]
        _require(type(name) is str and name.startswith("skills/") and len(name.split("/")) >= 3
                 and all(part not in ("", ".", "..") for part in name.split("/"))
                 and "\\" not in name and "\x00" not in name and name not in selected, "SOURCE_PATH_INVALID")
        blob_id = item["gitBlobSha1"]
        expected = item["sha256"]
        size = item["bytes"]
        _require(type(blob_id) is str and HEX40.fullmatch(blob_id) is not None
                 and type(expected) is str and HEX64.fullmatch(expected) is not None
                 and type(size) is int and 0 <= size <= 2097152, "SOURCE_DIGEST_INVALID")
        _require(tree.get(name) in (("100644", blob_id), ("100755", blob_id)), "SOURCE_TREE_MISMATCH")
        blob = _git(repo, "cat-file", "blob", blob_id)
        _require(len(blob) == size and _digest(blob) == expected, "SOURCE_BLOB_MISMATCH")
        selected[name] = item
        total += size
    groups = {name.split("/")[1] for name in selected}
    _require(set(selected) == {name for name in tree if name.split("/")[1] in groups}, "SOURCE_GROUP_INCOMPLETE")
    _require(total <= 2097152, "SOURCE_TOTAL_LIMIT")
    _require(inventory.get("sourceBytes", total) == total, "SOURCE_TOTAL_MISMATCH")
    return inventory, raw, selected


def preflight(inventory_path: Path, prompt_directory: Path, source_repo: Path,
              maximum_calls: int = 48) -> dict[str, Any]:
    """Check one immutable candidate; return BLOCKED or READY_FAKE_ONLY."""
    _require(type(maximum_calls) is int and 1 <= maximum_calls <= 1000, "CALL_CAP_INVALID")
    _require(prompt_directory.is_dir() and not prompt_directory.is_symlink(), "PROMPT_DIR_INVALID")
    inventory, inventory_bytes, selected = _source_inventory(inventory_path, source_repo)
    manifest, manifest_bytes = _read_json(prompt_directory / "manifest.json", "PROMPT_MANIFEST")
    _require(manifest.get("schemaVersion") == 1 and type(manifest.get("schemaVersion")) is int
             and manifest.get("sourceRevision") == inventory["candidate"]
             and manifest.get("sourceInventorySha256") == _digest(inventory_bytes)
             and manifest.get("sourceFileCount") == len(selected)
             and manifest.get("sourceBytes") == sum(item["bytes"] for item in selected.values())
             and manifest.get("realProviderCalls") == 0 and manifest.get("egressAuthorized") is False,
             "PROMPT_MANIFEST_BINDING")
    candidates = manifest.get("promptCandidates")
    _require(type(candidates) is list and 0 < len(candidates) <= 1000, "PROMPT_ITEMS_INVALID")
    calls = []
    seen: set[tuple[str, str]] = set()
    names: set[str] = set()
    prompt_bytes = 0
    for entry in candidates:
        _require(type(entry) is dict, "PROMPT_ENTRY_INVALID")
        filename = entry.get("file")
        skill = entry.get("skill")
        analyzer = entry.get("analyzerId")
        _require(type(filename) is str and filename.endswith(".txt") and filename == Path(filename).name
                 and "/" not in filename and "\\" not in filename and filename not in names,
                 "PROMPT_PATH_INVALID")
        names.add(filename)
        _require(type(skill) is str and skill in {name.split("/")[1] for name in selected}
                 and analyzer in ANALYZERS, "PROMPT_SCOPE_INVALID")
        prompt_path = prompt_directory / filename
        _require(prompt_path.is_file() and not prompt_path.is_symlink(), "PROMPT_UNSAFE_OR_MISSING")
        data = prompt_path.read_bytes()
        _require(0 < len(data) <= 524288 and entry.get("promptBytes") == len(data)
                 and entry.get("promptSha256") == _digest(data), "PROMPT_HASH_MISMATCH")
        try:
            text = data.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise CandidateError("PROMPT_UTF8_INVALID") from error
        markers = FILE_MARKER.findall(text)
        _require(len(markers) == 1, "PROMPT_FILE_MARKER_INVALID")
        source_path = "skills/" + skill + "/" + markers[0]
        _require(source_path in selected and (analyzer, source_path) not in seen,
                 "PROMPT_COVERAGE_DUPLICATE_OR_OUTSIDE")
        seen.add((analyzer, source_path))
        model = entry.get("model")
        output_tokens = entry.get("maxOutputTokensRequested")
        _require(type(model) is str and 0 < len(model) <= 128
                 and type(output_tokens) is int and 1 <= output_tokens <= 100000,
                 "PROMPT_ROUTE_INVALID")
        prompt_bytes += len(data)
        _require(prompt_bytes <= 67108864, "PROMPT_TOTAL_LIMIT")
        calls.append({"id": _digest((analyzer + "\n" + source_path + "\n" + _digest(data)).encode()),
                      "analyzerId": analyzer, "sourcePath": source_path,
                      "sourceSha256": selected[source_path]["sha256"],
                      "promptFile": filename, "promptSha256": _digest(data),
                      "promptBytes": len(data), "observedModel": model,
                      "observedMaximumOutputTokens": output_tokens})
    _require(seen == {(analyzer, path) for path in selected for analyzer in ANALYZERS},
             "PROMPT_COVERAGE_INCOMPLETE")
    actual_entries = list(prompt_directory.iterdir())
    _require(all(path.is_file() and not path.is_symlink() for path in actual_entries)
             and {path.name for path in actual_entries} == names | {"manifest.json"},
             "PROMPT_DIRECTORY_EXTRA_OR_MISSING")
    required = len(calls)
    return {"schemaVersion": 1, "artifactType": "routine-semantic-fake-preflight-v1",
            "sourceRevision": inventory["candidate"], "sourceInventorySha256": _digest(inventory_bytes),
            "promptManifestSha256": _digest(manifest_bytes), "sourceFileCount": len(selected),
            "sourceBytes": sum(item["bytes"] for item in selected.values()), "promptBytes": prompt_bytes,
            "requiredCalls": required, "maximumCalls": maximum_calls,
            "callShortfall": max(0, required - maximum_calls),
            "observedMaximumOutputTokensTotal": sum(call["observedMaximumOutputTokens"] for call in calls),
            "proposed2048OutputTokensTotal": required * 2048,
            "status": "BLOCKED" if required > maximum_calls else "READY_FAKE_ONLY",
            "calls": calls, "egressAuthorized": False, "ciAdmission": "BLOCKED",
            "releaseEligible": False}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--prompt-directory", required=True, type=Path)
    parser.add_argument("--source-repo", required=True, type=Path)
    parser.add_argument("--maximum-calls", type=int, default=48)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = preflight(args.inventory, args.prompt_directory, args.source_repo, args.maximum_calls)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, ensure_ascii=False, separators=(",", ":"))
            stream.write("\n")
    except (CandidateError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 10
    return 10 if result["status"] == "BLOCKED" else 0


if __name__ == "__main__":
    raise SystemExit(main())
