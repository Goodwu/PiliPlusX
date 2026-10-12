#!/usr/bin/env python3
"""Verify a CORE-reviewed Linux libmpv input and its eventual app bundle.

Receipts are data. Authorization always comes from the fixed ledger in the
clean, exact App checkout supplied with --app-root.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

TASK = "MK-ROUTING-20261011"
TASK_BRANCH = "routing/MK-ROUTING-20261011"
LEDGER_REL = Path("docs/plans/routing-linux-native-accepted-inputs.json")
SELF_REL = Path("scripts/verify_routing_linux_native.py")
MANIFEST_REL = Path("provenance/manifest.json")
EVIDENCE_DIR_REL = Path("provenance/evidence")
ROOT_MEMBER = "lib/libmpv.so.2"
COMPONENTS = {"FFmpeg", "mpv", "libplacebo", "recipe"}
CONSUMER_SOURCE_PREFIXES = {
    "Goodwu/PiliPlusX": ("lib/", "linux/", ".github/actions/routing-bootstrap/",
                         ".github/workflows/build.yml", ".github/workflows/linux_x64.yml",
                         "pubspec.yaml", "pubspec.lock", ".fvmrc"),
    "Goodwu/media-kit": ("media_kit/lib/", "media_kit_video/lib/",
                         "media_kit_video/linux/", "libs/linux/media_kit_libs_linux/",
                         "libs/universal/media_kit_libs_video/", "media_kit/pubspec.yaml",
                         "media_kit_video/pubspec.yaml"),
}
CONSUMER_SOURCE_FILES = {
    "Goodwu/PiliPlusX": frozenset({
        "scripts/acquire_routing_linux_native.py", "scripts/verify_routing_linux_native.py",
        "scripts/verify_routing_sources.py", "scripts/prepare_routing_ci.py",
        "scripts/verify_media_kit_lock.py", "scripts/verify_workflow_media_kit_refs.py",
        "scripts/verify_binary_arch.py", "scripts/release_manifest.py",
        "scripts/verify_release_manifest.py",
        "scripts/shared_gate_execution.py", "scripts/prepare_ohos_package_patches.py",
    }),
    "Goodwu/media-kit": frozenset(),
}
CONSUMER_REPOSITORIES = {"Goodwu/PiliPlusX", "Goodwu/media-kit"}
REQUIRED_CONSUMER_PATHS = {
    "Goodwu/PiliPlusX": {
        "scripts/acquire_routing_linux_native.py", "scripts/verify_routing_linux_native.py",
        "scripts/verify_routing_sources.py", "scripts/prepare_routing_ci.py",
        ".github/actions/routing-bootstrap/action.yml", ".github/workflows/build.yml",
        ".github/workflows/linux_x64.yml", "pubspec.yaml", "pubspec.lock", ".fvmrc",
        "lib/plugin/pl_player/controller.dart", "lib/plugin/pl_player/route_options.dart",
        "scripts/acquire_routing_linux_native.py", "scripts/verify_routing_linux_native.py",
        "scripts/verify_routing_sources.py", "scripts/prepare_routing_ci.py",
        "scripts/verify_media_kit_lock.py", "scripts/verify_workflow_media_kit_refs.py",
        "scripts/verify_binary_arch.py", "scripts/release_manifest.py",
        "scripts/verify_release_manifest.py",
        "scripts/shared_gate_execution.py", "scripts/prepare_ohos_package_patches.py",
        "linux/CMakeLists.txt", "linux/flutter/CMakeLists.txt",
        "linux/runner/CMakeLists.txt", "linux/runner/main.cc",
        "linux/runner/my_application.cc", "linux/runner/my_application.h",
    },
    "Goodwu/media-kit": {
        "media_kit/pubspec.yaml", "media_kit/lib/media_kit.dart", "media_kit_video/pubspec.yaml",
        "media_kit_video/lib/media_kit_video.dart",
        "media_kit_video/linux/CMakeLists.txt", "media_kit_video/linux/verify_routing_linux_native_local.py",
        "libs/linux/media_kit_libs_linux/linux/CMakeLists.txt",
        "libs/universal/media_kit_libs_video/pubspec.yaml",
    },
}
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
SAFE_CMAKE_PATH = re.compile(r"[A-Za-z0-9_./+-]+\Z")
MAX_ZIP = 1024 * 1024 * 1024
MAX_FILE = 256 * 1024 * 1024


class GateError(ValueError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("utf-8")


def exact(value: object, fields: set[str], where: str) -> dict:
    if not isinstance(value, dict) or set(value) != fields:
        raise GateError(f"{where}: expected exactly {sorted(fields)}")
    return value


def nonempty(value: object, where: str) -> str:
    if not isinstance(value, str) or value != value.strip() or not value:
        raise GateError(f"{where}: nonempty trimmed string required")
    if any(ord(char) < 32 for char in value):
        raise GateError(f"{where}: control characters are forbidden")
    return value


def sha(value: object, where: str, length: int = 64) -> str:
    pattern = HEX40 if length == 40 else HEX64
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise GateError(f"{where}: lowercase SHA-{length} required")
    return value


def relative(value: object, where: str) -> str:
    value = nonempty(value, where)
    path = PurePosixPath(value)
    if ("\\" in value or value.startswith("/") or ":" in value or
            any(part in ("", ".", "..") for part in value.split("/")) or
            str(path) != value):
        raise GateError(f"{where}: unsafe relative path")
    return value


def json_bytes(raw: bytes, where: str) -> dict:
    if len(raw) > 4 * 1024 * 1024:
        raise GateError(f"{where}: JSON exceeds size limit")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise GateError(f"{where}: duplicate JSON field {key}")
            result[key] = value
        return result

    try:
        value = json.loads(raw, object_pairs_hook=unique)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"{where}: invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise GateError(f"{where}: JSON object required")
    return value


def read_json(path: Path, where: str = "JSON input") -> tuple[dict, bytes]:
    if path.is_symlink() or not path.is_file():
        raise GateError(f"{where}: missing regular file or symbolic link")
    raw = path.read_bytes()
    return json_bytes(raw, where), raw


def artifact_spec(value: object, where: str) -> dict:
    value = exact(value, {"repository", "runId", "attempt", "headSha",
                          "artifactId", "name", "zipSha256", "uploadJobId"}, where)
    if not re.fullmatch(r"Goodwu/[A-Za-z0-9_.-]+", nonempty(value["repository"], where)):
        raise GateError(f"{where}: Goodwu repository required")
    for field in ("runId", "attempt", "artifactId", "uploadJobId"):
        if type(value[field]) is not int or value[field] <= 0:
            raise GateError(f"{where}.{field}: positive integer required")
    sha(value["headSha"], f"{where}.headSha", 40)
    sha(value["zipSha256"], f"{where}.zipSha256")
    if "/" in nonempty(value["name"], f"{where}.name") or "\\" in value["name"]:
        raise GateError(f"{where}.name: basename required")
    return value


def validate_ledger(value: object) -> tuple[dict, dict | None]:
    value = exact(value, {"schemaVersion", "task", "selectedManifestSha256", "entries"}, "Linux accepted ledger")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 or value["task"] != TASK:
        raise GateError("Linux accepted ledger schema/task mismatch")
    if not isinstance(value["entries"], list):
        raise GateError("Linux accepted ledger entries must be an array")
    selected = value["selectedManifestSha256"]
    if selected is not None:
        sha(selected, "selected manifest hash")
    seen = set()
    selected_entry = None
    for entry in value["entries"]:
        exact(entry, {"manifestSha256", "sourceClosureSha256", "consumerSourceClosure", "payloadSha256",
                      "producer", "evidenceArtifact", "approval"}, "Linux acceptance record")
        manifest_hash = sha(entry["manifestSha256"], "manifest hash")
        if manifest_hash in seen:
            raise GateError("duplicate accepted manifest")
        seen.add(manifest_hash)
        sha(entry["sourceClosureSha256"], "source closure hash")
        validate_consumer_closure_record(entry["consumerSourceClosure"])
        sha(entry["payloadSha256"], "payload ZIP hash")
        producer = artifact_spec(entry["producer"], "producer artifact")
        evidence = artifact_spec(entry["evidenceArtifact"], "evidence artifact")
        if (producer["repository"], producer["runId"], producer["attempt"], producer["headSha"]) != (
                evidence["repository"], evidence["runId"], evidence["attempt"], evidence["headSha"]):
            raise GateError("payload/evidence artifacts must share producer run, attempt, repository, and HEAD")
        if producer["artifactId"] == evidence["artifactId"]:
            raise GateError("payload and evidence artifact IDs must be distinct")
        approval = exact(entry["approval"], {"reviewUrl", "coreCommit"}, "approval")
        url = nonempty(approval["reviewUrl"], "approval review URL")
        if not re.fullmatch(r"https://github\.com/Goodwu/media-kit/pull/4(?:#(?:discussion_r\d+|issuecomment-\d+))?", url):
            raise GateError("approval must identify a concrete media-kit PR #4 review/comment")
        sha(approval["coreCommit"], "approval core commit", 40)
        if selected == manifest_hash:
            if selected_entry is not None:
                raise GateError("selected manifest is ambiguous")
            selected_entry = entry
    if selected is None:
        if value["entries"]:
            raise GateError("accepted entries require an explicit selected manifest")
        return value, None
    if selected_entry is None:
        raise GateError("selected manifest has no unique CORE acceptance record")
    return value, selected_entry


def consumer_path_allowed(repository: str, path: str) -> bool:
    if repository not in CONSUMER_SOURCE_PREFIXES:
        return False
    if path == "docs/plans/routing-linux-native-accepted-inputs.json":
        return False
    if repository == "Goodwu/media-kit" and path.startswith("media_kit_video/linux/"):
        parts = PurePosixPath(path).parts
        if any(part in {"test", "tests", "__pycache__"} for part in parts):
            return False
        basename = PurePosixPath(path).name
        if basename.startswith("test_") or basename.endswith(("_test.py", "_test.cc", "_test.cpp", "_test.h")):
            return False
    return (path in CONSUMER_SOURCE_FILES[repository] or
            any(path == prefix.rstrip("/") or path.startswith(prefix)
                for prefix in CONSUMER_SOURCE_PREFIXES[repository]))


def validate_consumer_closure_record(value: object) -> dict:
    value = exact(value, {"schemaVersion", "sha256", "files"}, "consumer source closure")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise GateError("unsupported consumer source closure schema")
    sha(value["sha256"], "consumer source closure hash")
    if not isinstance(value["files"], list) or not value["files"]:
        raise GateError("consumer source closure files must be nonempty")
    seen = set()
    prior = None
    for item in value["files"]:
        item = exact(item, {"repository", "path", "sha256"}, "consumer source file")
        repository = nonempty(item["repository"], "consumer source repository")
        path = relative(item["path"], "consumer source path")
        sha(item["sha256"], "consumer source blob hash")
        if repository not in CONSUMER_REPOSITORIES or not consumer_path_allowed(repository, path):
            raise GateError(f"consumer source path is outside fixed closure policy: {repository}:{path}")
        key = (repository, path)
        if key in seen or (prior is not None and key <= prior):
            raise GateError("consumer source closure must be unique and sorted")
        seen.add(key)
        prior = key
    expected_hash = digest(canonical(value["files"]))
    if value["sha256"] != expected_hash:
        raise GateError("consumer source closure hash does not match canonical files")
    return value


def closure_hash(manifest: dict) -> str:
    fields = ("components", "toolchain", "staging", "linkInputs", "evidence",
              "members", "headers", "dependencyClosure", "systemContracts")
    return digest(canonical({field: manifest[field] for field in fields}))


def validate_manifest(value: object) -> dict:
    fields = {"schemaVersion", "task", "platform", "artifact", "components",
              "toolchain", "staging", "linkInputs", "evidence", "members",
              "headers", "dependencyClosure", "systemContracts"}
    value = exact(value, fields, "Linux manifest")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 or value["task"] != TASK or value["platform"] != "linux-x86_64":
        raise GateError("unsupported Linux manifest schema/task/platform")
    artifact = exact(value["artifact"], {"kind", "name", "sha256", "identity"}, "payload artifact")
    if artifact["kind"] != "zip" or "/" in nonempty(artifact["name"], "payload artifact name") or not artifact["name"].endswith(".zip"):
        raise GateError("payload artifact must identify a ZIP basename")
    sha(artifact["sha256"], "payload ZIP hash")
    identity = exact(artifact["identity"], {"repository", "runId", "attempt", "artifactId"}, "payload identity")
    if not re.fullmatch(r"Goodwu/[A-Za-z0-9_.-]+", nonempty(identity["repository"], "payload repository")):
        raise GateError("payload identity must name a Goodwu repository")
    for field in ("runId", "attempt", "artifactId"):
        if type(identity[field]) is not int or identity[field] <= 0:
            raise GateError(f"payload identity {field}: positive integer required")

    components = exact(value["components"], COMPONENTS, "components")
    evidence_refs: list[tuple[str, str]] = []
    for name, component in components.items():
        component = exact(component, {"repository", "commit", "tree", "patches", "sourceEvidence"}, name)
        if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?", nonempty(component["repository"], f"{name}.repository")):
            raise GateError(f"{name}: explicit source repository URL required")
        sha(component["commit"], f"{name}.commit", 40)
        sha(component["tree"], f"{name}.tree", 40)
        evidence_refs.append((nonempty(component["sourceEvidence"], f"{name}.sourceEvidence"), "source"))
        if not isinstance(component["patches"], list):
            raise GateError(f"{name}: ordered patches list required")
        patch_paths = set()
        for patch in component["patches"]:
            patch = exact(patch, {"path", "sha256", "evidence"}, f"{name} patch")
            path = relative(patch["path"], "patch path")
            if path in patch_paths:
                raise GateError("duplicate patch path")
            patch_paths.add(path)
            sha(patch["sha256"], "patch hash")
            evidence_refs.append((nonempty(patch["evidence"], "patch evidence"), "patch"))

    toolchain = exact(value["toolchain"], {"name", "version", "sha256", "sysrootSha256", "evidence"}, "toolchain")
    for key in ("name", "version"):
        nonempty(toolchain[key], f"toolchain.{key}")
    for key in ("sha256", "sysrootSha256"):
        sha(toolchain[key], f"toolchain.{key}")
    evidence_refs.append((nonempty(toolchain["evidence"], "toolchain evidence"), "toolchain"))

    staging = exact(value["staging"], {"cleanEvidence", "membersEvidence", "linkEvidence"}, "staging")
    for key, kind in (("cleanEvidence", "staging"), ("membersEvidence", "members"), ("linkEvidence", "link")):
        evidence_refs.append((nonempty(staging[key], f"staging.{key}"), kind))

    if not isinstance(value["linkInputs"], list) or not value["linkInputs"]:
        raise GateError("ordered linkInputs must be nonempty")
    linked_components = set()
    link_pairs = set()
    for item in value["linkInputs"]:
        item = exact(item, {"component", "path", "sha256"}, "link input")
        component = nonempty(item["component"], "link input component")
        if component not in COMPONENTS | {"toolchain", "dependency"}:
            raise GateError("unknown native link input component")
        key = (component, relative(item["path"], "link input path"))
        if key in link_pairs:
            raise GateError("duplicate link input")
        link_pairs.add(key)
        linked_components.add(component)
        sha(item["sha256"], "link input hash")
    if not COMPONENTS <= linked_components or "toolchain" not in linked_components:
        raise GateError("link inputs must cover FFmpeg, mpv, libplacebo, recipe, and toolchain")

    if not isinstance(value["evidence"], list) or not value["evidence"]:
        raise GateError("source/link/staging evidence must be nonempty")
    evidence = {}
    evidence_paths = set()
    allowed_kinds = {"source", "patch", "toolchain", "staging", "members", "link", "dependency-contract"}
    for item in value["evidence"]:
        item = exact(item, {"id", "path", "sha256", "kind"}, "evidence")
        identifier = nonempty(item["id"], "evidence id")
        path = relative(item["path"], "evidence path")
        if identifier in evidence or path in evidence_paths:
            raise GateError("duplicate evidence ID/path")
        if item["kind"] not in allowed_kinds:
            raise GateError("unknown evidence kind")
        sha(item["sha256"], "evidence hash")
        evidence[identifier] = item
        evidence_paths.add(path)
    for identifier, kind in evidence_refs:
        if identifier not in evidence or evidence[identifier]["kind"] != kind:
            raise GateError(f"missing {kind} evidence: {identifier}")

    members = value["members"]
    if not isinstance(members, dict) or ROOT_MEMBER not in members or len(members) > 256:
        raise GateError("members must include lib/libmpv.so.2 and remain bounded")
    sonames = set()
    for path, member in members.items():
        path = relative(path, "DSO member path")
        if path != ROOT_MEMBER and not path.startswith("lib/deps/"):
            raise GateError("bundled DSOs must be lib/libmpv.so.2 or lib/deps/<name>")
        member = exact(member, {"sha256", "buildId", "soname", "elfClass", "machine", "type", "needed", "rpath", "runpath", "versionNeeds"}, f"member {path}")
        sha(member["sha256"], f"{path} hash")
        build_id = nonempty(member["buildId"], f"{path} Build ID")
        if not re.fullmatch(r"[0-9a-fA-F]{8,128}", build_id):
            raise GateError(f"{path}: malformed ELF Build ID")
        soname = nonempty(member["soname"], f"{path} SONAME")
        if "/" in soname or soname in sonames:
            raise GateError("DSO SONAMEs must be unique basenames")
        if PurePosixPath(path).name != soname:
            raise GateError(f"{path}: payload basename must equal ELF SONAME")
        sonames.add(soname)
        if type(member["elfClass"]) is not int or member["elfClass"] != 64 or type(member["machine"]) is not int or member["machine"] != 62 or member["type"] != "DYN":
            raise GateError(f"{path}: manifest must describe x86_64 ELF64 ET_DYN")
        if not isinstance(member["needed"], list) or len(member["needed"]) != len(set(member["needed"])):
            raise GateError(f"{path}: unique ordered NEEDED list required")
        for needed in member["needed"]:
            if not isinstance(needed, str) or not needed or "/" in needed or "\\" in needed:
                raise GateError(f"{path}: NEEDED values must be basenames")
        for field in ("rpath", "runpath"):
            if not isinstance(member[field], list):
                raise GateError(f"{path}: {field} must be an array")
            for entry in member[field]:
                validate_origin_path(entry, f"{path} {field}")
                if entry != "$ORIGIN":
                    raise GateError(f"{path}: bundled DSO search paths must survive flat bundle copying")
        if not isinstance(member["versionNeeds"], list):
            raise GateError(f"{path}: versionNeeds must be an array")
        seen_version_libraries = set()
        for need in member["versionNeeds"]:
            need = exact(need, {"library", "versions"}, f"{path} version need")
            library = nonempty(need["library"], "version need library")
            if library not in member["needed"] or library in seen_version_libraries:
                raise GateError(f"{path}: version need must uniquely reference a NEEDED library")
            seen_version_libraries.add(library)
            if not isinstance(need["versions"], list) or any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", v) for v in need["versions"]):
                raise GateError(f"{path}: invalid version need names")
            if len(need["versions"]) != len(set(need["versions"])):
                raise GateError(f"{path}: duplicate version need")
    if members[ROOT_MEMBER]["soname"] != "libmpv.so.2":
        raise GateError("root DSO SONAME must be libmpv.so.2")

    headers = value["headers"]
    if not isinstance(headers, dict) or not headers:
        raise GateError("complete libmpv headers inventory required")
    for path, checksum in headers.items():
        path = relative(path, "header path")
        if not path.startswith("include/mpv/") or not path.endswith((".h", ".hpp")):
            raise GateError("header inventory must contain only include/mpv headers")
        sha(checksum, f"header hash {path}")

    contracts = value["systemContracts"]
    if not isinstance(contracts, list):
        raise GateError("systemContracts must be an array")
    contract_ids = set()
    contracts_by_soname = {}
    for contract in contracts:
        contract = exact(contract, {"id", "evidence", "abi", "minimumBaseline", "sonames"}, "system contract")
        identifier = nonempty(contract["id"], "system contract id")
        if identifier in contract_ids:
            raise GateError("duplicate system contract ID")
        contract_ids.add(identifier)
        evidence_id = nonempty(contract["evidence"], "system contract evidence")
        if evidence_id not in evidence or evidence[evidence_id]["kind"] != "dependency-contract":
            raise GateError("system dependency contract must reference reviewed dependency-contract evidence")
        nonempty(contract["abi"], "system contract ABI")
        nonempty(contract["minimumBaseline"], "system contract minimum baseline")
        if not isinstance(contract["sonames"], list):
            raise GateError("system contract sonames must be a list")
        for item in contract["sonames"]:
            item = exact(item, {"name", "versions"}, "system SONAME contract")
            name = nonempty(item["name"], "system SONAME")
            if "/" in name or name in contracts_by_soname:
                raise GateError("system SONAME contract must be unique basename")
            versions = item["versions"]
            if not isinstance(versions, list) or any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", v) for v in versions) or len(versions) != len(set(versions)):
                raise GateError("system contract versions must be a unique allowlist")
            contracts_by_soname[name] = (identifier, set(versions))

    closure = value["dependencyClosure"]
    if not isinstance(closure, list):
        raise GateError("explicit DSO dependency closure required")
    resolutions = {}
    for item in closure:
        if not isinstance(item, dict):
            raise GateError("dependency closure entry must be an object")
        kind = item.get("kind")
        fields = {"requester", "needed", "kind", "member", "sha256"} if kind == "bundled" else {"requester", "needed", "kind", "contract"} if kind == "system" else set()
        item = exact(item, fields, "dependency closure entry")
        requester = relative(item["requester"], "dependency requester")
        needed = nonempty(item["needed"], "dependency needed")
        if requester not in members or needed not in members[requester]["needed"]:
            raise GateError("dependency closure references undeclared requester/NEEDED")
        key = (requester, needed)
        if key in resolutions:
            raise GateError("duplicate dependency closure resolution")
        if kind == "bundled":
            target = relative(item["member"], "bundled dependency path")
            sha(item["sha256"], "bundled dependency hash")
            if target not in members or members[target]["soname"] != needed or members[target]["sha256"] != item["sha256"]:
                raise GateError("bundled dependency does not match declared payload DSO/hash/SONAME")
            resolutions[key] = (kind, target)
        else:
            identifier = nonempty(item["contract"], "dependency contract")
            if identifier not in contract_ids or needed not in contracts_by_soname or contracts_by_soname[needed][0] != identifier:
                raise GateError("system dependency is not covered by its exact SONAME contract")
            resolutions[key] = (kind, identifier)
    expected_resolutions = {(path, needed) for path, member in members.items() for needed in member["needed"]}
    if set(resolutions) != expected_resolutions:
        raise GateError("dependency closure is missing or adds a NEEDED resolution")
    bundled_paths = {path for kind, path in resolutions.values() if kind == "bundled"}
    if set(members) != {ROOT_MEMBER} | bundled_paths:
        raise GateError("payload contains an unreferenced or missing bundled DSO")
    referenced_contracts = {target for kind, target in resolutions.values() if kind == "system"}
    if referenced_contracts != contract_ids:
        raise GateError("system dependency contracts must be used exactly by the declared closure")
    for identifier in contract_ids:
        declared_sonames = {name for name, (contract_id, _) in contracts_by_soname.items() if contract_id == identifier}
        used_sonames = {needed for (requester, needed), (kind, target) in resolutions.items()
                        if kind == "system" and target == identifier}
        if declared_sonames != used_sonames:
            raise GateError("system contract contains unused or missing SONAME entries")
    for path, member in members.items():
        actual_versions = {item["library"]: set(item["versions"]) for item in member["versionNeeds"]}
        for needed in member["needed"]:
            kind, target = resolutions[(path, needed)]
            if kind == "system":
                allowed_versions = contracts_by_soname[needed][1]
                if not actual_versions.get(needed, set()) <= allowed_versions:
                    raise GateError(f"{path}: system version requirements exceed approved contract for {needed}")
    return value


def validate_origin_path(value: object, where: str) -> str:
    value = nonempty(value, where)
    if (value.startswith("/") or "\\" in value or "$ORIGIN" not in value or
            any(token in value for token in ("${", "$LIB", "$PLATFORM")) or
            value.count("$ORIGIN") != 1 or ";" in value):
        raise GateError(f"{where}: only bounded ORIGIN-relative paths are allowed")
    suffix = value.replace("$ORIGIN", "", 1)
    normalized = PurePosixPath("/" + suffix.lstrip("/"))
    if any(part == ".." for part in suffix.split("/")) or str(normalized).startswith("/../"):
        raise GateError(f"{where}: RPATH escapes the bundle")
    return value


def selected_entry(ledger: dict) -> dict:
    _, entry = validate_ledger(ledger)
    if entry is None:
        raise GateError("missing-accepted-linux-native-input")
    return entry


def trusted_checkout(root: Path, expected_role: str, receipt: dict) -> tuple[str, str]:
    if root.is_symlink():
        raise GateError(f"{expected_role} root must not be a symbolic link")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise GateError(f"{expected_role} root must be a real directory")
    def git(*args):
        command = ["git", "-C", str(root), *args]
        try:
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, check=False, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GateError(f"{expected_role} Git inspection failed: {error}") from error
        receipt.setdefault("commands", []).append({"argv": command, "exitCode": result.returncode,
                                                     "stdout": result.stdout[:65536], "stderr": result.stderr[:65536]})
        if result.returncode != 0 or result.stderr.strip():
            raise GateError(f"{expected_role} Git inspection failed")
        return result.stdout.strip()
    top = Path(git("rev-parse", "--show-toplevel")).resolve(strict=True)
    if top != root:
        raise GateError(f"{expected_role} root is not a repository root")
    if git("rev-parse", "--abbrev-ref", "HEAD") != TASK_BRANCH:
        raise GateError(f"{expected_role} checkout is not on the task branch")
    remote_pattern = (re.compile(r"(?:https://github\.com/Goodwu/PiliPlusX(?:\.git)?|git@github\.com:Goodwu/PiliPlusX\.git)")
                      if expected_role == "App" else
                      re.compile(r"(?:https://github\.com/Goodwu/media-kit(?:\.git)?|git@github\.com:Goodwu/media-kit\.git)"))
    remote_names = git("remote").splitlines()
    remote_urls = [git("remote", "get-url", name) for name in remote_names]
    if not any(remote_pattern.fullmatch(url) for url in remote_urls):
        raise GateError(f"{expected_role} checkout lacks the canonical Goodwu remote")
    head = sha(git("rev-parse", "HEAD"), f"{expected_role} HEAD", 40)
    status = git("status", "--porcelain=v1", "--untracked-files=all")
    if status:
        raise GateError(f"{expected_role} source checkout is dirty")
    return str(root), head


def tracked_blob(root: Path, revision: str, relative_path: Path, receipt: dict) -> bytes:
    command = ["git", "-C", str(root), "show", f"{revision}:{relative_path.as_posix()}"]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                check=False, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"tracked source lookup failed: {relative_path}: {error}") from error
    receipt.setdefault("commands", []).append({"argv": command, "exitCode": result.returncode,
                                                 "stdoutSha256": digest(result.stdout),
                                                 "stderr": result.stderr.decode("utf-8", "replace")[:65536]})
    if result.returncode != 0 or result.stderr:
        raise GateError(f"tracked source lookup failed: {relative_path}")
    return result.stdout


def trusted_app(app_root: Path, receipt: dict) -> tuple[Path, str, dict, bytes]:
    app_text, app_head = trusted_checkout(app_root, "App", receipt)
    app = Path(app_text)
    ledger_path = app / LEDGER_REL
    ledger, ledger_raw = read_json(ledger_path, "fixed Linux accepted ledger")
    ledger_blob = tracked_blob(app, app_head, LEDGER_REL, receipt)
    if ledger_raw != ledger_blob:
        raise GateError("fixed Linux ledger differs from exact App Git blob")
    self_path = app / SELF_REL
    self_raw = self_path.read_bytes() if self_path.is_file() and not self_path.is_symlink() else b""
    self_blob = tracked_blob(app, app_head, SELF_REL, receipt)
    if not self_raw or self_raw != self_blob:
        raise GateError("Linux verifier differs from exact App Git blob")
    receipt["verifierSha256"] = digest(self_raw)
    return app, app_head, ledger, ledger_raw


def compute_consumer_source_closure(app_root: Path, media_root: Path) -> dict:
    files = []
    for repository, root in (("Goodwu/PiliPlusX", app_root), ("Goodwu/media-kit", media_root)):
        try:
            result = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    check=False, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GateError(f"{repository} source closure enumeration failed: {error}") from error
        if result.returncode or result.stderr:
            raise GateError(f"{repository} source closure enumeration failed")
        paths = sorted(path.decode("utf-8") for path in result.stdout.split(b"\0") if path)
        matched = [path for path in paths if consumer_path_allowed(repository, path)]
        if not matched:
            raise GateError(f"{repository} source closure matched no fixed production inputs")
        missing_required = REQUIRED_CONSUMER_PATHS[repository] - set(matched)
        if missing_required:
            raise GateError(f"{repository} consumer closure is missing fixed inputs: {sorted(missing_required)}")
        for relative_path in matched:
            path = root / relative_path
            if path.is_symlink() or not path.is_file():
                raise GateError(f"consumer source closure contains a missing/non-regular file: {repository}:{relative_path}")
            files.append({"repository": repository, "path": relative_path,
                          "sha256": file_digest(path)})
    files.sort(key=lambda item: (item["repository"], item["path"]))
    return {"schemaVersion": 1, "sha256": digest(canonical(files)), "files": files}


def require_consumer_source_closure(app_root: Path, media_root: Path, approved: object) -> dict:
    approved = validate_consumer_closure_record(approved)
    current = compute_consumer_source_closure(app_root, media_root)
    if current != approved:
        raise GateError("current App/media-kit consumer source closure differs from CORE-approved closure")
    return current


def evidence_inventory(root: Path, manifest: dict) -> None:
    evidence_root = root / EVIDENCE_DIR_REL
    if evidence_root.is_symlink() or not evidence_root.is_dir():
        raise GateError("manifest evidence directory missing or symbolic link")
    declared = {item["path"]: item["sha256"] for item in manifest["evidence"]}
    actual = {}
    for path in evidence_root.rglob("*"):
        if path.is_symlink():
            raise GateError("evidence tree contains symbolic link")
        if path.is_file():
            rel = path.relative_to(evidence_root).as_posix()
            actual[rel] = file_digest(path)
        elif not path.is_dir():
            raise GateError("evidence tree contains non-regular object")
    if actual != declared:
        raise GateError("evidence tree does not exactly match manifest attachment hashes")


def payload_inventory(root: Path, manifest: dict) -> None:
    expected = set(manifest["members"]) | set(manifest["headers"])
    actual = {}
    for path in (root / "lib", root / "include"):
        if path.is_symlink() or not path.is_dir():
            raise GateError("payload lib/include directories missing or symbolic link")
    for base in (root / "lib", root / "include"):
        for path in base.rglob("*"):
            if path.is_symlink():
                raise GateError("payload contains symbolic link")
            if path.is_file():
                relative_path = path.relative_to(root).as_posix()
                if path.stat().st_size > MAX_FILE:
                    raise GateError("payload member exceeds per-file limit")
                actual[relative_path] = file_digest(path)
            elif not path.is_dir():
                raise GateError("payload contains a non-regular object")
    if set(actual) != expected:
        raise GateError("payload contains missing or undeclared files")
    for name, declaration in manifest["members"].items():
        if actual[name] != declaration["sha256"]:
            raise GateError(f"payload DSO hash mismatch: {name}")
    for name, checksum in manifest["headers"].items():
        if actual[name] != checksum:
            raise GateError(f"payload header hash mismatch: {name}")


def run_tool(argv: list[str], receipt: dict) -> str:
    step = {"argv": argv, "exitCode": None}
    receipt.setdefault("commands", []).append(step)
    try:
        result = subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        step["error"] = str(error)
        raise GateError(f"ELF inspection tool failed to start/finish: {argv[0]}") from error
    step.update(exitCode=result.returncode, stdout=result.stdout[:1024 * 1024],
                stderr=result.stderr[:256 * 1024])
    if result.returncode != 0 or result.stderr.strip():
        raise GateError(f"ELF inspection tool failed or diagnosed input: {argv[0]}")
    return result.stdout


def parse_version_needs(output: str, path: str) -> list[dict]:
    current = None
    requirements: dict[str, list[str]] = {}
    for line in output.splitlines():
        file_match = re.search(r"\bFile:\s+(\S+)", line)
        if file_match:
            current = file_match.group(1)
            requirements.setdefault(current, [])
        names = re.findall(r"\bName:\s+([A-Za-z0-9_.+-]+)", line)
        if names:
            if current is None:
                raise GateError(f"{path}: version name without a library in readelf output")
            requirements[current].extend(names)
    if not requirements:
        if "No version information found" not in output and "Version needs section" not in output and "Version definition section" not in output:
            raise GateError(f"{path}: readelf version-info output was not recognized")
    return [{"library": name, "versions": versions} for name, versions in requirements.items()]


def inspect_elf(path: Path, rel: str, declaration: dict, readelf: str, receipt: dict) -> dict:
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1 or struct.unpack_from("<H", data, 16)[0] != 3 or struct.unpack_from("<H", data, 18)[0] != 62:
        raise GateError(f"{rel}: not little-endian x86_64 ELF64 ET_DYN")
    header = run_tool([readelf, "-h", str(path)], receipt)
    if not all(re.search(pattern, header, re.MULTILINE) for pattern in (
            r"^\s*Class:\s+ELF64\s*$", r"^\s*Data:\s+2's complement, little endian\s*$",
            r"^\s*Type:\s+DYN\s+\(Shared object file\)", r"^\s*Machine:\s+Advanced Micro Devices X86-64\s*$")):
        raise GateError(f"{rel}: readelf header does not confirm x86_64 ELF64 ET_DYN")
    notes = run_tool([readelf, "-n", str(path)], receipt)
    build_ids = re.findall(r"Build ID:\s*([0-9a-fA-F]+)", notes)
    if len(build_ids) != 1 or build_ids[0].lower() != declaration["buildId"].lower():
        raise GateError(f"{rel}: Build ID missing, duplicate, or changed")
    dynamic = run_tool([readelf, "-d", str(path)], receipt)
    sonames = re.findall(r"\(SONAME\).*?\[([^\]]+)\]", dynamic)
    needed = re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic)
    rpaths = re.findall(r"\(RPATH\).*?\[([^\]]*)\]", dynamic)
    runpaths = re.findall(r"\(RUNPATH\).*?\[([^\]]*)\]", dynamic)
    def split_paths(entries):
        if len(entries) > 1:
            raise GateError(f"{rel}: duplicate dynamic search path tags")
        return [] if not entries or not entries[0] else entries[0].split(":")
    actual_rpath, actual_runpath = split_paths(rpaths), split_paths(runpaths)
    for value in actual_rpath + actual_runpath:
        validate_origin_path(value, f"{rel} dynamic search path")
    for paths in (actual_rpath, actual_runpath):
        if len(paths) != len(set(paths)):
            raise GateError(f"{rel}: duplicate runtime search path entry")
    if len(sonames) != 1 or sonames[0] != declaration["soname"] or needed != declaration["needed"]:
        raise GateError(f"{rel}: SONAME/NEEDED differ from reviewed manifest")
    if actual_rpath != declaration["rpath"] or actual_runpath != declaration["runpath"]:
        raise GateError(f"{rel}: RPATH/RUNPATH differs from reviewed manifest")
    version_output = run_tool([readelf, "--version-info", "--wide", str(path)], receipt)
    actual_versions = parse_version_needs(version_output, rel)
    if actual_versions != declaration["versionNeeds"]:
        raise GateError(f"{rel}: ELF symbol-version requirements differ from manifest")
    return {"sha256": digest(data), "buildId": build_ids[0].lower(), "soname": sonames[0],
            "needed": needed, "rpath": actual_rpath, "runpath": actual_runpath,
            "versionNeeds": actual_versions, "elfClass": 64, "machine": 62, "type": "DYN"}


def verify_elfs(root: Path, manifest: dict, readelf: str, receipt: dict) -> dict:
    actual = {}
    for rel, declaration in manifest["members"].items():
        actual[rel] = inspect_elf(root / rel, rel, declaration, readelf, receipt)
    return actual


def manifest_evidence(root: Path, manifest: dict, receipt: dict) -> None:
    evidence_root = root / EVIDENCE_DIR_REL
    evidence_inventory(root, manifest)
    by_id = {item["id"]: item for item in manifest["evidence"]}
    for component in manifest["components"].values():
        for patch in component["patches"]:
            item = by_id[patch["evidence"]]
            path = evidence_root / item["path"]
            if file_digest(path) != patch["sha256"]:
                raise GateError("ordered patch attachment hash mismatch")
    link_hashes = {(item["component"], item["path"]): item["sha256"] for item in manifest["linkInputs"]}
    if not link_hashes:
        raise GateError("link inputs missing")


def expected_entry(ledger: dict, manifest: dict, manifest_raw: bytes) -> dict:
    entry = selected_entry(ledger)
    artifact = manifest["artifact"]
    if (digest(manifest_raw) != entry["manifestSha256"] or
            closure_hash(manifest) != entry["sourceClosureSha256"] or
            artifact["sha256"] != entry["payloadSha256"] or
            artifact["identity"]["repository"] != entry["producer"]["repository"] or
            artifact["identity"]["runId"] != entry["producer"]["runId"] or
            artifact["identity"]["attempt"] != entry["producer"]["attempt"] or
            artifact["identity"]["artifactId"] != entry["producer"]["artifactId"]):
        raise GateError("manifest/source closure/payload identity has no unique CORE acceptance")
    return entry


def verify_local(root: Path, receipt_path: Path, app_root: Path, media_kit_root: Path,
                 readelf: str, receipt: dict, write_cmake: Path | None = None) -> dict:
    prior_commands = receipt.get("commands", [])
    receipt.update(schemaVersion=1, task=TASK, scope="routing-linux-native-input",
                   stage="trusted-source", status="failed", nativeVerified=False,
                   deviceVerified=False, commands=prior_commands)
    if root.is_symlink() or not root.is_dir():
        raise GateError("native root must be a real directory")
    root = root.resolve(strict=True)
    try:
        receipt_path.absolute().relative_to(root.absolute())
    except ValueError:
        pass
    else:
        raise GateError("receipt must remain outside the local native payload root")
    if (root / "provenance").is_symlink() or (root / "lib").is_symlink() or (root / "include").is_symlink():
        raise GateError("native root contains a symbolic payload/provenance directory")
    app, app_head, ledger, _ = trusted_app(app_root, receipt)
    entry = selected_entry(ledger)
    media_text, media_head = trusted_checkout(media_kit_root, "media-kit", receipt)
    if Path(media_text) != media_kit_root.resolve(strict=True):
        raise GateError("media-kit root does not match trusted Git top-level")
    consumer_closure = require_consumer_source_closure(app, Path(media_text),
                                                       entry["consumerSourceClosure"])
    consumer = {"appCommit": app_head, "mediaKitCommit": media_head,
                "sourceClosureSha256": consumer_closure["sha256"]}
    receipt["consumer"] = consumer
    if receipt_path.is_symlink() or not receipt_path.is_file():
        raise GateError("acquisition receipt missing or symbolic link")
    supplied_receipt, receipt_raw = read_json(receipt_path, "acquisition receipt")
    receipt_keys = {"schemaVersion", "task", "scope", "stage", "status", "nativeVerified",
                    "deviceVerified", "consumer", "native", "verifierSha256", "files", "commands"}
    supplied_receipt = exact(supplied_receipt, receipt_keys, "acquisition receipt")
    if (supplied_receipt["schemaVersion"] != 1 or supplied_receipt["task"] != TASK or
            supplied_receipt["scope"] != "routing-linux-native-input" or
            supplied_receipt["status"] not in ("acquired", "passed") or
            type(supplied_receipt["nativeVerified"]) is not bool or
            supplied_receipt["nativeVerified"] != (supplied_receipt["status"] == "passed") or
            supplied_receipt["deviceVerified"] is not False or supplied_receipt["consumer"] != consumer):
        raise GateError("receipt scope/status/native claim/consumer does not match trusted current sources")
    expected_stage = "acquired" if supplied_receipt["status"] == "acquired" else "verified-input"
    if supplied_receipt["stage"] != expected_stage:
        raise GateError("receipt stage does not correspond to its status")
    if not isinstance(supplied_receipt["commands"], list) or len(supplied_receipt["commands"]) > 1000:
        raise GateError("receipt command history is malformed or oversized")
    expected_files_shape = {"members": {}, "headers": {}}
    if supplied_receipt["status"] == "acquired" and supplied_receipt["files"] != expected_files_shape:
        raise GateError("acquired receipt must not claim verified payload members")
    if supplied_receipt["verifierSha256"] != digest((app / SELF_REL).read_bytes()):
        raise GateError("receipt verifier hash differs from trusted current helper")
    native = exact(supplied_receipt["native"], {"manifestSha256", "sourceClosureSha256", "payloadSha256",
                     "producer", "evidenceArtifact"}, "receipt native identity")
    for label in ("producer", "evidenceArtifact"):
        artifact_spec(native[label], f"receipt {label}")
    manifest_path = root / MANIFEST_REL
    manifest, manifest_raw = read_json(manifest_path, "local manifest")
    manifest = validate_manifest(manifest)
    declared_root_files = {"payload.zip", "provenance/manifest.json"}
    declared_root_files |= {f"provenance/evidence/{item['path']}" for item in manifest["evidence"]}
    declared_root_files |= set(manifest["members"]) | set(manifest["headers"])
    actual_root_files = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise GateError("native input root contains symbolic link")
        if path.is_file():
            actual_root_files.add(path.relative_to(root).as_posix())
        elif not path.is_dir():
            raise GateError("native input root contains non-regular filesystem object")
    if actual_root_files != declared_root_files:
        raise GateError("native input root contains missing or undeclared files (including embedded authorization data)")
    expected_dirs = {"lib", "include", "provenance", "provenance/evidence"}
    for file_name in declared_root_files:
        parent = PurePosixPath(file_name).parent
        while str(parent) != ".":
            expected_dirs.add(str(parent))
            parent = parent.parent
    actual_dirs = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_dir()}
    if actual_dirs != expected_dirs:
        raise GateError("native input root contains unexpected empty directories")
    accepted = expected_entry(ledger, manifest, manifest_raw)
    if native != {"manifestSha256": accepted["manifestSha256"],
                  "sourceClosureSha256": accepted["sourceClosureSha256"],
                  "payloadSha256": accepted["payloadSha256"],
                  "producer": accepted["producer"], "evidenceArtifact": accepted["evidenceArtifact"]}:
        raise GateError("receipt data is not identical to fixed CORE-approved ledger")
    if (root / "payload.zip").is_symlink() or not (root / "payload.zip").is_file() or file_digest(root / "payload.zip") != accepted["payloadSha256"]:
        raise GateError("local payload ZIP differs from CORE-reviewed digest")
    payload_inventory(root, manifest)
    manifest_evidence(root, manifest, receipt)
    actual_elf = verify_elfs(root, manifest, readelf, receipt)
    actual_files = {"members": actual_elf, "headers": manifest["headers"]}
    if supplied_receipt["status"] == "passed" and supplied_receipt["files"] != actual_files:
        raise GateError("previous verified receipt member hashes differ from current payload")
    receipt.update(stage="verified-input", status="passed", nativeVerified=True,
                   deviceVerified=False, consumer=consumer, native=native,
                   files=actual_files, verifierSha256=digest((app / SELF_REL).read_bytes()))
    if write_cmake is not None:
        write_cmake_data(root, manifest, write_cmake)
    return manifest


def write_cmake_data(root: Path, manifest: dict, output: Path) -> None:
    paths = [root / ROOT_MEMBER, root / "include"] + [root / name for name in sorted(manifest["members"]) if name != ROOT_MEMBER]
    lines = ["schema=1", f"libmpv={paths[0]}", f"include={paths[1]}"]
    lines.extend(f"bundle={root / name}" for name in sorted(manifest["members"]))
    for value in lines:
        if "=" not in value or any(char in value for char in "\r\n;$|%{}\\\"'") or not SAFE_CMAKE_PATH.fullmatch(value.split("=", 1)[1]):
            raise GateError("verified CMake data contains unsafe path characters")
    data = "\n".join(lines) + "\n"
    if output == Path("-"):
        sys.stdout.write(data)
    else:
        if output.is_symlink():
            raise GateError("CMake data output must not be a symbolic link")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(data, encoding="ascii")


def parse_cmake_data(path: Path) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise GateError("CMake data missing, symbolic link, or too large")
    result = {"schema": None, "libmpv": None, "include": None, "bundle": []}
    for line in path.read_text(encoding="ascii").splitlines():
        if any(char in line for char in "\r\n;$|%{}\\\"'") or "=" not in line:
            raise GateError("unsafe CMake data line")
        key, value = line.split("=", 1)
        if not SAFE_CMAKE_PATH.fullmatch(value):
            raise GateError("unsafe CMake path value")
        if key == "schema" and result["schema"] is None:
            result["schema"] = value
        elif key == "libmpv" and result["libmpv"] is None:
            result["libmpv"] = value
        elif key == "include" and result["include"] is None:
            result["include"] = value
        elif key == "bundle":
            result["bundle"].append(value)
        else:
            raise GateError("unknown or duplicate CMake data field")
    if result["schema"] != "1" or not result["libmpv"] or not result["include"] or not result["bundle"]:
        raise GateError("incomplete CMake data")
    return result


def safe_extract_zip(archive_path: Path, destination: Path, expected_files: set[str]) -> set[str]:
    destination.mkdir(mode=0o700, exist_ok=True)
    names = set()
    total = 0
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        if not entries or len(entries) > 100000:
            raise GateError("artifact ZIP empty or too many members")
        for item in entries:
            name = item.filename
            if item.orig_filename != name or item.is_dir() or item.flag_bits & 1 or stat.S_ISLNK(item.external_attr >> 16):
                raise GateError("artifact ZIP directory/symlink/encryption/ambiguous name forbidden")
            name = relative(name, "artifact ZIP member")
            if name in names:
                raise GateError("duplicate artifact ZIP member")
            names.add(name)
            if name not in expected_files:
                raise GateError("artifact ZIP contains undeclared member")
            if item.file_size > MAX_FILE or item.file_size > max(1, item.compress_size) * 250:
                raise GateError("artifact ZIP member expansion limit")
            total += item.file_size
            if total > MAX_ZIP:
                raise GateError("artifact ZIP expansion limit")
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(item) as source, target.open("xb") as sink:
                size = 0
                while chunk := source.read(1024 * 1024):
                    size += len(chunk)
                    if size > item.file_size or size > MAX_FILE:
                        raise GateError("artifact actual expansion exceeds limit")
                    sink.write(chunk)
                if size != item.file_size:
                    raise GateError("artifact ZIP member size mismatch")
    if names != expected_files:
        raise GateError("artifact ZIP missing required members")
    return names


def verify_plugin(plugin: Path, root: Path, receipt_path: Path, app_root: Path,
                  media_kit_root: Path, readelf: str, receipt: dict) -> None:
    manifest = verify_local(root, receipt_path, app_root, media_kit_root, readelf, receipt)
    if plugin.is_symlink() or not plugin.is_file():
        raise GateError("linked plugin output missing or symbolic link")
    plugin_path = plugin.resolve(strict=True)
    inspected = run_tool([readelf, "-h", str(plugin_path)], receipt)
    if not all(re.search(pattern, inspected, re.MULTILINE) for pattern in (
            r"^\s*Class:\s+ELF64\s*$", r"^\s*Data:\s+2's complement, little endian\s*$",
            r"^\s*Type:\s+DYN\s+\(Shared object file\)", r"^\s*Machine:\s+Advanced Micro Devices X86-64\s*$")):
        raise GateError("linked plugin is not x86_64 ELF64 ET_DYN")
    dynamic = run_tool([readelf, "-d", str(plugin_path)], receipt)
    needed = re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic)
    tags = re.findall(r"\(RUNPATH\).*?\[([^\]]*)\]", dynamic)
    old_tags = re.findall(r"\(RPATH\).*?\[([^\]]*)\]", dynamic)
    if needed.count("libmpv.so.2") != 1:
        raise GateError("linked plugin does not record libmpv.so.2 as an actual NEEDED input")
    if len(tags) + len(old_tags) != 1:
        raise GateError("linked plugin must have one explicit RUNPATH/RPATH")
    raw_paths = (tags or old_tags)[0]
    runpaths = raw_paths.split(":")
    if (runpaths != ["$ORIGIN"] or not raw_paths or
            any(not path or path != "$ORIGIN" for path in runpaths)):
        raise GateError("linked plugin runtime search path must be exactly the bounded $ORIGIN policy")
    receipt["plugin"] = {"path": str(plugin_path), "sha256": file_digest(plugin_path),
                         "needed": needed, "runpath": runpaths}
    receipt["stage"] = "plugin-linked"
    receipt["status"] = "passed"


def inspect_bundle_elf_header(path: Path, readelf: str, receipt: dict) -> dict:
    data = path.read_bytes()
    if (len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1 or
            struct.unpack_from("<H", data, 16)[0] != 3 or
            struct.unpack_from("<H", data, 18)[0] != 62):
        raise GateError(f"bundle shared library is not ELF64 little-endian x86_64 ET_DYN: {path}")
    header = run_tool([readelf, "-h", str(path)], receipt)
    if not all(re.search(pattern, header, re.MULTILINE) for pattern in (
            r"^\s*Class:\s+ELF64\s*$", r"^\s*Data:\s+2's complement, little endian\s*$",
            r"^\s*Type:\s+DYN\s+\(Shared object file\)",
            r"^\s*Machine:\s+Advanced Micro Devices X86-64\s*$")):
        raise GateError(f"bundle shared library has wrong ELF ABI/type: {path}")
    return {"sha256": digest(data), "elfClass": 64, "machine": 62, "type": "DYN"}


def verify_bundle(bundle: Path, root: Path, receipt_path: Path, app_root: Path,
                  media_kit_root: Path, readelf: str, receipt: dict) -> None:
    receipt.update(nativeVerificationScope="approved-producer-closure-and-plugin-link",
                   bundleSharedLibraries=[], fullBundleProvenanceVerified=False,
                   releaseVerified=False)
    manifest = verify_local(root, receipt_path, app_root, media_kit_root, readelf, receipt)
    if bundle.is_symlink() or not bundle.is_dir():
        raise GateError("final Linux application bundle missing or symbolic link")
    install_lib = bundle / "lib"
    if install_lib.is_symlink() or not install_lib.is_dir():
        raise GateError("final Linux bundle must contain its canonical lib directory")
    expected_libs = {manifest["members"][path]["soname"]: root / path
                     for path in manifest["members"]}
    found_libs = {}
    for soname, source in expected_libs.items():
        path = install_lib / soname
        if path.is_symlink() or not path.is_file():
            raise GateError(f"final application bundle is missing canonical DSO: lib/{soname}")
        if file_digest(path) != file_digest(source):
            raise GateError(f"application bundle DSO differs from accepted input: {soname}")
        found_libs[soname] = path
    for candidate in bundle.rglob("*"):
        if candidate.is_symlink() and candidate.name in expected_libs:
            raise GateError("approved DSO is a symbolic link")
        if candidate.is_file() and candidate.name in expected_libs and candidate != install_lib / candidate.name:
            raise GateError(f"approved DSO appears outside canonical bundle location: {candidate.name}")
    plugin = install_lib / "libmedia_kit_video_plugin.so"
    if plugin.is_symlink() or not plugin.is_file():
        raise GateError("final Linux bundle must contain lib/libmedia_kit_video_plugin.so")
    if sum(1 for candidate in bundle.rglob("libmedia_kit_video_plugin.so") if candidate.is_file()) != 1:
        raise GateError("final Linux bundle contains duplicate plugin output")
    verify_plugin(plugin, root, receipt_path, app_root, media_kit_root,
                  readelf, receipt)
    # Resolve every reviewed bundled edge at the canonical flat install path.
    resolutions = {(item["requester"], item["needed"]): item
                   for item in manifest["dependencyClosure"]}
    inspected = {}
    for rel, declaration in manifest["members"].items():
        path = found_libs[declaration["soname"]]
        inspected[rel] = inspect_elf(path, rel, declaration, readelf, receipt)
    plugin_dynamic = run_tool([readelf, "-d", str(plugin.resolve(strict=True))], receipt)
    plugin_needed = re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", plugin_dynamic)
    for needed in plugin_needed:
        if needed in expected_libs:
            resolved = install_lib / needed
            if not resolved.is_file() or resolved.is_symlink():
                raise GateError(f"plugin bundled dependency is unreachable at lib/{needed}")
    bundled_edges: dict[str, set[str]] = {rel: set() for rel in inspected}
    for rel, dynamic in inspected.items():
        for needed in dynamic["needed"]:
            resolution = resolutions[(rel, needed)]
            if resolution["kind"] == "bundled":
                target_name = manifest["members"][resolution["member"]]["soname"]
                target = install_lib / target_name
                if target != found_libs[target_name] or not target.is_file() or target.is_symlink():
                    raise GateError(f"bundled NEEDED edge is unreachable from lib/{dynamic['soname']}: {needed}")
                if target_name != needed or file_digest(target) != resolution["sha256"]:
                    raise GateError(f"bundle NEEDED resolution differs from accepted SONAME/hash: {needed}")
                bundled_edges[rel].add(needed)
            elif (install_lib / needed).exists():
                raise GateError(f"bundle shadows reviewed system dependency {needed}")
    for rel, declaration in manifest["members"].items():
        dynamic = inspected[rel]
        if bundled_edges[rel]:
            effective = dynamic["runpath"] or dynamic["rpath"]
            if (dynamic["runpath"] and dynamic["rpath"]) or effective != ["$ORIGIN"]:
                raise GateError(f"bundle requester lacks its own exact $ORIGIN path for bundled NEEDED entries: {declaration['soname']}")
        elif dynamic["runpath"] and dynamic["rpath"]:
            raise GateError(f"bundle DSO has ambiguous RPATH and RUNPATH tags: {declaration['soname']}")

    # Keep the original bundle-wide native ABI gate. Producer-owned files get
    # manifest hash/Build ID/NEEDED checks above; Flutter/AOT/plugin outputs
    # still need to be regular ELF64 little-endian x86_64 ET_DYN files.
    shared_libraries = []
    for path in bundle.rglob("*"):
        if ".so" not in path.name:
            continue
        if path.is_symlink() or not path.is_file():
            raise GateError(f"application bundle contains symbolic/non-regular shared library: {path}")
        if path.stat().st_size > MAX_FILE:
            raise GateError(f"application bundle shared library exceeds size limit: {path.name}")
        name = path.name
        if name in expected_libs:
            if path != found_libs[name]:
                raise GateError(f"approved DSO appears outside canonical bundle location: {name}")
            info = inspected[next(rel for rel, member in manifest["members"].items()
                                  if member["soname"] == name)]
            classification = "approved-producer-payload"
            source_status = "producer-hash-bound"
        elif path == plugin:
            info = inspect_bundle_elf_header(path, readelf, receipt)
            classification = "generated-media-kit-plugin"
            source_status = "generated-plugin-link-verified"
        else:
            info = inspect_bundle_elf_header(path, readelf, receipt)
            classification = ("flutter-runtime" if name == "libflutter_linux_gtk.so" else
                              "app-aot-output" if name == "libapp.so" else
                              "app-bundled-native-output")
            source_status = "unbound-generated-build-output"
        shared_libraries.append({"path": path.relative_to(bundle).as_posix(),
                                 "classification": classification,
                                 "sourceStatus": source_status, **info})
    if sum(item["classification"] == "generated-media-kit-plugin" for item in shared_libraries) != 1:
        raise GateError("bundle must contain exactly one generated media-kit plugin shared object")
    receipt.update(stage="bundle-verified", status="passed", bundle=str(bundle.resolve()),
                   bundleMembers={name: file_digest(path) for name, path in found_libs.items()},
                   bundleSharedLibraries=sorted(shared_libraries, key=lambda item: item["path"]),
                   nativeVerificationScope="approved-producer-closure-and-plugin-link",
                   fullBundleProvenanceVerified=False, releaseVerified=False,
                   nativeVerified=True, deviceVerified=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check-ledger", action="store_true")
    mode.add_argument("--local-input", action="store_true")
    mode.add_argument("--verify-plugin", type=Path)
    mode.add_argument("--verify-bundle", type=Path)
    parser.add_argument("--app-root", type=Path)
    parser.add_argument("--media-kit-root", type=Path)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--result", type=Path,
                        help="write post-build diagnostics separately from the accepted input receipt")
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--write-cmake", type=Path)
    args = parser.parse_args()
    receipt = {"schemaVersion": 1, "task": TASK, "scope": "routing-linux-native-input",
               "stage": "trusted-ledger", "status": "failed", "nativeVerified": False,
               "deviceVerified": False, "consumer": {}, "native": {},
               "verifierSha256": "", "files": {"members": {}, "headers": {}}, "commands": []}
    try:
        if args.check_ledger:
            if args.app_root is None:
                raise GateError("--app-root is required")
            app, _, ledger, _ = trusted_app(args.app_root, receipt)
            selected_entry(ledger)
            receipt.update(status="passed", stage="ledger", appRoot=str(app))
        elif args.local_input:
            if None in (args.app_root, args.media_kit_root, args.root):
                raise GateError("--local-input requires --app-root, --media-kit-root, and --root")
            verify_local(args.root, args.receipt, args.app_root, args.media_kit_root,
                         args.readelf, receipt, args.write_cmake)
        else:
            if None in (args.app_root, args.media_kit_root, args.root):
                raise GateError("post-build verification requires exact App/media-kit roots and native root")
            if args.verify_plugin:
                verify_plugin(args.verify_plugin, args.root, args.receipt, args.app_root,
                              args.media_kit_root, args.readelf, receipt)
            else:
                verify_bundle(args.verify_bundle, args.root, args.receipt, args.app_root,
                              args.media_kit_root, args.readelf, receipt)
    except Exception as error:
        receipt.update(status="failed", nativeVerified=False, reason=str(error))
        code = 1
    else:
        code = 0
    try:
        result_path = args.result or args.receipt
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except OSError as error:
        print(f"routing Linux native receipt write failed: {error}", file=sys.stderr)
        return 1
    if args.write_cmake != Path("-"):
        print(f"routing Linux native gate: {receipt['status']} ({receipt['stage']})")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
