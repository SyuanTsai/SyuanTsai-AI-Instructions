#!/usr/bin/env python3
"""Materialize a verified PyPI wheel pool and resolve it without pip network access.

The online phase is owned by this helper and never asks pip to traverse dependency
metadata.  It lazily adds one older compatible candidate per known project when
the current local pool cannot be solved.  Every candidate is hash-checked against
the approved PEP 691 Simple JSON response and its wheel metadata is validated
before pip can see it.  pip then performs the actual dependency backtracking with
--no-index against the run-owned pool.
"""

from __future__ import annotations

import argparse
import email.policy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass, replace
from email.parser import BytesParser
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Mapping, MutableMapping, Optional, Sequence, Set, Tuple

import pip
from pip._vendor.packaging.markers import default_environment
from pip._vendor.packaging.requirements import InvalidRequirement, Requirement
from pip._vendor.packaging.specifiers import InvalidSpecifier, SpecifierSet
from pip._vendor.packaging.tags import Tag, sys_tags
from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename
from pip._vendor.packaging.version import InvalidVersion, Version


SCHEMA_VERSION = 1
APPROVED_INDEX = "https://pypi.org/simple"
APPROVED_ARTIFACT_HOSTS = frozenset(("files.pythonhosted.org", "pypi.org"))
SIMPLE_JSON_MEDIA_TYPE = "application/vnd.pypi.simple.v1+json"
MAX_WHEEL_BYTES = 512 * 1024 * 1024
MAX_METADATA_BYTES = 8 * 1024 * 1024
MAX_SIMPLE_JSON_BYTES = 32 * 1024 * 1024
MAX_EVIDENCE_BYTES = 64 * 1024 * 1024
MAX_REJECTION_REASON_BYTES = 4096
SHA256_RE = __import__("re").compile(r"^[0-9a-f]{64}$")


class ClosureError(RuntimeError):
    """A fail-closed acquisition or resolution error."""


def validate_https_url(url: str, allowed_hosts: Iterable[str]) -> str:
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError as error:
        raise ClosureError(f"Invalid Python distribution URL: {url!r}") from error
    if (
        parsed.scheme != "https"
        or parsed.hostname not in set(allowed_hosts)
        or port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or bool(parsed.query)
        or bool(parsed.fragment)
    ):
        raise ClosureError(f"Unapproved Python distribution URL: {url!r}")
    return url


class ValidatedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed_hosts: Iterable[str]) -> None:
        super().__init__()
        self.allowed_hosts = frozenset(allowed_hosts)

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):  # type: ignore[no-untyped-def]
        # Validate before urllib follows the redirect; post-response validation is
        # too late because an unapproved target would already have been contacted.
        validate_https_url(new_url, self.allowed_hosts)
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


@dataclass(frozen=True)
class Descriptor:
    project: str
    version: Version
    filename: str
    url: str
    sha256: str
    tag_rank: int
    build: Tuple[int, str]
    simple_requires_python: Optional[str] = None
    enforce_simple_requires_python: bool = False
    source_path: Optional[Path] = None


@dataclass
class WheelMetadata:
    name: str
    normalized_name: str
    version: str
    requires_python: Optional[str]
    requirements: List[Requirement]
    provides_extras: Set[str]


@dataclass
class PoolEntry:
    descriptor: Descriptor
    path: Path
    metadata: WheelMetadata
    source_kind: str

    def to_json(self) -> Mapping[str, object]:
        return {
            "name": self.metadata.name,
            "normalizedName": self.metadata.normalized_name,
            "version": self.metadata.version,
            "requiresPython": self.metadata.requires_python,
            "file": self.path.name,
            "sha256": self.descriptor.sha256,
            "sourceKind": self.source_kind,
            "sourceUrl": self.descriptor.url,
        }


def stable_entry_identity(entry: Mapping[str, object]) -> Mapping[str, object]:
    return {
        "name": entry["name"],
        "normalizedName": entry["normalizedName"],
        "version": entry["version"],
        "requiresPython": entry["requiresPython"],
        "file": entry["file"],
        "sha256": entry["sha256"],
        "sourceKind": entry["sourceKind"],
    }


def stable_rejected_candidate_identity(entry: Mapping[str, object]) -> Mapping[str, object]:
    return {
        "project": entry["project"],
        "filename": entry["filename"],
        "reason": entry["reason"],
    }


def canonical_hash(value: object) -> str:
    payload = json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def bounded_rejection_reason(error: ClosureError) -> str:
    text = str(error)
    if len(text.encode("utf-8")) <= MAX_REJECTION_REASON_BYTES:
        return text
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return f"{text[:1024]}... [truncated-reason-sha256={digest}]"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")


def safe_filename(value: str) -> str:
    if not value or Path(value).name != value or "/" in value or "\\" in value:
        raise ClosureError(f"Unsafe wheel filename: {value!r}")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ClosureError(f"Wheel filename contains a control character: {value!r}")
    return value


def simple_file_is_yanked(item: Mapping[str, object], filename: str) -> bool:
    if "yanked" not in item:
        return False
    value = item["yanked"]
    if type(value) is bool:
        return bool(value)
    if isinstance(value, str):
        # PEP 691 uses every string, including an empty reason, to mean yanked.
        return True
    raise ClosureError(f"Simple JSON wheel {filename!r} has an invalid yanked value")


def normalize_requires_python(value: object, context: str) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ClosureError(f"{context} has a non-string Requires-Python value")
    normalized = value.strip()
    if not normalized or any(ord(character) < 32 or ord(character) == 127 for character in normalized):
        raise ClosureError(f"{context} has an empty or unsafe Requires-Python value")
    try:
        SpecifierSet(normalized)
    except InvalidSpecifier as error:
        raise ClosureError(f"{context} has invalid Requires-Python: {value!r}") from error
    return normalized


def requires_python_allows(value: object, python_version: Version, context: str) -> bool:
    normalized = normalize_requires_python(value, context)
    return normalized is None or SpecifierSet(normalized).contains(python_version, prereleases=True)


def validate_zip_entries(archive: zipfile.ZipFile, wheel_path: Path) -> None:
    exact: Set[str] = set()
    folded: Set[str] = set()
    for info in archive.infolist():
        name = info.filename
        pure = PurePosixPath(name)
        raw_path = name[:-1] if name.endswith("/") else name
        raw_parts = raw_path.split("/")
        if (
            not name
            or "\\" in name
            or pure.is_absolute()
            or any(part in ("", ".", "..") or ":" in part for part in raw_parts)
            or any(ord(character) < 32 or ord(character) == 127 for character in name)
        ):
            raise ClosureError(f"Unsafe ZIP entry {name!r} in {wheel_path.name!r}")
        if name in exact or name.casefold() in folded:
            raise ClosureError(f"Duplicate or case-colliding ZIP entry {name!r} in {wheel_path.name!r}")
        exact.add(name)
        folded.add(name.casefold())
        unix_mode = (info.external_attr >> 16) & 0xFFFF
        file_type = unix_mode & 0o170000
        if file_type not in (0, 0o100000, 0o040000):
            raise ClosureError(f"Special ZIP entry {name!r} is not allowed in {wheel_path.name!r}")


