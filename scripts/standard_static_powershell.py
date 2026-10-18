"""Bounded native PowerShell ownership for the frozen SkillSpector static parser.

The original finding analyzer always receives the original source. This module
corrects completeness accounting only after the native parser has identified
the actual command nodes; it does not authenticate a run or authorize actions.
"""
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
from typing import Callable

MAX_SOURCE_BYTES = 1024 * 1024
MAX_PROOF_BYTES = 8 * 1024 * 1024
PROFILE = "powershell-native-command-ownership-v1"
OFFICIAL_VERSION = "2.13.0"
OFFICIAL_RELEASE_COMMIT = "091a509b3d6ba8ff5be528966e1f43c2e68cf214"
OFFICIAL_RELEASE_ASSET_SHA256 = "41e097b4127c0aa0732ad31cc909f8aee0b907d97816c866a55b8e782a6ca6dc"
OFFICIAL_MODULE_SHA256 = "c799169f9ad716f8dbbbec5892ef76affd0f9974433709ed0c1cfc3bcd0b66a4"
FENCE = re.compile(r"(?m)^```(?:powershell|pwsh|ps1)[ \t]*\n(?P<body>[\s\S]*?)^```[ \t]*$")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "cmd", "pwsh",
          "powershell", "wsl", "python", "python3", "node", "perl", "ruby", "php",
          "iex", "invoke-expression", "invoke-command", "start-process", "add-type"}


class ParserCoverageError(ValueError):
    """Source, parser or coverage evidence is unavailable or inconsistent."""


