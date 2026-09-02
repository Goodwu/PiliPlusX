#!/usr/bin/env python3
"""Create deterministic release hashes and metadata for a build directory."""

from __future__ import annotations

import argparse
import hashlib
import json
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

    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"release directory does not exist: {root}")
    output = (args.output or root / "manifest.json").resolve()
    if output.parent != root:
        parser.error("--output must be directly inside the release directory")

    files = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path in (output, root / "SHA256SUMS"):
            continue
        relative = path.relative_to(root).as_posix()
        files.append({"path": relative, "sha256": sha256(path), "size": path.stat().st_size})

    sums = root / "SHA256SUMS"
    sums.write_text(
        "".join(f"{item['sha256']}  {item['path']}\n" for item in files),
        encoding="utf-8",
    )
    manifest = {
        "schema": 1,
        "platform": args.platform,
        "abi": args.abi,
        "gitCommit": args.git_commit or git_value(),
        "mediaKitCommit": args.media_kit_commit,
        "hdrBackend": args.hdr_backend,
        "nativeLibraryVersion": args.native_library_version,
        "files": files,
    }
    output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