def read_wheel_metadata(path: Path) -> WheelMetadata:
    try:
        with zipfile.ZipFile(path, "r") as archive:
            validate_zip_entries(archive, path)
            metadata_entries = [
                info
                for info in archive.infolist()
                if info.filename.count("/") == 1 and info.filename.endswith(".dist-info/METADATA")
            ]
            if len(metadata_entries) != 1:
                raise ClosureError(
                    f"Expected exactly one top-level dist-info/METADATA in {path.name!r}; "
                    f"found {len(metadata_entries)}"
                )
            info = metadata_entries[0]
            if info.file_size > MAX_METADATA_BYTES:
                raise ClosureError(f"Wheel metadata is too large in {path.name!r}")
            raw = archive.read(info)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        if isinstance(error, ClosureError):
            raise
        raise ClosureError(f"Cannot inspect wheel {path.name!r}: {error}") from error

    message = BytesParser(policy=email.policy.default).parsebytes(raw)
    names = message.get_all("Name", [])
    versions = message.get_all("Version", [])
    if len(names) != 1 or len(versions) != 1:
        raise ClosureError(f"Wheel {path.name!r} must contain exactly one Name and Version field")
    name = str(names[0]).strip()
    version_text = str(versions[0]).strip()
    if not name or not version_text or "\n" in name or "\n" in version_text:
        raise ClosureError(f"Wheel {path.name!r} contains an invalid Name or Version")
    try:
        Version(version_text)
    except InvalidVersion as error:
        raise ClosureError(f"Wheel {path.name!r} has an invalid METADATA Version: {version_text!r}") from error

    requires_python_fields = message.get_all("Requires-Python", [])
    if len(requires_python_fields) > 1:
        raise ClosureError(f"Wheel {path.name!r} must contain at most one Requires-Python field")
    requires_python = normalize_requires_python(
        None if not requires_python_fields else str(requires_python_fields[0]),
        f"Wheel {path.name!r} METADATA",
    )

    requirements: List[Requirement] = []
    for raw_requirement in message.get_all("Requires-Dist", []):
        try:
            requirement = Requirement(str(raw_requirement))
        except InvalidRequirement as error:
            raise ClosureError(f"Invalid Requires-Dist in {path.name!r}: {error}") from error
        if requirement.url is not None:
            raise ClosureError(
                f"Python direct dependency reference is not allowed in {path.name!r}: {raw_requirement!r}"
            )
        requirements.append(requirement)

    extras = {canonicalize_name(str(item)) for item in message.get_all("Provides-Extra", [])}
    return WheelMetadata(
        name=name,
        normalized_name=canonicalize_name(name),
        version=version_text,
        requires_python=requires_python,
        requirements=requirements,
        provides_extras=extras,
    )


def verify_candidate(path: Path, descriptor: Descriptor) -> WheelMetadata:
    if path.name != descriptor.filename:
        raise ClosureError(f"Candidate path/filename mismatch for {descriptor.filename!r}")
    actual_hash = file_sha256(path)
    if actual_hash != descriptor.sha256:
        raise ClosureError(
            f"Candidate hash mismatch for {descriptor.filename!r}: expected {descriptor.sha256}, got {actual_hash}"
        )
    metadata = read_wheel_metadata(path)
    if metadata.normalized_name != descriptor.project:
        raise ClosureError(
            f"Candidate METADATA Name mismatch for {descriptor.filename!r}: "
            f"expected {descriptor.project!r}, got {metadata.normalized_name!r}"
        )
    if Version(metadata.version) != descriptor.version:
        raise ClosureError(
            f"Candidate METADATA Version mismatch for {descriptor.filename!r}: "
            f"expected {descriptor.version}, got {metadata.version!r}"
        )
    current_python = Version(".".join(str(part) for part in sys.version_info[:3]))
    if metadata.requires_python is not None and not SpecifierSet(metadata.requires_python).contains(
        current_python, prereleases=True
    ):
        raise ClosureError(
            f"Candidate METADATA Requires-Python is incompatible with {current_python} "
            f"for {descriptor.filename!r}: {metadata.requires_python!r}"
        )
    if descriptor.enforce_simple_requires_python:
        simple_requires_python = normalize_requires_python(
            descriptor.simple_requires_python,
            f"Simple JSON wheel {descriptor.filename!r}",
        )
        requires_python_matches = simple_requires_python is None and metadata.requires_python is None
        if simple_requires_python is not None and metadata.requires_python is not None:
            requires_python_matches = SpecifierSet(simple_requires_python) == SpecifierSet(metadata.requires_python)
        if not requires_python_matches:
            raise ClosureError(
                f"Candidate Requires-Python mismatch for {descriptor.filename!r}: "
                f"Simple JSON={simple_requires_python!r}, METADATA={metadata.requires_python!r}"
            )
    parsed_name, parsed_version, _, _ = parse_wheel_filename(descriptor.filename)
    if canonicalize_name(parsed_name) != descriptor.project or parsed_version != descriptor.version:
        raise ClosureError(f"Candidate wheel filename identity mismatch: {descriptor.filename!r}")
    return metadata