def normalize_source(source: str) -> str:
    if not isinstance(source, str) or "\x00" in source:
        raise ParserCoverageError("source must be bounded text")
    normalized = source.removeprefix("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    if len(normalized.encode("utf-8")) > MAX_SOURCE_BYTES:
        raise ParserCoverageError("source exceeds the fixed parser budget")
    return normalized


def _keys(value, expected, context):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise ParserCoverageError(context + " has an unsupported property set")


def _list(value, limit, context):
    if not isinstance(value, list) or len(value) > limit:
        raise ParserCoverageError(context + " must be a bounded array")
    return value


def _offset_map(source):
    positions = {0: 0}
    offset = 0
    for index, character in enumerate(source):
        if 0xD800 <= ord(character) <= 0xDFFF:
            raise ParserCoverageError("source contains an unpaired surrogate")
        offset += 2 if ord(character) > 0xFFFF else 1
        positions[offset] = index + 1
    return positions, offset


def native_proof(source: str, language: str, pwsh: str, process_observer=None) -> dict:
    source = normalize_source(source)
    if language not in {"powershell", "markdown"}:
        raise ParserCoverageError("unsupported host language")
    helper = Path(__file__).with_name("Get-StandardPowerShellSyntaxProof.ps1")
    request = json.dumps({"source": source, "language": language}, ensure_ascii=False)
    started = time.monotonic()
    try:
        run = subprocess.run([pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(helper)],
                             input=request, encoding="utf-8", capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ParserCoverageError("native parser process failed") from error
    if run.returncode != 0 or len(run.stdout.encode("utf-8")) > MAX_PROOF_BYTES:
        raise ParserCoverageError("native parser rejected source or exceeded its budget")
    try:
        proof = json.loads(run.stdout)
    except (TypeError, json.JSONDecodeError) as error:
        raise ParserCoverageError("native parser produced invalid JSON") from error
    validate_proof(source, language, proof)
    if process_observer is not None:
        process_observer({"command": str(pwsh), "arguments": ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(helper)],
                          "exitCode": run.returncode, "seconds": round(time.monotonic()-started, 6),
                          "stdout": run.stdout, "stderr": run.stderr,
                          "stdoutSha256": hashlib.sha256(run.stdout.encode("utf-8")).hexdigest(),
                          "stderrSha256": hashlib.sha256(run.stderr.encode("utf-8")).hexdigest()})
    return proof


def validate_proof(source: str, language: str, proof: dict) -> dict:
    source = normalize_source(source)
    _keys(proof, {"schemaVersion", "parserRuntimeVersion", "sourceSha256", "language", "sourceLength", "units"}, "native proof")
    positions, utf16_length = _offset_map(source)
    if (type(proof["schemaVersion"]) is not int or proof["schemaVersion"] != 1
            or proof["parserRuntimeVersion"] != "7.6.6" or proof["language"] != language or language not in {"powershell", "markdown"}
            or type(proof["sourceLength"]) is not int or proof["sourceLength"] != utf16_length
            or proof["sourceSha256"] != hashlib.sha256(source.encode("utf-8")).hexdigest()):
        raise ParserCoverageError("native proof source identity differs")
    expected = [(0, len(source))] if language == "powershell" else [
        match.span("body") for match in FENCE.finditer(source)]
    units = _list(proof["units"], 128, "native units")
    if len(units) != len(expected):
        raise ParserCoverageError("native proof does not cover the exact host units")
    converted = []
    for unit, expected_span in zip(units, expected):
        _keys(unit, {"start", "end", "errors", "strings", "subexpressions", "continuations",
                     "commands", "commandCount", "unsupported"}, "native unit")
        def span(item, lower=expected_span[0], upper=expected_span[1]):
            start, end = item["start"], item["end"]
            if (type(start) is not int or type(end) is not int or start not in positions or end not in positions
                    or not lower <= positions[start] <= positions[end] <= upper):
                raise ParserCoverageError("native extent is invalid or splits a surrogate pair")
            return positions[start], positions[end]
        begin, end = span(unit)
        if (begin, end) != expected_span:
            raise ParserCoverageError("native unit extent differs from parsed host region")
        errors = _list(unit["errors"], 100000, "parser errors")
        if any(not isinstance(error, str) or not error for error in errors):
            raise ParserCoverageError("native parser error identities are malformed")
        item = {"start": begin, "end": end, "errors": errors}
        for field, maximum in (("strings", 16384), ("subexpressions", 4096),
                               ("continuations", 100000), ("commands", 4096), ("unsupported", 4096)):
            out = []
            seen = set()
            for value in _list(unit[field], maximum, field):
                fields = {"start", "end"}
                if field == "strings": fields |= {"stringType"}
                if field == "commands": fields |= {"name", "invocation", "parameters"}
                _keys(value, fields, field)
                left, right = span(value)
                if left == right or (left, right) in seen:
                    raise ParserCoverageError("empty or duplicate native extent")
                seen.add((left, right))
                entry = {**value, "start": left, "end": right}
                if field == "strings" and value["stringType"] not in {
                        "SingleQuoted", "DoubleQuoted", "SingleQuotedHereString", "DoubleQuotedHereString", "Expandable"}:
                    raise ParserCoverageError("unsupported native string kind")
                if field == "subexpressions" and not (source[left:right].startswith("$(") and source[right-1] == ")"):
                    raise ParserCoverageError("native subexpression text differs")
                if field == "continuations" and not source[left:right].startswith(chr(96)):
                    raise ParserCoverageError("native continuation text differs")
                if field == "commands":
                    if value["name"] is not None and not isinstance(value["name"], str):
                        raise ParserCoverageError("native command name is malformed")
                    if value["invocation"] not in {"Unknown", "Ampersand", "Dot"}:
                        raise ParserCoverageError("native invocation operator is unsupported")
                    if any(not isinstance(p, str) or not p for p in _list(value["parameters"], 4096, "parameters")):
                        raise ParserCoverageError("native command parameters are malformed")
                out.append(entry)
            item[field] = out
        if type(unit["commandCount"]) is not int or unit["commandCount"] != len(item["commands"]):
            raise ParserCoverageError("native command coverage count differs")
        converted.append(item)
    return {"source": source, "units": converted}


def _command_view(source, command, unit):
    begin, end = command["start"], command["end"]
    view = list(source[begin:end])
    closers = set()
    for string in unit["strings"]:
        left, right = string["start"], string["end"]
        if not begin <= left < right <= end:
            continue
        if source[left] in {"'", '"'}:
            closers.add(right - begin - 1)
        if string["stringType"] in {"DoubleQuoted", "Expandable", "DoubleQuotedHereString"}:
            cursor = left
            while cursor < right - 1:
                if source[cursor] == chr(96):
                    view[cursor-begin] = "\\"
                    cursor += 1
                cursor += 1
    for expression in unit["subexpressions"]:
        left, right = expression["start"], expression["end"]
        if begin <= left < right <= end:
            view[left-begin:left-begin+2] = [" ", " "]
            view[right-begin-1] = " "
    for continuation in unit["continuations"]:
        left = continuation["start"]
        if begin <= left < end:
            view[left-begin] = " "
    return "".join(view), closers


def check_command_views(source: str, language: str, proof: dict, bounded: Callable, check_runtime=lambda: None) -> bool:
    validated = validate_proof(source, language, proof)
    source = validated["source"]
    total_view_chars = 0
    for unit in validated["units"]:
        check_runtime()
        if unit["errors"]:
            raise ParserCoverageError("native parser did not accept the complete host unit")
        if unit["unsupported"]:
            return True
        for command in unit["commands"]:
            check_runtime()
            name = (command["name"] or "").replace("\\", "/").rsplit("/", 1)[-1].casefold().removesuffix(".exe")
            # Another interpreter or dynamic command-string receiver needs a
            # separate language/data-flow proof; this profile cannot grant it.
            if name in SHELLS or re.fullmatch(r"python\d+(?:\.\d+)*", name):
                return True
            if command["name"] is None and any(
                    "command".startswith(p.casefold()) or "encodedcommand".startswith(p.casefold())
                    for p in command["parameters"]):
                return True
            raw = source[command["start"]:command["end"]]
            if command["name"] is None and re.search(r"(?:^|\s)(?:/c|/k)(?:\s|$)", raw, re.I):
                return True
            view, closers = _command_view(source, command, unit)
            total_view_chars += len(view)
            if total_view_chars > 4 * MAX_SOURCE_BYTES:
                raise ParserCoverageError("nested command-view budget exceeded")
            if bounded(view, file_type="powershell", quote_closers=closers, check_runtime=check_runtime):
                return True
    if language == "markdown":
        unowned = list(source)
        for unit in validated["units"]:
            for index in range(unit["start"], unit["end"]):
                if unowned[index] not in "\r\n":
                    unowned[index] = " "
        if bounded("".join(unowned), file_type="markdown", quote_closers=set(), check_runtime=check_runtime):
            return True
    return False


def install_bridge(pwsh: str, pwsh_sha256: str, module, installed_version: str, source_inventory: dict):
    """Install one reviewed in-memory completeness hook; finding code is untouched."""
    import types
    runtime = Path(pwsh)
    if (not runtime.is_absolute() or not runtime.is_file()
            or hashlib.sha256(runtime.read_bytes()).hexdigest() != pwsh_sha256):
        raise ParserCoverageError("native runtime differs from its frozen identity")
    if installed_version != OFFICIAL_VERSION:
        raise ParserCoverageError("scanner version has no reviewed parser profile")
    module_path = Path(module.__file__)
    if hashlib.sha256(module_path.read_bytes()).hexdigest() != OFFICIAL_MODULE_SHA256:
        raise ParserCoverageError("scanner module differs from reviewed official bytes")
    original = module.has_bounded_parse_exhaustion
    original_helper = module._has_shell_command_word_exhaustion
    finding_analyzer = module.analyze
    records = []
    cache = {}

    def corrected(content, check_runtime, *, file_type="shell", complete_context=True):
        check_runtime()
        original_partial = original(content, check_runtime, file_type=file_type, complete_context=complete_context)
        if not original_partial or not complete_context:
            return original_partial
        normalized = normalize_source(content)
        digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
        paths = source_inventory.get(digest, [])
        # The official generic classifier does not label .psm1 as PowerShell.
        # Admit it only through the actual frozen inventory, never a caller flag.
        if file_type not in {"powershell", "markdown"}:
            if not paths or not all(path.casefold().endswith(".psm1") for path in paths):
                return original_partial
            file_type = "powershell"
        if not paths:
            raise ParserCoverageError("scanner input is not in the frozen candidate inventory")
        key = (file_type, digest)
        if key in cache:
            return cache[key]
        if hashlib.sha256(runtime.read_bytes()).hexdigest() != pwsh_sha256:
            raise ParserCoverageError("native runtime changed during scanning")
        native_process = []
        proof = native_proof(normalized, file_type, str(runtime), native_process.append)
        check_runtime()
        validated = validate_proof(normalized, file_type, proof)
        if file_type == "markdown" and not validated["units"]:
            return original_partial

        def bounded(view, *, file_type, quote_closers, check_runtime):
            def aware(text, runtime_check, **kwargs):
                # Native offsets apply only to this command view. Recursive
                # shell payloads retain the original conservative parser.
                if kwargs.get("_command_string_depth", 0) == 0:
                    kwargs["structural_quote_closers"] = set(kwargs.get("structural_quote_closers") or ()) | quote_closers
                return original_helper(text, runtime_check, **kwargs)
            namespace = dict(original.__globals__)
            namespace["_has_shell_command_word_exhaustion"] = aware
            scanner = types.FunctionType(original.__code__, namespace, original.__name__, original.__defaults__)
            scanner.__kwdefaults__ = original.__kwdefaults__
            return scanner(view, check_runtime, file_type=file_type, complete_context=True)

        partial = check_command_views(normalized, file_type, proof, bounded, check_runtime)
        if module.analyze is not finding_analyzer:
            raise ParserCoverageError("the original source finding analyzer changed")
        proof_bytes = json.dumps(proof, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        records.append({"language": file_type, "sourceSha256": digest,
                        "candidatePaths": source_inventory[digest],
                        "nativeProofSha256": hashlib.sha256(proof_bytes).hexdigest(),
                        "nativeProof": proof, "nativeParserProcess": native_process[0], "partialAfterActualParserRun": partial,
                        "commandCount": sum(len(unit["commands"]) for unit in validated["units"])})
        cache[key] = partial
        return partial

    module.has_bounded_parse_exhaustion = corrected
    return records


def _inventory(root: Path):
    manifest = []
    normalized = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
            raise ParserCoverageError("candidate inventory crosses a linked path")
        if not path.is_file():
            continue
        raw = path.read_bytes()
        relative = path.relative_to(root).as_posix()
        manifest.append({"path": relative, "sha256": hashlib.sha256(raw).hexdigest(), "length": len(raw)})
        try:
            text = normalize_source(raw.decode("utf-8-sig"))
        except (UnicodeError, ParserCoverageError):
            continue
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        normalized.setdefault(digest, []).append(relative)
    if not manifest:
        raise ParserCoverageError("candidate inventory is empty")
    return manifest, normalized


def main(argv=None):
    import argparse
    import importlib.metadata
    import os
    import sys
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pwsh", required=True)
    parser.add_argument("--pwsh-sha256", required=True)
    parser.add_argument("--skill-root", required=True)
    parser.add_argument("--report-path", required=True)
    parser.add_argument("--evidence-path", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--candidate-identity", required=True)
    args = parser.parse_args(argv)
    if (not re.fullmatch(r"[0-9a-f]{40}", args.source_revision)
            or not re.fullmatch(r"[0-9a-f]{64}", args.candidate_identity)
            or not re.fullmatch(r"[0-9a-f]{64}", args.pwsh_sha256)):
        raise ParserCoverageError("run binding has an invalid identity")
    root = Path(args.skill_root)
    if not root.is_absolute() or not root.is_dir():
        raise ParserCoverageError("candidate root must be an existing absolute directory")
    for ancestor in (root, *root.parents):
        if ancestor.is_symlink() or (hasattr(ancestor, "is_junction") and ancestor.is_junction()):
            raise ParserCoverageError("candidate root has a linked ancestor")
    report = Path(args.report_path)
    evidence = Path(args.evidence_path)
    if report == evidence:
        raise ParserCoverageError("report and profile evidence must be distinct")
    for output in (report, evidence):
        if (not output.is_absolute() or output.exists() or not output.parent.is_dir()
                or output == root or root in output.parents):
            raise ParserCoverageError("scan outputs must be new files outside candidate")
        for ancestor in (output.parent, *output.parent.parents):
            if ancestor.is_symlink() or (hasattr(ancestor, "is_junction") and ancestor.is_junction()):
                raise ParserCoverageError("scan output has a linked ancestor")
    manifest, normalized = _inventory(root)
    from skillspector.nodes.analyzers import static_patterns_tool_misuse as module
    records = install_bridge(args.pwsh, args.pwsh_sha256, module,
                             importlib.metadata.version("skillspector"), normalized)
    from skillspector.cli import app
    result = 0
    try:
        app(args=["scan", str(root), "--no-llm", "--format", "json", "--output", str(report)],
            prog_name="skillspector-central-static")
    except SystemExit as error:
        result = error.code if isinstance(error.code, int) else 10
    after, _ = _inventory(root)
    if after != manifest:
        raise ParserCoverageError("candidate changed during actual scanner graph execution")
    if not report.is_file():
        raise ParserCoverageError("actual scanner graph omitted its report")
    report_bytes = report.read_bytes()
    native_report = json.loads(report_bytes)
    value = {"schemaVersion": 1, "profile": PROFILE, "signed": False,
             "authorizationGranted": False, "authorizedOperations": [], "releaseEligible": False,
             "applicabilityStatus": "not-verified", "executionProvenanceStatus": "not-verified",
             "sourceRevision": args.source_revision,
             "candidateIdentity": args.candidate_identity, "candidateInventory": manifest,
             "officialScannerVersion": OFFICIAL_VERSION,
             "officialScannerReleaseCommit": OFFICIAL_RELEASE_COMMIT,
             "officialScannerReleaseAssetSha256": OFFICIAL_RELEASE_ASSET_SHA256,
             "officialAnalyzerSha256": OFFICIAL_MODULE_SHA256,
             "nativeParserRuntimePath": args.pwsh, "nativeParserRuntimeSha256": args.pwsh_sha256,
             "installedToolModified": False, "originalSourceFindingAnalyzerUnchanged": True,
             "scannerGraphExecuted": True, "scannerExitCode": result,
             "correctedReportSha256": hashlib.sha256(report_bytes).hexdigest(),
             "actualCompleteness": native_report.get("analysis_completeness"), "correctedComponents": records}
    with evidence.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    return result


if __name__ == "__main__":
    import sys
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit("central static parser failed closed: " + str(error))
