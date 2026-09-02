#!/usr/bin/env python3
"""Verify that release metadata and SHA256SUMS describe the same files."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
NATIVE_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+@[0-9][A-Za-z0-9+_.-]*$")


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    manifest_path = root / "manifest.json"
    sums_path = root / "SHA256SUMS"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1:
        raise SystemExit("unsupported release manifest schema")
    for field in ("platform", "abi", "hdrBackend", "nativeLibraryVersion"):
        if not isinstance(manifest.get(field), str) or not manifest[field].strip():
            raise SystemExit(f"release manifest has invalid {field}")
    media_kit_commit = manifest.get("mediaKitCommit")
    if not isinstance(media_kit_commit, str) or not SHA_RE.fullmatch(media_kit_commit):
        raise SystemExit("release manifest has no full immutable mediaKitCommit")
    player_commit = manifest.get("gitCommit")
    if not isinstance(player_commit, str) or not SHA_RE.fullmatch(player_commit):
        raise SystemExit("release manifest has no full player gitCommit")
    if not NATIVE_VERSION_RE.fullmatch(manifest["nativeLibraryVersion"]):
        raise SystemExit("release manifest has invalid nativeLibraryVersion")
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        raise SystemExit("release manifest has no files")

    expected: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise SystemExit("release manifest contains an invalid file entry")
        relative = entry.get("path")
        if not isinstance(relative, str) or Path(relative).is_absolute():
            raise SystemExit(f"invalid manifest path: {relative!r}")
        if relative in expected:
            raise SystemExit(f"duplicate manifest path: {relative}")
        path = (root / relative).resolve()
        if root not in path.parents or not path.is_file():
            raise SystemExit(f"manifest file is missing: {relative}")
        actual = digest(path)
        if actual != entry.get("sha256") or path.stat().st_size != entry.get("size"):
            raise SystemExit(f"manifest does not match file: {relative}")
        expected[relative] = actual

    observed: dict[str, str] = {}
    for line in sums_path.read_text(encoding="utf-8").splitlines():
        checksum, separator, relative = line.partition("  ")
        if not separator or not HASH_RE.fullmatch(checksum) or not relative:
            raise SystemExit(f"invalid SHA256SUMS line: {line!r}")
        if relative in observed:
            raise SystemExit(f"duplicate SHA256SUMS path: {relative}")
        observed[relative] = checksum
    if observed != expected:
        raise SystemExit("SHA256SUMS does not match manifest")
    print(f"release manifest verified: {len(expected)} files")


if __name__ == "__main__":
    main()
