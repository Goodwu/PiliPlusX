#!/usr/bin/env python3
"""Validate native ABI layout in packaged Android-family artifacts."""

from __future__ import annotations

import argparse
import zipfile
from pathlib import Path


ANDROID_ABIS = {
    "armeabi-v7a",
    "arm64-v8a",
    "x86",
    "x86_64",
}


def verify_android_archive(path: Path, abi: str) -> None:
    if not path.is_file():
        raise ValueError(f"artifact does not exist: {path}")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
    native = [name for name in names if name.endswith(".so")]
    if not native:
        raise ValueError(f"artifact contains no native .so files: {path}")
    expected = f"/{abi}/"
    misplaced = [name for name in native if expected not in f"/{name}"]
    if misplaced:
        raise ValueError(
            f"artifact contains native libraries outside {abi}: {misplaced[:5]}"
        )
    if not any(f"/{abi}/" in f"/{name}" for name in native):
        raise ValueError(f"artifact has no native libraries for {abi}: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--platform", choices=("android", "ohos"), required=True)
    parser.add_argument("--abi", required=True)
    args = parser.parse_args()
    if args.abi not in ANDROID_ABIS:
        parser.error(f"unsupported Android-family ABI: {args.abi}")
    verify_android_archive(args.artifact, args.abi)
    print(f"artifact ABI: OK ({args.platform}, {args.abi}, {args.artifact})")


if __name__ == "__main__":
    main()
