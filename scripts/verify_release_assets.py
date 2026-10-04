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

from verify_release_manifest import trusted_source


VERIFIER = Path(__file__).with_name("verify_release_manifest.py")
REQUIRED_PLATFORMS = {"android", "ios", "macos", "ohos"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--expected-source",
                        help="full application source commit selected by the release context job")
    parser.add_argument("--source-checkout", type=Path,
                        help="checkout supplying the trusted committed macOS acquisition lock")
    args = parser.parse_args()
    if args.expected_source is not None and (
        len(args.expected_source) != 40 or any(
        character not in "0123456789abcdef" for character in args.expected_source
        )
    ):
        parser.error("--expected-source must be a lowercase full 40-character commit")
    root = args.root.resolve(strict=True)
    if not root.is_dir() or args.root.is_symlink():
        raise SystemExit("release asset root must be a real directory")
    manifests = sorted(root.glob("*.manifest.json"))
    if not manifests:
        raise SystemExit("release contains no platform manifests")

    platforms: set[str] = set()
    declared_files: set[str] = set()
    expected_source = args.expected_source
    loaded: list[tuple[Path, str, dict]] = []
    # Validate every manifest and every path before copying any user-controlled
    # asset into the verifier staging area.
    for manifest_path in manifests:
        if manifest_path.is_symlink() or not manifest_path.is_file():
            raise SystemExit(f"release manifest is not a regular file: {manifest_path.name}")
        suffix = ".manifest.json"
        prefix = manifest_path.name[: -len(suffix)]
        sums_path = root / f"{prefix}.SHA256SUMS"
        if sums_path.is_symlink() or not sums_path.is_file():
            raise SystemExit(f"release asset is missing checksum file: {sums_path.name}")
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise SystemExit(f"invalid release manifest {manifest_path.name}: {error}")
        if not isinstance(manifest, dict):
            raise SystemExit(f"invalid release manifest object: {manifest_path.name}")
        platform = manifest.get("platform")
        if not isinstance(platform, str) or platform in platforms:
            raise SystemExit(f"release has invalid or duplicate platform manifest: {platform!r}")
        platforms.add(platform)
        source_commit = manifest.get("gitCommit")
        if expected_source is None:
            expected_source = source_commit
        if (not isinstance(expected_source, str) or len(expected_source) != 40 or
                any(character not in "0123456789abcdef" for character in expected_source) or
                source_commit != expected_source):
            raise SystemExit(
                f"{platform} source commit {source_commit!r} does not match "
                f"release source {expected_source}"
            )
        entries = manifest.get("files")
        if not isinstance(entries, list) or not entries:
            raise SystemExit(f"release manifest has no files: {manifest_path.name}")
        for file_info in entries:
            name = file_info.get("path") if isinstance(file_info, dict) else None
            if (not isinstance(name, str) or not name or name in (".", "..") or
                    Path(name).is_absolute() or Path(name).name != name or
                    "\\" in name or "/" in name):
                raise SystemExit(f"unsafe or unsupported release asset path: {name!r}")
            if name in declared_files:
                raise SystemExit(f"duplicate declared release asset: {name}")
            if (name in {path.name for path in manifests} or
                    name in {f"{item.name[:-len('.manifest.json')]}.SHA256SUMS" for item in manifests} or
                    name in ("manifest.json", "SHA256SUMS") or
                    name.endswith(".manifest.json") or name.endswith(".SHA256SUMS")):
                raise SystemExit(f"release payload collides with metadata control file: {name}")
            declared_files.add(name)
            source = root / name
            if source.is_symlink() or not source.is_file():
                raise SystemExit(f"release asset is missing or not a regular file: {name}")
        loaded.append((manifest_path, prefix, manifest))

    if platforms != REQUIRED_PLATFORMS:
        raise SystemExit(f"release platforms are {sorted(platforms)}, expected {sorted(REQUIRED_PLATFORMS)}")
    if "macos" in platforms:
        if args.expected_source is None or args.source_checkout is None:
            raise SystemExit("four-platform macOS release verification requires --expected-source and --source-checkout")
        _, _, trusted_checkout, _ = trusted_source(
            args.source_checkout, args.expected_source, aggregate=True)
    else:
        trusted_checkout = None

    expected_sums = {
        f"{path.name[:-len('.manifest.json')]}.SHA256SUMS" for path in manifests
    }
    observed_sums = {path.name for path in root.glob("*.SHA256SUMS")}
    if observed_sums != expected_sums:
        raise SystemExit(
            f"release checksum set differs from manifests: unexpected={sorted(observed_sums - expected_sums)} "
            f"missing={sorted(expected_sums - observed_sums)}"
        )
    control_files = {path.name for path in manifests} | expected_sums
    expected_files = declared_files | control_files
    observed_files = set()
    for path in root.iterdir():
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f"release asset directory contains a non-regular entry: {path.name}")
        observed_files.add(path.name)
    if observed_files != expected_files:
        raise SystemExit(
            f"release asset set differs from manifests: unexpected={sorted(observed_files - expected_files)} "
            f"missing={sorted(expected_files - observed_files)}"
        )

    with tempfile.TemporaryDirectory() as directory:
        for manifest_path, prefix, manifest in loaded:
            sums_path = root / f"{prefix}.SHA256SUMS"
            stage = Path(directory) / prefix
            stage.mkdir()
            shutil.copy2(manifest_path, stage / "manifest.json")
            shutil.copy2(sums_path, stage / "SHA256SUMS")
            for file_info in manifest.get("files", []):
                name = file_info.get("path") if isinstance(file_info, dict) else None
                source = root / name
                shutil.copy2(source, stage / name)
            command = [sys.executable, str(VERIFIER), str(stage),
                       "--expected-source", expected_source]
            if trusted_checkout is not None:
                command.extend(["--source-checkout", str(trusted_checkout)])
            subprocess.run(command, check=True)
    print("release assets verified: android, ios, macos, ohos")


if __name__ == "__main__":
    main()
