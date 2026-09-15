"""Inspect the registered and graph-wired semantic nodes of one installed SkillSpector.

This pre-scan probe does not execute an LLM or issue a semantic receipt. A trusted
supervisor must still authenticate the frozen tool, consent, scan and signer.
"""

from __future__ import annotations

import argparse
from hashlib import sha256
import importlib.metadata
import json
import os
from pathlib import Path
import re
import sys
from typing import Mapping, Sequence


VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ANALYZER_PATTERN = re.compile(r"^semantic_[a-z0-9_]+$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _exact_ids(values: Sequence[str], context: str) -> list[str]:
    if isinstance(values, (str, bytes)) or not values:
        raise ValueError(f"{context} must contain a non-empty semantic analyzer set")
    ids = list(values)
    if any(not isinstance(value, str) or not ANALYZER_PATTERN.fullmatch(value) for value in ids):
        raise ValueError(f"{context} contains an invalid semantic analyzer identity")
    if len(ids) != len(set(ids)):
        raise ValueError(f"{context} contains a duplicate semantic analyzer identity")
    return sorted(ids)


def evaluate_inventory(
    expected_version: str,
    installed_version: str,
    registered: Sequence[str],
    wired: Sequence[str],
    module_hashes: Mapping[str, str],
) -> dict[str, object]:
    """Reject ambiguous tool identity and reveal a skipped registered analyzer."""
    if (
        not isinstance(expected_version, str)
        or not VERSION_PATTERN.fullmatch(expected_version)
        or not isinstance(installed_version, str)
        or installed_version != expected_version
    ):
        raise ValueError("installed SkillSpector version differs from the frozen resolver version")
    registered_ids = _exact_ids(registered, "registered analyzers")
    wired_ids = [] if not wired else _exact_ids(wired, "graph-wired analyzers")
    registered_set = set(registered_ids)
    wired_set = set(wired_ids)
    if wired_set - registered_set:
        raise ValueError("graph contains an unregistered semantic analyzer")
    if not isinstance(module_hashes, Mapping) or set(module_hashes) != registered_set:
        raise ValueError("module source digest set does not match registered semantic analyzers")
    if any(
        not isinstance(module_hashes[identity], str)
        or not SHA_PATTERN.fullmatch(module_hashes[identity])
        for identity in registered_ids
    ):
        raise ValueError("semantic analyzer module source digest is missing or invalid")
    missing = sorted(registered_set - wired_set)
    return {
        "installedVersion": installed_version,
        "registeredSemanticAnalyzerIds": registered_ids,
        "wiredSemanticAnalyzerIds": wired_ids,
        "missingWiredAnalyzerIds": missing,
        "moduleSourceSha256": {identity: module_hashes[identity] for identity in registered_ids},
        "scannerReady": not missing,
    }


def validate_output_path(output: str | Path, source_root: str | Path) -> Path:
    """Resolve the unsigned output outside source and reject linked parents."""
    full = Path(os.path.abspath(output))
    authority = Path(os.path.abspath(source_root))
    if full == authority or authority in full.parents:
        raise ValueError("semantic inventory probe output must be outside authority source")
    if not full.parent.is_dir():
        raise ValueError("semantic inventory probe output parent does not exist")
    for entry in (full, *full.parents):
        if entry.exists() and (
            entry.is_symlink() or (hasattr(entry, "is_junction") and entry.is_junction())
        ):
            raise ValueError("semantic inventory probe output must not use a linked path")
    actual = full.resolve(strict=False)
    real_authority = authority.resolve(strict=True)
    if actual == real_authority or real_authority in actual.parents:
        raise ValueError("semantic inventory probe output resolves into authority source")
    if full.exists():
        raise ValueError("semantic inventory probe output already exists")
    return full


def validate_module_source(source_value: str | Path, install_prefix: str | Path) -> Path:
    """Bind a dynamically registered module to the isolated installed venv."""
    source = Path(os.path.abspath(source_value))
    prefix = Path(os.path.abspath(install_prefix))
    if not prefix.is_dir() or not source.is_file() or source.suffix != ".py":
        raise ValueError("semantic analyzer module is not a regular installed Python source")
    for entry in (source, *source.parents):
        if entry.exists() and (
            entry.is_symlink() or (hasattr(entry, "is_junction") and entry.is_junction())
        ):
            raise ValueError("semantic analyzer module source uses a linked path")
    actual = source.resolve(strict=True)
    actual_prefix = prefix.resolve(strict=True)
    if not actual.is_relative_to(actual_prefix) or "site-packages" not in actual.parts:
        raise ValueError("semantic analyzer module source is outside the isolated installation")
    return actual


def _installed_graph_inventory() -> tuple[str, list[str], list[str], dict[str, str]]:
    # Import creates SkillSpector's graph and applies its current provider gate.
    # A newly available provider therefore needs a fresh frozen tool process.
    from skillspector.graph import graph
    from skillspector.nodes.analyzers import ANALYZER_MODULES, ANALYZER_NODE_IDS

    if sys.prefix == sys.base_prefix:
        raise ValueError("semantic scanner probe requires the resolver's isolated Python venv")
    distribution = importlib.metadata.distribution("skillspector")
    metadata_root = Path(str(distribution.locate_file(""))).resolve(strict=True)
    install_prefix = Path(sys.prefix).resolve(strict=True)
    if not metadata_root.is_relative_to(install_prefix) or "site-packages" not in metadata_root.parts:
        raise ValueError("SkillSpector distribution metadata is outside the isolated installation")
    installed_version = distribution.version
    registered = [identity for identity in ANALYZER_NODE_IDS if identity.startswith("semantic_")]
    wired = [identity for identity in graph.get_graph().nodes if identity.startswith("semantic_")]
    hashes: dict[str, str] = {}
    for identity in registered:
        module = ANALYZER_MODULES.get(identity)
        source_value = getattr(module, "__file__", None)
        node_value = getattr(module, "node", None)
        if not isinstance(source_value, str) or not callable(node_value):
            raise ValueError("registered semantic analyzer has no source or callable node")
        source = validate_module_source(source_value, install_prefix)
        hashes[identity] = sha256(source.read_bytes()).hexdigest()
    return installed_version, registered, wired, hashes


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--output-path", required=True)
    parser.add_argument(
        "--observe-only", action="store_true", help="write an unready diagnostic without returning exit 10"
    )
    args = parser.parse_args(argv)
    installed, registered, wired, hashes = _installed_graph_inventory()
    inventory = evaluate_inventory(args.expected_version, installed, registered, wired, hashes)
    output = validate_output_path(args.output_path, Path(__file__).resolve().parents[1])
    probe = {
        "schemaVersion": 1,
        "probeType": "semantic-analyzer-inventory-probe-v1",
        **inventory,
        "scanExecuted": False,
        "analyzerCoverageVerified": False,
        "consentStatus": "pending",
        "signed": False,
        "releaseEligible": False,
    }
    with output.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(probe, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    print(
        json.dumps(
            {
                "scannerReady": inventory["scannerReady"],
                "registeredCount": len(inventory["registeredSemanticAnalyzerIds"]),
                "wiredCount": len(inventory["wiredSemanticAnalyzerIds"]),
                "outputPath": str(output),
            }
        )
    )
    return 0 if inventory["scannerReady"] or args.observe_only else 10


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, importlib.metadata.PackageNotFoundError) as exc:
        sys.exit(f"semantic inventory probe failed closed: {exc}")