class PyPISimpleCatalog:
    def __init__(self, index_url: str) -> None:
        normalized = index_url.rstrip("/")
        if normalized != APPROVED_INDEX:
            raise ClosureError(f"Unapproved Python Simple index: {index_url!r}")
        self.index_url = normalized
        self._cache: Dict[str, List[Descriptor]] = {}
        self._rejected_candidates: List[Mapping[str, str]] = []
        self._tag_rank: Dict[Tag, int] = {tag: rank for rank, tag in enumerate(sys_tags())}
        self._python_version = Version(".".join(str(part) for part in sys.version_info[:3]))
        self._simple_opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            ValidatedRedirectHandler(("pypi.org",)),
        )
        self._artifact_opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            ValidatedRedirectHandler(APPROVED_ARTIFACT_HOSTS),
        )

    @staticmethod
    def _validate_remote_url(url: str, allowed_hosts: Iterable[str]) -> str:
        return validate_https_url(url, allowed_hosts)

    def rejected_candidates(self) -> List[Mapping[str, str]]:
        return sorted(
            self._rejected_candidates,
            key=lambda entry: (entry["project"], entry["filename"], entry["reason"]),
        )

    def descriptors(self, project: str) -> List[Descriptor]:
        project = canonicalize_name(project)
        if project in self._cache:
            return self._cache[project]
        url = f"{self.index_url}/{urllib.parse.quote(project, safe='-')}/"
        request = urllib.request.Request(url, headers={"Accept": SIMPLE_JSON_MEDIA_TYPE})
        try:
            with self._simple_opener.open(request, timeout=60) as response:
                final_url = self._validate_remote_url(response.geturl(), ("pypi.org",))
                content_type = response.headers.get_content_type()
                if content_type not in (SIMPLE_JSON_MEDIA_TYPE, "application/json"):
                    raise ClosureError(
                        f"Approved Simple endpoint returned unsupported content type {content_type!r} for {project!r}"
                    )
                content_length = response.headers.get("Content-Length")
                if content_length is not None and int(content_length) > MAX_SIMPLE_JSON_BYTES:
                    raise ClosureError(f"Simple JSON response is too large for {project!r}")
                raw_payload = response.read(MAX_SIMPLE_JSON_BYTES + 1)
                if len(raw_payload) > MAX_SIMPLE_JSON_BYTES:
                    raise ClosureError(f"Simple JSON response is too large for {project!r}")
                payload = json.loads(raw_payload.decode("utf-8"))
        except ClosureError:
            raise
        except Exception as error:
            raise ClosureError(f"Cannot read approved Simple JSON for {project!r}: {error}") from error
        if not isinstance(payload, dict):
            raise ClosureError(f"Simple JSON payload must be an object for {project!r}")
        payload_name = payload.get("name")
        if not isinstance(payload_name, str) or canonicalize_name(payload_name) != project:
            raise ClosureError(f"Simple JSON project identity mismatch for {project!r} at {final_url!r}")
        files = payload.get("files")
        if not isinstance(files, list):
            raise ClosureError(f"Simple JSON files must be an array for {project!r}")

        per_version: MutableMapping[Version, List[Descriptor]] = {}
        for item in files:
            if not isinstance(item, dict):
                raise ClosureError(f"Simple JSON contains a non-object file for {project!r}")
            filename_value = item.get("filename")
            if not isinstance(filename_value, str):
                raise ClosureError(f"Simple JSON contains a file with a non-string filename for {project!r}")
            filename = filename_value
            if not filename.endswith(".whl"):
                continue
            try:
                safe_filename(filename)
                parsed_name, version, build, tags = parse_wheel_filename(filename)
            except Exception:
                continue
            if canonicalize_name(parsed_name) != project:
                continue
            if simple_file_is_yanked(item, filename):
                continue
            try:
                requires_python = normalize_requires_python(
                    item.get("requires-python"),
                    f"Simple JSON wheel {filename!r}",
                )
                if not requires_python_allows(
                    requires_python,
                    self._python_version,
                    f"Simple JSON wheel {filename!r}",
                ):
                    continue
            except ClosureError as error:
                # A malformed candidate is never admitted to the verified pool. Keep
                # deterministic rejection evidence so a different valid candidate may
                # be selected without hiding the upstream metadata defect.
                self._rejected_candidates.append(
                    {"project": project, "filename": filename, "reason": bounded_rejection_reason(error)}
                )
                continue
            ranks = [self._tag_rank[tag] for tag in tags if tag in self._tag_rank]
            if not ranks:
                continue
            hashes = item.get("hashes")
            sha256 = hashes.get("sha256") if isinstance(hashes, dict) else None
            if not isinstance(sha256, str) or not SHA256_RE.fullmatch(sha256):
                raise ClosureError(f"Simple JSON wheel {filename!r} is missing an exact SHA-256 hash")
            artifact_url_value = item.get("url")
            if not isinstance(artifact_url_value, str) or not artifact_url_value:
                raise ClosureError(f"Simple JSON wheel {filename!r} is missing a string artifact URL")
            artifact_url = urllib.parse.urljoin(final_url, artifact_url_value)
            self._validate_remote_url(artifact_url, APPROVED_ARTIFACT_HOSTS)
            build_key = build if build else (-1, "")
            descriptor = Descriptor(
                project=project,
                version=version,
                filename=filename,
                url=artifact_url,
                sha256=sha256,
                tag_rank=min(ranks),
                build=build_key,
                simple_requires_python=requires_python,
                enforce_simple_requires_python=True,
            )
            per_version.setdefault(version, []).append(descriptor)

        selected: List[Descriptor] = []
        for version, candidates in per_version.items():
            # For a version, prefer the current interpreter's highest-ranked tag,
            # then the highest build tag, with filename as a deterministic tie-break.
            best = max(candidates, key=lambda candidate: (-candidate.tag_rank, candidate.build, candidate.filename))
            selected.append(best)
        selected.sort(key=lambda candidate: (candidate.version, -candidate.tag_rank, candidate.build), reverse=True)
        self._cache[project] = selected
        return selected

    def materialize(self, descriptor: Descriptor, destination: Path) -> Path:
        self._validate_remote_url(descriptor.url, APPROVED_ARTIFACT_HOSTS)
        temporary = destination / f".{uuid.uuid4().hex}.download"
        digest = hashlib.sha256()
        total = 0
        request = urllib.request.Request(descriptor.url, headers={"Accept": "application/octet-stream"})
        try:
            with self._artifact_opener.open(request, timeout=120) as response, temporary.open("xb") as output:
                self._validate_remote_url(response.geturl(), APPROVED_ARTIFACT_HOSTS)
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_WHEEL_BYTES:
                        raise ClosureError(f"Wheel exceeds size limit: {descriptor.filename!r}")
                    digest.update(chunk)
                    output.write(chunk)
            if digest.hexdigest() != descriptor.sha256:
                raise ClosureError(
                    f"Downloaded wheel hash mismatch for {descriptor.filename!r}: "
                    f"expected {descriptor.sha256}, got {digest.hexdigest()}"
                )
            target = destination / descriptor.filename
            if target.exists():
                if file_sha256(target) != descriptor.sha256:
                    raise ClosureError(f"Candidate filename collision for {descriptor.filename!r}")
                temporary.unlink()
                return target
            os.replace(str(temporary), str(target))
            return target
        except Exception:
            if temporary.exists():
                temporary.unlink()
            raise


class LocalCatalog:
    """In-memory catalog used only by the offline self-test."""

    def __init__(self, descriptors: Sequence[Descriptor]) -> None:
        self._by_project: Dict[str, List[Descriptor]] = {}
        for descriptor in descriptors:
            self._by_project.setdefault(descriptor.project, []).append(descriptor)
        for values in self._by_project.values():
            values.sort(key=lambda candidate: candidate.version, reverse=True)

    def descriptors(self, project: str) -> List[Descriptor]:
        return list(self._by_project.get(canonicalize_name(project), []))

    def rejected_candidates(self) -> List[Mapping[str, str]]:
        return []

    def materialize(self, descriptor: Descriptor, destination: Path) -> Path:
        if descriptor.source_path is None:
            raise ClosureError("Local self-test descriptor is missing source_path")
        target = destination / descriptor.filename
        shutil.copyfile(descriptor.source_path, target)
        return target


