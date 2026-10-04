#!/usr/bin/env python3
"""Create deterministic release hashes and metadata for a build directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_value() -> str | None:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$")


def regular_payloads(root: Path, excluded: set[Path]) -> list[dict[str, object]]:
    files: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"release payload may not contain symbolic links: {path.relative_to(root)}")
        if not path.is_file() or path in excluded:
            continue
        relative = path.relative_to(root).as_posix()
        if Path(relative).name != relative or "\\" in relative or relative in (".", ".."):
            raise ValueError(f"release payload path must be a flat filename: {relative!r}")
        files.append({"path": relative, "sha256": sha256(path), "size": path.stat().st_size})
    return files


def _required_hash(value: object, field: str, parent: str) -> str:
    item = value.get(field) if isinstance(value, dict) else None
    if not isinstance(item, str) or not HASH_RE.fullmatch(item):
        raise ValueError(f"macOS distribution has no valid {parent}.{field}")
    return item


def validate_shared_distribution(root: Path, files: list[dict[str, object]],
                                 git_commit: str | None, media_kit_commit: str,
                                 abi: str, hdr_backend: str) -> dict[str, object]:
    if abi != "universal-arm64+x86_64":
        raise ValueError("macOS shared release ABI must be universal-arm64+x86_64")
    if hdr_backend != "shared-gpu-next":
        raise ValueError("macOS shared release backend must be shared-gpu-next")
    if not isinstance(git_commit, str) or not SHA_RE.fullmatch(git_commit):
        raise ValueError("macOS shared release requires the exact full application source commit")
    if not SHA_RE.fullmatch(media_kit_commit):
        raise ValueError("macOS shared release requires an approved immutable media-kit commit")
    names = [entry["path"] for entry in files]
    dmgs = [name for name in names if isinstance(name, str) and name.endswith(".dmg")]
    distributions = [name for name in names if isinstance(name, str) and name.endswith(".shared-distribution.json")]
    cores = [name for name in names if isinstance(name, str) and name.endswith(".shared-core.json")]
    backends = [name for name in names if isinstance(name, str) and name.endswith(".shared-backend.json")]
    if not (len(files) == 4 and len(dmgs) == len(distributions) == len(cores) == len(backends) == 1):
        raise ValueError("macOS shared release requires exactly one DMG and exactly three shared sidecars")
    dmg, distribution_name, core_name, backend_name = dmgs[0], distributions[0], cores[0], backends[0]
    prefix = dmg.removesuffix(".dmg")
    expected = {f"{prefix}.shared-core.json", f"{prefix}.shared-backend.json",
                f"{prefix}.shared-distribution.json"}
    if {distribution_name, core_name, backend_name} != expected or not prefix.startswith("PiliPlusX_macos_v"):
        raise ValueError("macOS shared payloads must use the DMG's PiliPlusX_macos_<tag> prefix")
    tag = prefix.removeprefix("PiliPlusX_macos_")
    if not TAG_RE.fullmatch(tag):
        raise ValueError("macOS shared payload has an invalid release tag")
    try:
        distribution = json.loads((root / distribution_name).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid macOS shared distribution report: {error}") from error
    if not isinstance(distribution, dict):
        raise ValueError("macOS shared distribution report must be a JSON object")
    if (type(distribution.get("schema_version")) is not int or
            distribution.get("schema_version") != 2 or distribution.get("status") != "ready" or
            distribution.get("production_eligible") is not True):
        raise ValueError("macOS shared distribution is not a production-eligible ready report")
    gate_execution = distribution.get("gate_execution")
    if (not isinstance(gate_execution, dict) or
            type(gate_execution.get("schema_version")) is not int or
            gate_execution.get("schema_version") != 1):
        raise ValueError("macOS shared distribution has no supported gate_execution identity")
    eligibility = distribution.get("eligibility")
    if (not isinstance(eligibility, dict) or eligibility.get("enabled") is not True or
            eligibility.get("missing") != []):
        raise ValueError("macOS shared distribution eligibility is disabled or incomplete")
    source = distribution.get("source")
    if (not isinstance(source, dict) or source.get("source_ref") != git_commit or
            source.get("peeled_tag_commit") != git_commit or source.get("release_tag") != tag):
        raise ValueError("macOS shared distribution source identity does not match the release")
    if distribution.get("approved_media_kit_revision") != media_kit_commit:
        raise ValueError("macOS distribution does not bind the approved media-kit revision")
    lock = distribution.get("lock")
    if (not isinstance(lock, dict) or lock.get("path") != "scripts/macos-shared-ci-inputs.lock.json" or
            not isinstance(lock.get("sha256"), str) or not HASH_RE.fullmatch(lock["sha256"])):
        raise ValueError("macOS distribution has no valid fixed acquisition lock identity")
    dmg_record = distribution.get("dmg")
    dmg_entry = next(entry for entry in files if entry["path"] == dmg)
    if (not isinstance(dmg_record, dict) or dmg_record.get("filename") != dmg or
            dmg_record.get("sha256") != dmg_entry["sha256"]):
        raise ValueError("macOS distribution DMG filename or digest differs from the payload")
    by_name = {entry["path"]: entry for entry in files}
    return {
        "schema_version": 1,
        "distribution": {"path": distribution_name, "sha256": by_name[distribution_name]["sha256"]},
        "shared_core": {"path": core_name, "sha256": by_name[core_name]["sha256"]},
        "shared_backend": {"path": backend_name, "sha256": by_name[backend_name]["sha256"]},
        "runner_sha256": _required_hash(distribution.get("build"), "runner_sha256", "build"),
        "mpv_sha256": _required_hash(distribution.get("build"), "mpv_sha256", "build"),
        "build_identity_sha256": _required_hash(distribution.get("build"), "identity_sha256", "build"),
        "sealed_input_manifest_sha256": _required_hash(distribution.get("sealed"), "input_manifest_sha256", "sealed"),
        "acquisition_manifest_sha256": _required_hash(distribution.get("sealed"), "acquisition_manifest_sha256", "sealed"),
        "signed_context_manifest_sha256": _required_hash(distribution.get("sealed"), "signed_context_manifest_sha256", "sealed"),
        "runtime_manifest_sha256": _required_hash(distribution.get("sealed"), "runtime_manifest_sha256", "sealed"),
        "source_manifest_sha256": _required_hash(distribution.get("source_manifest"), "identity_sha256", "source_manifest"),
        "consumer_app_tree_identity_sha256": _required_hash(distribution.get("consumer"), "app_tree_identity_sha256", "consumer"),
        "mounted_app_tree_identity_sha256": _required_hash(distribution.get("mounted_app"), "tree_identity_sha256", "mounted_app"),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="directory containing release files")
    parser.add_argument("--platform", required=True)
    parser.add_argument("--abi", required=True)
    parser.add_argument("--media-kit-commit", required=True)
    parser.add_argument("--hdr-backend", default="texture-tone-map")
    parser.add_argument("--native-library-version", required=True)
    parser.add_argument(
        "--git-commit",
        default=None,
        help="source commit to record when the release directory is outside a git checkout",
    )
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    if args.root.is_symlink():
        parser.error("release directory may not be a symbolic link")
    root = args.root.resolve(strict=True)
    if not root.is_dir():
        parser.error(f"release directory does not exist: {root}")
    requested_output = args.output or root / "manifest.json"
    if not requested_output.is_absolute():
        requested_output = root / requested_output
    if requested_output.is_symlink():
        parser.error("manifest output may not be a symbolic link")
    output = requested_output.absolute()
    if output.parent.resolve() != root:
        parser.error("--output must be directly inside the release directory")

    files = regular_payloads(root, {output, root / "SHA256SUMS"})

    sums = root / "SHA256SUMS"
    git_commit = args.git_commit or git_value()
    manifest = {
        "schema": 2 if args.platform == "macos" else 1,
        "platform": args.platform,
        "abi": args.abi,
        "gitCommit": git_commit,
        "mediaKitCommit": args.media_kit_commit,
        "hdrBackend": args.hdr_backend,
        "nativeLibraryVersion": args.native_library_version,
        "files": files,
    }
    if args.platform == "macos":
        try:
            manifest["sharedRelease"] = validate_shared_distribution(
                root, files, git_commit, args.media_kit_commit, args.abi, args.hdr_backend)
        except ValueError as error:
            parser.error(str(error))
    sums.write_text(
        "".join(f"{item['sha256']}  {item['path']}\n" for item in files),
        encoding="utf-8",
    )
    output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
