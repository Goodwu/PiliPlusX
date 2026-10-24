#!/usr/bin/env python3
"""Source-bound, relocatable identity and argv validation for shared macOS gates.

The consumer verifies producer paths as POSIX strings only. It never opens or
resolves a path recorded by another runner; the executable gate scripts are
instead identified by their committed bytes in the expected source commit.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path, PurePosixPath
from typing import Mapping


HASH_RE = re.compile(r"^[0-9a-f]{64}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
LOCK_RELATIVE = "scripts/macos-shared-ci-inputs.lock.json"
GATE_SCRIPTS = (
    "scripts/verify_macos_mpv_bundle.sh",
    "scripts/verify_binary_arch.py",
    "scripts/verify_macos_shared_backend.py",
    "scripts/verify_macos_mpv_closure.py",
    "scripts/verify_macos_mpv_load.sh",
    "scripts/native/macos_mpv_smoke.c",
    "scripts/native/shared_backend_probe.c",
)


class GateIdentityError(ValueError):
    """Raised when a trusted source or gate execution identity is invalid."""


def canonical_absolute_path(value: object, label: str) -> str:
    if (not isinstance(value, str) or not value or "\x00" in value or
            "\\" in value or not value.startswith("/") or value == "/"):
        raise GateIdentityError(f"{label} must be a canonical absolute POSIX path")
    components = value.split("/")
    if (components[0] != "" or any(part in ("", ".", "..") for part in components[1:]) or
            str(PurePosixPath(value)) != value):
        raise GateIdentityError(f"{label} must be a canonical absolute POSIX path")
    return value


def _python_path(value: object) -> str:
    result = canonical_absolute_path(value, "producer Python executable")
    if not re.fullmatch(r"python(?:[0-9]+(?:\.[0-9]+)*)?", PurePosixPath(result).name):
        raise GateIdentityError("producer Python executable has an unexpected basename")
    return result


def _git(checkout: Path, *args: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *args], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise GateIdentityError(f"cannot verify trusted gate source: {error}") from error
    return result.stdout


def _ordinary_committed_file(checkout: Path, commit: str, relative: str) -> bytes:
    record = _git(checkout, "ls-tree", commit, "--", relative).decode("utf-8", "replace")
    if not (record.startswith("100644 blob ") or record.startswith("100755 blob ")):
        raise GateIdentityError(f"trusted source is missing a regular committed file: {relative}")
    current = checkout
    for component in PurePosixPath(relative).parts:
        current = current / component
        if current.is_symlink():
            raise GateIdentityError(f"trusted source path contains a symbolic link: {relative}")
    path = checkout / relative
    if not path.is_file():
        raise GateIdentityError(f"trusted source file is missing: {relative}")
    committed = _git(checkout, "show", f"{commit}:{relative}")
    if path.read_bytes() != committed:
        raise GateIdentityError(f"trusted source working bytes differ from commit: {relative}")
    return committed


def _source_checkout(source_checkout: Path, expected_source: str) -> Path:
    if not isinstance(expected_source, str) or not SHA_RE.fullmatch(expected_source):
        raise GateIdentityError("gate identity requires a full expected source commit")
    if source_checkout.is_symlink():
        raise GateIdentityError("trusted source checkout may not be a symbolic link")
    try:
        checkout = source_checkout.resolve(strict=True)
    except OSError as error:
        raise GateIdentityError(f"trusted source checkout is unavailable: {error}") from error
    if not checkout.is_dir():
        raise GateIdentityError("trusted source checkout is not a directory")
    try:
        head = _git(checkout, "rev-parse", "--verify", "HEAD").decode("ascii").strip()
    except UnicodeError as error:
        raise GateIdentityError("trusted source HEAD is not valid ASCII") from error
    if head != expected_source:
        raise GateIdentityError("trusted source checkout HEAD differs from expected source")
    return checkout


def trusted_gate_digests(source_checkout: Path, expected_source: str) -> dict[str, str]:
    """Return the fixed gate-script identities from committed source bytes."""
    checkout = _source_checkout(source_checkout, expected_source)
    result = {}
    for relative in GATE_SCRIPTS:
        content = _ordinary_committed_file(checkout, expected_source, relative)
        result[relative] = hashlib.sha256(content).hexdigest()
    return result


def trusted_lock_identity(source_checkout: Path, expected_source: str) -> tuple[str, str]:
    """Return the approved immutable revision and committed lock-byte digest."""
    checkout = _source_checkout(source_checkout, expected_source)
    lock_bytes = _ordinary_committed_file(checkout, expected_source, LOCK_RELATIVE)
    try:
        lock = json.loads(lock_bytes.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GateIdentityError(f"trusted source lock is invalid JSON: {error}") from error
    revision = lock.get("reviewed_media_kit_revision") if isinstance(lock, dict) else None
    if not isinstance(revision, str) or not SHA_RE.fullmatch(revision):
        raise GateIdentityError("trusted source lock has no approved immutable media-kit revision")
    return revision, hashlib.sha256(lock_bytes).hexdigest()


def capture_gate_execution(source_checkout: Path, expected_source: str, *,
                           python_executable: str,
                           backend_inputs: Mapping[str, str]) -> dict[str, object]:
    """Capture a producer-local execution identity, anchored to committed source.

    Call before and after producer gates and require the returned objects to be
    byte-for-byte equivalent. The lock digest is intentionally checked during
    capture but stays in the existing distribution ``lock`` record.
    """
    checkout = _source_checkout(source_checkout, expected_source)
    digests = trusted_gate_digests(checkout, expected_source)
    trusted_lock_identity(checkout, expected_source)
    root = canonical_absolute_path(str(checkout), "producer checkout root")
    interpreter = _python_path(python_executable)
    if not isinstance(backend_inputs, Mapping) or set(backend_inputs) != {
        "prepared_source", "source_manifest", "report"
    }:
        raise GateIdentityError("backend_inputs must contain exactly prepared_source, source_manifest, and report")
    inputs = {
        name: canonical_absolute_path(backend_inputs[name], f"backend_inputs.{name}")
        for name in ("prepared_source", "source_manifest", "report")
    }
    if PurePosixPath(inputs["source_manifest"]).name != "manifest.json":
        raise GateIdentityError("backend_inputs.source_manifest must end in manifest.json")
    return {
        "schema_version": 1,
        "producer_checkout_root": root,
        "python_executable": interpreter,
        "scripts": digests,
        "backend_inputs": inputs,
    }


def validate_gate_execution(value: object, trusted_digests: Mapping[str, str]) -> dict[str, object]:
    """Validate schema and source digests without opening producer-side paths."""
    if not isinstance(value, dict) or type(value.get("schema_version")) is not int or value.get("schema_version") != 1:
        raise GateIdentityError("unsupported or missing gate_execution schema")
    if set(value) != {"schema_version", "producer_checkout_root", "python_executable", "scripts", "backend_inputs"}:
        raise GateIdentityError("gate_execution has unexpected or missing fields")
    root = canonical_absolute_path(value.get("producer_checkout_root"), "producer checkout root")
    interpreter = _python_path(value.get("python_executable"))
    scripts = value.get("scripts")
    if not isinstance(scripts, dict) or set(scripts) != set(GATE_SCRIPTS):
        raise GateIdentityError("gate_execution scripts must contain exactly the fixed seven scripts")
    for relative in GATE_SCRIPTS:
        digest = scripts.get(relative)
        trusted = trusted_digests.get(relative)
        if (not isinstance(digest, str) or not HASH_RE.fullmatch(digest) or
                not isinstance(trusted, str) or not HASH_RE.fullmatch(trusted) or digest != trusted):
            raise GateIdentityError(f"gate script identity differs from trusted source: {relative}")
    inputs = value.get("backend_inputs")
    if not isinstance(inputs, dict) or set(inputs) != {"prepared_source", "source_manifest", "report"}:
        raise GateIdentityError("gate_execution backend_inputs has unexpected or missing fields")
    normalized_inputs = {
        name: canonical_absolute_path(inputs.get(name), f"backend_inputs.{name}")
        for name in ("prepared_source", "source_manifest", "report")
    }
    if PurePosixPath(normalized_inputs["source_manifest"]).name != "manifest.json":
        raise GateIdentityError("backend_inputs.source_manifest must end in manifest.json")
    return {
        "schema_version": 1,
        "producer_checkout_root": root,
        "python_executable": interpreter,
        "scripts": dict(scripts),
        "backend_inputs": normalized_inputs,
    }


def validate_gate_argv(argv: object, gate_name: str, execution: Mapping[str, object],
                       app_path: str, *, consumer_app_path: str | None = None) -> None:
    """Require an exact gate command while treating all paths as foreign strings."""
    if not isinstance(execution, Mapping):
        raise GateIdentityError("gate execution identity is not a mapping")
    root = execution["producer_checkout_root"]
    python = execution["python_executable"]
    scripts = execution["scripts"]
    inputs = execution["backend_inputs"]
    if (not isinstance(root, str) or not isinstance(python, str) or
            not isinstance(scripts, dict) or not isinstance(inputs, dict)):
        raise GateIdentityError("gate execution identity is malformed")
    canonical_absolute_path(app_path, "gate App path")
    runner = f"{app_path}/Contents/MacOS/PiliPlusX"
    bundle = f"{root}/scripts/verify_macos_mpv_bundle.sh"
    arch_script = f"{root}/scripts/verify_binary_arch.py"
    backend_script = f"{root}/scripts/verify_macos_shared_backend.py"
    if gate_name == "codesign":
        expected = ["/usr/bin/codesign", "--verify", "--deep", "--strict", app_path]
    elif gate_name in ("bundle", "final_bundle"):
        target = consumer_app_path if gate_name == "final_bundle" else app_path
        if target is None:
            raise GateIdentityError("final bundle gate requires the consumer App path")
        canonical_absolute_path(target, "consumer App path")
        expected = [bundle, target]
    elif gate_name in ("arm64", "x86_64"):
        expected = [python, arch_script, runner, "--platform", "macos", "--arch", gate_name]
    elif gate_name == "backend":
        expected = [python, backend_script, app_path, inputs["prepared_source"],
                    inputs["source_manifest"], "--report", inputs["report"]]
    else:
        raise GateIdentityError(f"unexpected gate name: {gate_name!r}")
    if argv != expected:
        raise GateIdentityError(f"{gate_name} gate argv differs from its trusted execution identity")