class LazyPoolResolver:
    def __init__(
        self,
        catalog: object,
        root_wheel: Path,
        root_sha256: str,
        candidate_dir: Path,
        plan_path: Path,
    ) -> None:
        self.catalog = catalog
        self.root_wheel = root_wheel.resolve(strict=True)
        self.root_sha256 = root_sha256
        self.candidate_dir = candidate_dir.resolve()
        self.plan_path = plan_path.resolve()
        self.candidate_dir.mkdir(parents=True, exist_ok=False)
        self.requirements: Dict[str, Dict[str, Requirement]] = {}
        self.requested_extras: Dict[str, Set[str]] = {}
        self.entries: Dict[str, PoolEntry] = {}
        self.attempted: Dict[str, Set[str]] = {}
        self.scan_state: Dict[str, Tuple[str, ...]] = {}
        self.last_pip_error = ""

        if not SHA256_RE.fullmatch(root_sha256) or file_sha256(self.root_wheel) != root_sha256:
            raise ClosureError("Root wheel hash does not match its approved release digest")
        parsed_name, parsed_version, build, tags = parse_wheel_filename(self.root_wheel.name)
        root_descriptor = Descriptor(
            project=canonicalize_name(parsed_name),
            version=parsed_version,
            filename=safe_filename(self.root_wheel.name),
            url=self.root_wheel.as_uri(),
            sha256=root_sha256,
            tag_rank=0,
            build=build if build else (-1, ""),
            source_path=self.root_wheel,
        )
        root_copy = self.candidate_dir / root_descriptor.filename
        shutil.copyfile(self.root_wheel, root_copy)
        root_metadata = verify_candidate(root_copy, root_descriptor)
        self.root_project = root_metadata.normalized_name
        self.root_copy = root_copy
        self.entries[root_copy.name] = PoolEntry(root_descriptor, root_copy, root_metadata, "approved-root-wheel")
        self._register_requirement(Requirement(f"{root_metadata.name}=={root_metadata.version}"))
        self._discover_dependencies()

    def _register_requirement(self, requirement: Requirement) -> bool:
        if requirement.url is not None:
            raise ClosureError(f"Python direct dependency reference is not allowed: {requirement}")
        project = canonicalize_name(requirement.name)
        raw = str(requirement)
        bucket = self.requirements.setdefault(project, {})
        changed = raw not in bucket
        bucket[raw] = requirement
        extras = self.requested_extras.setdefault(project, set())
        previous_count = len(extras)
        extras.update(canonicalize_name(extra) for extra in requirement.extras)
        return changed or len(extras) != previous_count

    def _active_requirements(self, metadata: WheelMetadata, extras: Set[str]) -> Iterable[Requirement]:
        environment = default_environment()
        # pip models an extras candidate as a dependency on the exact base
        # candidate plus the requested-extra dependencies.  Candidate discovery
        # must therefore materialize both contexts before offline pip can solve.
        contexts = [""] + sorted(extras.intersection(metadata.provides_extras))
        for requirement in metadata.requirements:
            if requirement.marker is None:
                yield requirement
                continue
            if any(requirement.marker.evaluate({**environment, "extra": extra}) for extra in contexts):
                yield requirement

    def _discover_dependencies(self) -> bool:
        changed_any = False
        while True:
            changed = False
            for entry in list(self.entries.values()):
                project = entry.metadata.normalized_name
                extras = tuple(sorted(self.requested_extras.get(project, set())))
                if self.scan_state.get(entry.path.name) == extras:
                    continue
                self.scan_state[entry.path.name] = extras
                for requirement in self._active_requirements(entry.metadata, set(extras)):
                    changed = self._register_requirement(requirement) or changed
            changed_any = changed_any or changed
            if not changed:
                return changed_any

    def _eligible(self, descriptor: Descriptor) -> bool:
        requirements = self.requirements.get(descriptor.project, {})
        if not requirements:
            return False
        return any(
            not requirement.specifier
            # Candidate materialization is an over-approximation.  Include
            # prereleases that satisfy the textual range and let offline pip
            # apply its authoritative prerelease preference during resolution.
            or requirement.specifier.contains(descriptor.version, prereleases=True)
            for requirement in requirements.values()
        )

    def _add_next_candidate(self, project: str) -> bool:
        if project == self.root_project:
            return False
        attempted = self.attempted.setdefault(project, set())
        for descriptor in self.catalog.descriptors(project):
            if descriptor.filename in attempted or not self._eligible(descriptor):
                continue
            attempted.add(descriptor.filename)
            path = self.catalog.materialize(descriptor, self.candidate_dir)
            metadata = verify_candidate(path, descriptor)
            self.entries[path.name] = PoolEntry(descriptor, path, metadata, "pypi-simple-json")
            self._discover_dependencies()
            return True
        return False

    def _seed_new_projects(self) -> bool:
        changed_any = False
        while True:
            changed = False
            for project in sorted(self.requirements):
                if project == self.root_project:
                    continue
                has_candidate = any(entry.metadata.normalized_name == project for entry in self.entries.values())
                if not has_candidate and self._add_next_candidate(project):
                    changed = True
                    changed_any = True
            self._discover_dependencies()
            if not changed:
                return changed_any

    def _run_offline_plan(self) -> bool:
        if self.plan_path.exists():
            self.plan_path.unlink()
        command = [
            sys.executable,
            "-I",
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            "--no-cache-dir",
            "--dry-run",
            "--ignore-installed",
            "--no-index",
            f"--find-links={self.candidate_dir}",
            "--only-binary=:all:",
            "--report",
            str(self.plan_path),
            str(self.root_copy),
        ]
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.last_pip_error = (result.stdout + "\n" + result.stderr).strip()
        return result.returncode == 0 and self.plan_path.is_file()

    def resolve(self) -> int:
        self._seed_new_projects()
        rounds = 0
        while True:
            rounds += 1
            if self._run_offline_plan():
                return rounds
            expanded = False
            for project in sorted(self.requirements):
                expanded = self._add_next_candidate(project) or expanded
            expanded = self._seed_new_projects() or expanded
            if not expanded:
                raise ClosureError(
                    "Verified local wheel candidates are exhausted and pip cannot resolve the root wheel.\n"
                    + self.last_pip_error[-12000:]
                )

    def inventory(self) -> Mapping[str, object]:
        entries = sorted((entry.to_json() for entry in self.entries.values()), key=lambda item: (item["normalizedName"], item["version"], item["file"]))
        stable_entries = [stable_entry_identity(entry) for entry in entries]
        rejected_candidates = [
            stable_rejected_candidate_identity(entry)
            for entry in self.catalog.rejected_candidates()
        ]
        return {
            "schemaVersion": SCHEMA_VERSION,
            "index": APPROVED_INDEX,
            "pipVersion": pip.__version__,
            "yankedAllowed": False,
            "entries": entries,
            "rejectedCandidates": rejected_candidates,
            "inventorySha256": canonical_hash(
                {"entries": stable_entries, "rejectedCandidates": rejected_candidates}
            ),
        }


def path_from_file_url(url: str) -> Path:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost") or parsed.query or parsed.fragment:
        raise ClosureError(f"Offline pip report contains a non-local artifact URL: {url!r}")
    try:
        return Path(urllib.request.url2pathname(urllib.parse.unquote(parsed.path))).resolve(strict=True)
    except OSError as error:
        raise ClosureError(f"Offline pip report selected a missing local artifact: {url!r}") from error


def validate_and_select_plan(
    plan_path: Path,
    resolver: LazyPoolResolver,
    selected_dir: Path,
) -> Mapping[str, object]:
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except Exception as error:
        raise ClosureError(f"Offline pip report is not valid JSON: {error}") from error
    installs = plan.get("install") if isinstance(plan, dict) else None
    if not isinstance(installs, list) or not installs:
        raise ClosureError("Offline pip report must contain a non-empty install array")
    by_path = {entry.path.resolve(): entry for entry in resolver.entries.values()}
    selected: List[PoolEntry] = []
    seen: Set[str] = set()
    for item in installs:
        if not isinstance(item, dict):
            raise ClosureError("Offline pip report install entries must be objects")
        download = item.get("download_info")
        metadata = item.get("metadata")
        if not isinstance(download, dict) or not isinstance(metadata, dict):
            raise ClosureError("Offline pip report entry is missing download_info or metadata")
        path = path_from_file_url(str(download.get("url", "")))
        entry = by_path.get(path)
        if entry is None:
            raise ClosureError(f"Offline pip report selected a path outside the verified candidate pool: {path}")
        hashes = download.get("archive_info", {}).get("hashes", {})
        plan_hash = hashes.get("sha256") if isinstance(hashes, dict) else None
        if plan_hash != entry.descriptor.sha256 or file_sha256(path) != entry.descriptor.sha256:
            raise ClosureError(f"Offline pip report hash mismatch for {path.name!r}")
        normalized_name = canonicalize_name(str(metadata.get("name", "")))
        version = str(metadata.get("version", ""))
        if normalized_name != entry.metadata.normalized_name or version != entry.metadata.version:
            raise ClosureError(f"Offline pip report metadata mismatch for {path.name!r}")
        if normalized_name in seen:
            raise ClosureError(f"Offline pip report selected duplicate project {normalized_name!r}")
        seen.add(normalized_name)
        selected.append(entry)
    if resolver.root_project not in seen:
        raise ClosureError("Offline pip report did not select the approved root wheel")

    selected_dir.mkdir(parents=True, exist_ok=False)
    for entry in selected:
        target = selected_dir / entry.path.name
        shutil.copyfile(entry.path, target)
        if file_sha256(target) != entry.descriptor.sha256:
            raise ClosureError(f"Selected wheel changed while copying: {entry.path.name!r}")
    selected_json = sorted((entry.to_json() for entry in selected), key=lambda item: (item["normalizedName"], item["version"], item["file"]))
    stable_selected = [stable_entry_identity(entry) for entry in selected_json]
    environment = plan.get("environment")
    if not isinstance(environment, dict):
        raise ClosureError("Offline pip report is missing its environment fingerprint")
    return {
        "entries": selected_json,
        "selectedClosureSha256": canonical_hash(stable_selected),
        "selectionPlanSha256": canonical_hash({"environment": environment, "selected": stable_selected}),
        "rawSelectionPlanSha256": file_sha256(plan_path),
    }


