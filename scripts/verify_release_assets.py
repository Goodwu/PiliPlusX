#!/usr/bin/env python3
"""Verify the complete set of assets assembled for one public release."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


VERIFIER = Path(__file__).with_name("verify_release_manifest.py")
REQUIRED_PLATFORMS = {"android", "ios", "macos", "ohos"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    manifests = sorted(root.glob("*.manifest.json"))
    if not manifests:
        raise SystemExit("release contains no platform manifests")

    platforms: set[str] = set()
    with tempfile.TemporaryDirectory() as directory:
        for manifest_path in manifests:
            suffix = ".manifest.json"
            prefix = manifest_path.name[: -len(suffix)]
            sums_path = root / f"{prefix}.SHA256SUMS"
            if not sums_path.is_file():
                raise SystemExit(f"release asset is missing checksum file: {sums_path.name}")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            platform = manifest.get("platform")
            if platform in platforms:
                raise SystemExit(f"release has duplicate platform manifest: {platform}")
            platforms.add(platform)
            stage = Path(directory) / prefix
            stage.mkdir()
            shutil.copy2(manifest_path, stage / "manifest.json")
            shutil.copy2(sums_path, stage / "SHA256SUMS")
            for file_info in manifest.get("files", []):
                name = file_info.get("path") if isinstance(file_info, dict) else None
                source = root / name if isinstance(name, str) else None
                if source is None or not source.is_file():
                    raise SystemExit(f"release asset is missing manifest file: {name!r}")
                shutil.copy2(source, stage / name)
            subprocess.run([sys.executable, str(VERIFIER), str(stage)], check=True)
    if platforms != REQUIRED_PLATFORMS:
        raise SystemExit(f"release platforms are {sorted(platforms)}, expected {sorted(REQUIRED_PLATFORMS)}")
    print("release assets verified: android, ios, macos, ohos")


if __name__ == "__main__":
    main()