def read_evidence_object(path: Path, context: str) -> Mapping[str, object]:
    try:
        if path.stat().st_size > MAX_EVIDENCE_BYTES:
            raise ClosureError(f"{context} exceeds the local evidence size limit")
        value = json.loads(path.read_text(encoding="utf-8"))
    except ClosureError:
        raise
    except Exception as error:
        raise ClosureError(f"{context} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ClosureError(f"{context} must be a JSON object")
    return value


def validate_evidence_entry(value: object, context: str) -> Mapping[str, object]:
    required = frozenset(
        (
            "name",
            "normalizedName",
            "version",
            "requiresPython",
            "file",
            "sha256",
            "sourceKind",
            "sourceUrl",
        )
    )
    if not isinstance(value, dict) or frozenset(value) != required:
        raise ClosureError(f"{context} has an invalid property set")
    string_fields = required.difference(("requiresPython",))
    if any(not isinstance(value[name], str) for name in string_fields):
        raise ClosureError(f"{context} identity properties must be strings")
    name = str(value["name"])
    normalized_name = str(value["normalizedName"])
    version = str(value["version"])
    filename = safe_filename(str(value["file"]))
    sha256 = str(value["sha256"])
    source_kind = str(value["sourceKind"])
    source_url = str(value["sourceUrl"])
    requires_python = normalize_requires_python(value["requiresPython"], context)
    current_python = Version(".".join(str(part) for part in sys.version_info[:3]))
    if requires_python is not None and not SpecifierSet(requires_python).contains(current_python, prereleases=True):
        raise ClosureError(f"{context} Requires-Python excludes the current interpreter")
    if not name or canonicalize_name(name) != normalized_name or not normalized_name:
        raise ClosureError(f"{context} has an invalid project identity")
    try:
        Version(version)
    except InvalidVersion as error:
        raise ClosureError(f"{context} has an invalid version") from error
    if not SHA256_RE.fullmatch(sha256):
        raise ClosureError(f"{context} has an invalid SHA-256")
    if source_kind == "pypi-simple-json":
        validate_https_url(source_url, APPROVED_ARTIFACT_HOSTS)
    elif source_kind == "approved-root-wheel":
        parsed = urllib.parse.urlsplit(source_url)
        if parsed.scheme != "file" or parsed.query or parsed.fragment:
            raise ClosureError(f"{context} has an invalid approved root source URL")
    else:
        raise ClosureError(f"{context} has an invalid source kind")
    return {
        "name": name,
        "normalizedName": normalized_name,
        "version": version,
        "requiresPython": requires_python,
        "file": filename,
        "sha256": sha256,
        "sourceKind": source_kind,
        "sourceUrl": source_url,
    }


def validate_rejected_candidate(value: object, context: str) -> Mapping[str, str]:
    required = frozenset(("project", "filename", "reason"))
    if not isinstance(value, dict) or frozenset(value) != required:
        raise ClosureError(f"{context} has an invalid property set")
    if any(not isinstance(value[name], str) for name in required):
        raise ClosureError(f"{context} fields must be strings")
    project = str(value["project"])
    filename = safe_filename(str(value["filename"]))
    reason = str(value["reason"])
    if not project or canonicalize_name(project) != project:
        raise ClosureError(f"{context} has an invalid project identity")
    if not filename.endswith(".whl"):
        raise ClosureError(f"{context} must identify a wheel filename")
    try:
        parsed_name, _, _, _ = parse_wheel_filename(filename)
    except Exception as error:
        raise ClosureError(f"{context} has an invalid wheel filename") from error
    if canonicalize_name(parsed_name) != project:
        raise ClosureError(f"{context} project does not match its wheel filename")
    if (
        not reason
        or len(reason.encode("utf-8")) > MAX_REJECTION_REASON_BYTES
        or any(ord(character) < 32 or ord(character) == 127 for character in reason)
    ):
        raise ClosureError(f"{context} has an empty or unsafe rejection reason")
    return {"project": project, "filename": filename, "reason": reason}


def verify_evidence(
    candidate_dir: Path,
    selected_dir: Path,
    plan_path: Path,
    inventory_path: Path,
    result_path: Path,
) -> Mapping[str, object]:
    """Recompute every stable identity and cross-check all three evidence files."""

    candidate_root = candidate_dir.resolve(strict=True)
    selected_root = selected_dir.resolve(strict=True)
    if not candidate_root.is_dir() or not selected_root.is_dir():
        raise ClosureError("Candidate and selected evidence roots must be directories")
    inventory = read_evidence_object(inventory_path, "Candidate inventory")
    result = read_evidence_object(result_path, "Closure result")
    plan = read_evidence_object(plan_path, "Offline pip report")

    if (
        type(inventory.get("schemaVersion")) is not int
        or inventory.get("schemaVersion") != SCHEMA_VERSION
        or inventory.get("index") != APPROVED_INDEX
        or not isinstance(inventory.get("pipVersion"), str)
        or inventory.get("pipVersion") != result.get("pipVersion")
        or type(inventory.get("yankedAllowed")) is not bool
        or inventory.get("yankedAllowed") is not False
        or not isinstance(inventory.get("entries"), list)
        or not isinstance(inventory.get("rejectedCandidates"), list)
    ):
        raise ClosureError("Candidate inventory header is inconsistent with the closure result")
    if (
        type(result.get("schemaVersion")) is not int
        or result.get("schemaVersion") != SCHEMA_VERSION
        or type(result.get("resolutionRounds")) is not int
        or int(result.get("resolutionRounds", 0)) <= 0
        or type(result.get("candidateCount")) is not int
        or not isinstance(result.get("selectedEntries"), list)
    ):
        raise ClosureError("Closure result header is invalid")

    inventory_entries = [
        validate_evidence_entry(item, f"Candidate inventory entry {index}")
        for index, item in enumerate(inventory["entries"])
    ]
    inventory_entries.sort(key=lambda item: (item["normalizedName"], item["version"], item["file"]))
    if len(inventory_entries) != int(result["candidateCount"]) or not inventory_entries:
        raise ClosureError("Candidate count is inconsistent with the closure result")
    candidate_by_filename: Dict[str, Mapping[str, object]] = {}
    candidate_by_path: Dict[Path, Mapping[str, object]] = {}
    seen_versions: Set[Tuple[str, str]] = set()
    for entry in inventory_entries:
        filename = str(entry["file"])
        identity = (str(entry["normalizedName"]), str(entry["version"]))
        if filename in candidate_by_filename or identity in seen_versions:
            raise ClosureError("Candidate inventory contains a duplicate file or project version")
        seen_versions.add(identity)
        path = (candidate_root / filename).resolve(strict=True)
        if path.parent != candidate_root or not path.is_file() or file_sha256(path) != entry["sha256"]:
            raise ClosureError(f"Candidate evidence changed or escaped its pool: {filename!r}")
        metadata = read_wheel_metadata(path)
        if (
            metadata.name != entry["name"]
            or metadata.normalized_name != entry["normalizedName"]
            or metadata.version != entry["version"]
            or metadata.requires_python != entry["requiresPython"]
        ):
            raise ClosureError(f"Candidate inventory metadata differs from its wheel: {filename!r}")
        candidate_by_filename[filename] = entry
        candidate_by_path[path] = entry
    candidate_items = list(candidate_root.iterdir())
    if any(not item.is_file() for item in candidate_items) or {
        item.resolve(strict=True) for item in candidate_items
    } != set(candidate_by_path):
        raise ClosureError("Candidate pool contains an unlisted file or directory")
    rejected_candidates = [
        validate_rejected_candidate(item, f"Candidate rejected entry {index}")
        for index, item in enumerate(inventory["rejectedCandidates"])
    ]
    rejected_candidates.sort(key=lambda item: (item["project"], item["filename"], item["reason"]))
    if len(rejected_candidates) != len({
        (entry["project"], entry["filename"], entry["reason"])
        for entry in rejected_candidates
    }):
        raise ClosureError("Candidate rejected evidence contains a duplicate entry")
    inventory_hash = canonical_hash(
        {
            "entries": [stable_entry_identity(entry) for entry in inventory_entries],
            "rejectedCandidates": [stable_rejected_candidate_identity(entry) for entry in rejected_candidates],
        }
    )
    if inventory.get("inventorySha256") != inventory_hash or result.get("candidateInventorySha256") != inventory_hash:
        raise ClosureError("Candidate inventory identity does not match its entries")

    selected_entries = [
        validate_evidence_entry(item, f"Selected closure entry {index}")
        for index, item in enumerate(result["selectedEntries"])
    ]
    selected_entries.sort(key=lambda item: (item["normalizedName"], item["version"], item["file"]))
    if not selected_entries:
        raise ClosureError("Selected closure is empty")
    selected_by_filename: Dict[str, Mapping[str, object]] = {}
    selected_projects: Set[str] = set()
    root_count = 0
    for entry in selected_entries:
        filename = str(entry["file"])
        project = str(entry["normalizedName"])
        if filename in selected_by_filename or project in selected_projects:
            raise ClosureError("Selected closure contains a duplicate file or project")
        inventory_entry = candidate_by_filename.get(filename)
        if inventory_entry != entry:
            raise ClosureError(f"Selected entry is not identical to its candidate evidence: {filename!r}")
        path = (selected_root / filename).resolve(strict=True)
        if path.parent != selected_root or not path.is_file() or file_sha256(path) != entry["sha256"]:
            raise ClosureError(f"Selected evidence changed or escaped its wheelhouse: {filename!r}")
        selected_by_filename[filename] = entry
        selected_projects.add(project)
        if entry["sourceKind"] == "approved-root-wheel":
            root_count += 1
    selected_items = list(selected_root.iterdir())
    expected_selected_paths = {(selected_root / filename).resolve(strict=True) for filename in selected_by_filename}
    if any(not item.is_file() for item in selected_items) or {
        item.resolve(strict=True) for item in selected_items
    } != expected_selected_paths:
        raise ClosureError("Selected wheelhouse contains an unlisted file or directory")
    if root_count != 1:
        raise ClosureError("Selected closure must contain exactly one approved root wheel")
    selected_hash = canonical_hash([stable_entry_identity(entry) for entry in selected_entries])
    if result.get("selectedClosureSha256") != selected_hash:
        raise ClosureError("Selected closure identity does not match its entries")

    installs = plan.get("install")
    environment = plan.get("environment")
    if not isinstance(installs, list) or len(installs) != len(selected_entries) or not isinstance(environment, dict):
        raise ClosureError("Offline pip report is inconsistent with the selected closure")
    planned_files: Set[str] = set()
    for index, item in enumerate(installs):
        if not isinstance(item, dict) or not isinstance(item.get("download_info"), dict) or not isinstance(item.get("metadata"), dict):
            raise ClosureError(f"Offline pip report entry {index} is invalid")
        download = item["download_info"]
        metadata = item["metadata"]
        path = path_from_file_url(str(download.get("url", "")))
        candidate = candidate_by_path.get(path)
        if candidate is None or candidate["file"] not in selected_by_filename:
            raise ClosureError(f"Offline pip report selected an unverified path: {path}")
        filename = str(candidate["file"])
        archive_info = download.get("archive_info")
        hashes = archive_info.get("hashes", {}) if isinstance(archive_info, dict) else {}
        if (
            filename in planned_files
            or not isinstance(hashes, dict)
            or hashes.get("sha256") != candidate["sha256"]
            or canonicalize_name(str(metadata.get("name", ""))) != candidate["normalizedName"]
            or str(metadata.get("version", "")) != candidate["version"]
        ):
            raise ClosureError(f"Offline pip report identity mismatch for {filename!r}")
        planned_files.add(filename)
    if planned_files != set(selected_by_filename):
        raise ClosureError("Offline pip report and selected closure files differ")

    plan_hash = canonical_hash(
        {"environment": environment, "selected": [stable_entry_identity(entry) for entry in selected_entries]}
    )
    raw_plan_hash = file_sha256(plan_path)
    if result.get("selectionPlanSha256") != plan_hash or result.get("rawSelectionPlanSha256") != raw_plan_hash:
        raise ClosureError("Offline pip report identity does not match the closure result")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "verified": True,
        "candidateInventorySha256": inventory_hash,
        "selectionPlanSha256": plan_hash,
        "rawSelectionPlanSha256": raw_plan_hash,
        "selectedClosureSha256": selected_hash,
    }


def verify_command(arguments: argparse.Namespace) -> None:
    verification = verify_evidence(
        Path(arguments.candidate_dir),
        Path(arguments.selected_dir),
        Path(arguments.plan),
        Path(arguments.inventory),
        Path(arguments.result),
    )
    print(json.dumps(verification, ensure_ascii=True, separators=(",", ":"), sort_keys=True))


def resolve_command(arguments: argparse.Namespace) -> None:
    root_wheel = Path(arguments.root_wheel)
    candidate_dir = Path(arguments.candidate_dir)
    selected_dir = Path(arguments.selected_dir)
    plan_path = Path(arguments.plan)
    for directory in (candidate_dir, selected_dir):
        if directory.exists():
            if not directory.is_dir() or any(directory.iterdir()):
                raise ClosureError(f"Resolver output directory must be absent or empty: {directory}")
            directory.rmdir()
    catalog = PyPISimpleCatalog(arguments.index_url)
    resolver = LazyPoolResolver(catalog, root_wheel, arguments.root_sha256, candidate_dir, plan_path)
    rounds = resolver.resolve()
    inventory = resolver.inventory()
    selection = validate_and_select_plan(plan_path, resolver, selected_dir)
    write_json(Path(arguments.inventory), inventory)
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "pipVersion": pip.__version__,
        "resolutionRounds": rounds,
        "candidateCount": len(inventory["entries"]),
        "candidateInventorySha256": inventory["inventorySha256"],
        "selectionPlanSha256": selection["selectionPlanSha256"],
        "rawSelectionPlanSha256": selection["rawSelectionPlanSha256"],
        "selectedClosureSha256": selection["selectedClosureSha256"],
        "selectedEntries": selection["entries"],
    }
    write_json(Path(arguments.result), result)
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":"), sort_keys=True))


def make_test_wheel(
    root: Path,
    name: str,
    version: str,
    requirements: Sequence[str] = (),
    provides_extras: Sequence[str] = (),
    requires_python_fields: Sequence[str] = (),
) -> Path:
    distribution = name.replace("-", "_")
    filename = f"{distribution}-{version}-py3-none-any.whl"
    dist_info = f"{distribution}-{version}.dist-info"
    metadata = f"Metadata-Version: 2.4\nName: {name}\nVersion: {version}\n"
    metadata += "".join(f"Requires-Python: {specifier}\n" for specifier in requires_python_fields)
    metadata += "".join(f"Provides-Extra: {extra}\n" for extra in provides_extras)
    metadata += "".join(f"Requires-Dist: {requirement}\n" for requirement in requirements)
    wheel = "Wheel-Version: 1.0\nGenerator: resolver-self-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
    path = root / filename
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{dist_info}/METADATA", metadata)
        archive.writestr(f"{dist_info}/WHEEL", wheel)
        archive.writestr(f"{dist_info}/RECORD", "")
    return path


def local_descriptor(path: Path) -> Descriptor:
    parsed_name, version, build, tags = parse_wheel_filename(path.name)
    metadata = read_wheel_metadata(path)
    return Descriptor(
        project=canonicalize_name(parsed_name),
        version=version,
        filename=path.name,
        url=f"https://files.pythonhosted.org/packages/resolver-self-test/{path.name}",
        sha256=file_sha256(path),
        tag_rank=0,
        build=build if build else (-1, ""),
        simple_requires_python=metadata.requires_python,
        enforce_simple_requires_python=True,
        source_path=path,
    )


def expect_closure_error(action: object, context: str) -> None:
    try:
        action()
    except ClosureError:
        return
    raise AssertionError(f"Expected fail-closed error: {context}")


def self_test_command(_: argparse.Namespace) -> None:
    with tempfile.TemporaryDirectory(prefix="python-wheel-closure-self-test-") as temporary:
        root = Path(temporary)
        sources = root / "sources"
        sources.mkdir()
        root_wheel = make_test_wheel(
            sources,
            "rootpkg",
            "1.0",
            (
                "a>=1",
                "b>=1",
                "rcpkg==2.0rc1",
                "range-rc>=2.0rc1,<2.0rc3",
                "extra-pkg[foo]==1.0",
            ),
        )
        candidates = [
            make_test_wheel(sources, "a", "2.0", ("c==1.0",)),
            make_test_wheel(sources, "a", "1.0", ("c==2.0",)),
            make_test_wheel(sources, "b", "2.0", ("c==2.0",)),
            make_test_wheel(sources, "c", "2.0"),
            make_test_wheel(sources, "c", "1.0"),
            make_test_wheel(sources, "rcpkg", "2.0rc1"),
            make_test_wheel(sources, "range-rc", "2.0rc2"),
            make_test_wheel(
                sources,
                "extra-pkg",
                "1.0",
                ('foo-dep==1.0; extra == "foo"', 'inactive-dep==1.0; extra != "foo"'),
                ("foo",),
            ),
            make_test_wheel(sources, "foo-dep", "1.0"),
            make_test_wheel(sources, "inactive-dep", "1.0"),
        ]
        resolver = LazyPoolResolver(
            LocalCatalog([local_descriptor(path) for path in candidates]),
            root_wheel,
            file_sha256(root_wheel),
            root / "candidate-pool",
            root / "selection.json",
        )
        rounds = resolver.resolve()
        selection = validate_and_select_plan(root / "selection.json", resolver, root / "selected")
        inventory = resolver.inventory()
        inventory_path = root / "candidate-inventory.json"
        result_path = root / "closure-result.json"
        write_json(inventory_path, inventory)
        write_json(
            result_path,
            {
                "schemaVersion": SCHEMA_VERSION,
                "pipVersion": pip.__version__,
                "resolutionRounds": rounds,
                "candidateCount": len(inventory["entries"]),
                "candidateInventorySha256": inventory["inventorySha256"],
                "selectionPlanSha256": selection["selectionPlanSha256"],
                "rawSelectionPlanSha256": selection["rawSelectionPlanSha256"],
                "selectedClosureSha256": selection["selectedClosureSha256"],
                "selectedEntries": selection["entries"],
            },
        )
        verification = verify_evidence(
            root / "candidate-pool",
            root / "selected",
            root / "selection.json",
            inventory_path,
            result_path,
        )
        if verification["verified"] is not True:
            raise AssertionError("Cross-file evidence verification did not pass")
        rejected = validate_rejected_candidate(
            {
                "project": "rejected-project",
                "filename": "rejected_project-1.0-py3-none-any.whl",
                "reason": "Simple JSON wheel 'rejected_project-1.0-py3-none-any.whl' has invalid Requires-Python",
            },
            "self-test rejected candidate",
        )
        if stable_rejected_candidate_identity(rejected)["project"] != "rejected-project":
            raise AssertionError("Rejected candidate evidence was not normalized")
        expect_closure_error(
            lambda: validate_rejected_candidate(
                {
                    "project": "rejected-project",
                    "filename": "other_project-1.0-py3-none-any.whl",
                    "reason": "mismatched project",
                },
                "self-test invalid rejected candidate",
            ),
            "rejected candidate project/filename mismatch",
        )
        unlisted_candidate = root / "candidate-pool" / "unlisted.whl"
        unlisted_candidate.write_bytes(b"unlisted candidate evidence")
        expect_closure_error(
            lambda: verify_evidence(
                root / "candidate-pool",
                root / "selected",
                root / "selection.json",
                inventory_path,
                result_path,
            ),
            "unlisted candidate pool file",
        )
        unlisted_candidate.unlink()
        unlisted_selected = root / "selected" / "unlisted.whl"
        unlisted_selected.write_bytes(b"unlisted selected evidence")
        expect_closure_error(
            lambda: verify_evidence(
                root / "candidate-pool",
                root / "selected",
                root / "selection.json",
                inventory_path,
                result_path,
            ),
            "unlisted selected wheelhouse file",
        )
        unlisted_selected.unlink()
        selected = {(item["normalizedName"], item["version"]) for item in selection["entries"]}
        if (
            rounds < 2
            or ("a", "1.0") not in selected
            or ("a", "2.0") in selected
            or ("rcpkg", "2.0rc1") not in selected
            or ("range-rc", "2.0rc2") not in selected
            or ("foo-dep", "1.0") not in selected
            or ("inactive-dep", "1.0") not in selected
        ):
            raise AssertionError(f"Offline pip did not backtrack to the valid A 1.0 closure: {sorted(selected)}")

        expect_closure_error(
            lambda: validate_https_url("https://pypi.org:444/simple/demo/", ("pypi.org",)),
            "non-default HTTPS port",
        )
        expect_closure_error(
            lambda: validate_https_url("https://pypi.org/simple/demo/?redirect=1", ("pypi.org",)),
            "query-bearing Simple URL",
        )
        redirect_handler = ValidatedRedirectHandler(("pypi.org",))
        expect_closure_error(
            lambda: redirect_handler.redirect_request(
                urllib.request.Request("https://pypi.org/simple/demo/"),
                None,
                302,
                "Found",
                {},
                "https://example.invalid/simple/demo/",
            ),
            "redirect to an unapproved host",
        )
        production_catalog = PyPISimpleCatalog(APPROVED_INDEX)
        for opener in (production_catalog._simple_opener, production_catalog._artifact_opener):
            proxy_handlers = [
                handler for handler in opener.handlers if isinstance(handler, urllib.request.ProxyHandler)
            ]
            if any(handler.proxies for handler in proxy_handlers):
                raise AssertionError("Approved-index acquisition must ignore inherited proxy configuration")
        if simple_file_is_yanked({}, "missing.whl") or simple_file_is_yanked({"yanked": False}, "false.whl"):
            raise AssertionError("Missing/native-false yanked metadata must remain eligible")
        if not simple_file_is_yanked({"yanked": True}, "true.whl") or not simple_file_is_yanked(
            {"yanked": ""}, "empty-reason.whl"
        ):
            raise AssertionError("Native-true and every string yanked value must be excluded")
        expect_closure_error(
            lambda: simple_file_is_yanked({"yanked": 0}, "integer.whl"),
            "non-boolean/non-string yanked metadata",
        )
        if not requires_python_allows(None, Version("3.11"), "missing.whl") or not requires_python_allows(
            ">=3.10", Version("3.11"), "compatible.whl"
        ):
            raise AssertionError("Valid/missing Requires-Python metadata must remain eligible")
        expect_closure_error(
            lambda: requires_python_allows(False, Version("3.11"), "boolean.whl"),
            "non-string Requires-Python metadata",
        )
        expect_closure_error(
            lambda: requires_python_allows("", Version("3.11"), "empty.whl"),
            "empty Requires-Python metadata",
        )

        compatible_python = make_test_wheel(
            sources,
            "compatible-python",
            "1.0",
            requires_python_fields=(">=0",),
        )
        compatible_descriptor = local_descriptor(compatible_python)
        compatible_metadata = verify_candidate(compatible_python, compatible_descriptor)
        if compatible_metadata.requires_python != ">=0":
            raise AssertionError("Compatible wheel Requires-Python was not preserved")
        whitespace_equivalent_metadata = verify_candidate(
            compatible_python,
            replace(compatible_descriptor, simple_requires_python=">= 0"),
        )
        if whitespace_equivalent_metadata.requires_python != ">=0":
            raise AssertionError("Normalized-equivalent Requires-Python specifiers must agree")
        expect_closure_error(
            lambda: verify_candidate(
                compatible_python,
                replace(compatible_descriptor, simple_requires_python=">=1"),
            ),
            "Simple JSON and METADATA Requires-Python mismatch",
        )
        expect_closure_error(
            lambda: verify_candidate(
                compatible_python,
                replace(compatible_descriptor, simple_requires_python=None),
            ),
            "Simple JSON omitted Requires-Python while METADATA declares it",
        )

        no_python_field = make_test_wheel(sources, "no-python-field", "1.0")
        no_python_descriptor = local_descriptor(no_python_field)
        expect_closure_error(
            lambda: verify_candidate(
                no_python_field,
                replace(no_python_descriptor, simple_requires_python=">=0"),
            ),
            "Simple JSON declares Requires-Python while METADATA omits it",
        )

        incompatible_python = make_test_wheel(
            sources,
            "incompatible-python",
            "1.0",
            requires_python_fields=("<0",),
        )
        incompatible_descriptor = local_descriptor(incompatible_python)
        expect_closure_error(
            lambda: verify_candidate(incompatible_python, incompatible_descriptor),
            "candidate METADATA Requires-Python excludes the current interpreter",
        )
        invalid_python = make_test_wheel(
            sources,
            "invalid-python",
            "1.0",
            requires_python_fields=("not-a-specifier",),
        )
        expect_closure_error(lambda: read_wheel_metadata(invalid_python), "invalid METADATA Requires-Python")
        duplicate_python = make_test_wheel(
            sources,
            "duplicate-python",
            "1.0",
            requires_python_fields=(">=0", ">=0"),
        )
        expect_closure_error(lambda: read_wheel_metadata(duplicate_python), "duplicate METADATA Requires-Python")

        incompatible_root = make_test_wheel(
            sources,
            "incompatible-root",
            "1.0",
            requires_python_fields=("<0",),
        )
        expect_closure_error(
            lambda: LazyPoolResolver(
                LocalCatalog(()),
                incompatible_root,
                file_sha256(incompatible_root),
                root / "incompatible-root-pool",
                root / "incompatible-root-plan.json",
            ),
            "root METADATA Requires-Python excludes the current interpreter",
        )

        direct = make_test_wheel(sources, "unsafe", "1.0", ("dep @ https://example.invalid/dep.whl",))
        expect_closure_error(lambda: read_wheel_metadata(direct), "direct reference")

        mismatch = make_test_wheel(sources, "actual-name", "1.0")
        mismatch_descriptor = Descriptor(
            project="expected-name",
            version=Version("1.0"),
            filename=mismatch.name,
            url=mismatch.as_uri(),
            sha256=file_sha256(mismatch),
            tag_rank=0,
            build=(-1, ""),
            source_path=mismatch,
        )
        expect_closure_error(lambda: verify_candidate(mismatch, mismatch_descriptor), "metadata identity")

        bad_hash_descriptor = Descriptor(
            project="actual-name",
            version=Version("1.0"),
            filename=mismatch.name,
            url=mismatch.as_uri(),
            sha256="0" * 64,
            tag_rank=0,
            build=(-1, ""),
            source_path=mismatch,
        )
        expect_closure_error(lambda: verify_candidate(mismatch, bad_hash_descriptor), "artifact hash")

        unsafe_archive = make_test_wheel(sources, "unsafe-archive", "1.0")
        with zipfile.ZipFile(unsafe_archive, "a", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("package/../escape.py", "")
        expect_closure_error(lambda: read_wheel_metadata(unsafe_archive), "wheel archive path traversal")

        forged = json.loads((root / "selection.json").read_text(encoding="utf-8"))
        forged["install"][0]["download_info"]["url"] = (sources / "outside.whl").resolve().as_uri()
        forged_path = root / "forged-plan.json"
        write_json(forged_path, forged)
        expect_closure_error(
            lambda: validate_and_select_plan(forged_path, resolver, root / "forged-selected"),
            "offline plan path escape",
        )

        tampered_result = json.loads(result_path.read_text(encoding="utf-8"))
        tampered_result["selectedEntries"][0]["sha256"] = "f" * 64
        tampered_result_path = root / "tampered-result.json"
        write_json(tampered_result_path, tampered_result)
        expect_closure_error(
            lambda: verify_evidence(
                root / "candidate-pool",
                root / "selected",
                root / "selection.json",
                inventory_path,
                tampered_result_path,
            ),
            "cross-file selected evidence mismatch",
        )
    print("python-wheel-closure-self-test: passed")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    resolve = subcommands.add_parser("resolve")
    resolve.add_argument("--index-url", required=True)
    resolve.add_argument("--root-wheel", required=True)
    resolve.add_argument("--root-sha256", required=True)
    resolve.add_argument("--candidate-dir", required=True)
    resolve.add_argument("--selected-dir", required=True)
    resolve.add_argument("--plan", required=True)
    resolve.add_argument("--inventory", required=True)
    resolve.add_argument("--result", required=True)
    resolve.set_defaults(handler=resolve_command)
    verify = subcommands.add_parser("verify")
    verify.add_argument("--candidate-dir", required=True)
    verify.add_argument("--selected-dir", required=True)
    verify.add_argument("--plan", required=True)
    verify.add_argument("--inventory", required=True)
    verify.add_argument("--result", required=True)
    verify.set_defaults(handler=verify_command)
    self_test = subcommands.add_parser("self-test")
    self_test.set_defaults(handler=self_test_command)
    return parser


def main() -> int:
    parser = build_parser()
    arguments = parser.parse_args()
    try:
        arguments.handler(arguments)
        return 0
    except ClosureError as error:
        print(f"python wheel closure error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
