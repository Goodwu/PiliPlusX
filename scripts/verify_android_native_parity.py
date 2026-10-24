#!/usr/bin/env python3
"""Verify that Android and Pink APKs ship identical arm64 native libraries."""

from __future__ import annotations

import argparse
import hashlib
import zipfile


def native_hashes(apk: str) -> dict[str, str]:
    with zipfile.ZipFile(apk) as archive:
        entries = {
            name: hashlib.sha256(archive.read(name)).hexdigest()
            for name in archive.namelist()
            if name.startswith("lib/arm64-v8a/") and name.endswith(".so")
        }
    if not entries:
        raise ValueError(f"no arm64 native libraries found in {apk}")
    return entries


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("android_apk")
    parser.add_argument("pink_apk")
    args = parser.parse_args()
    android = native_hashes(args.android_apk)
    pink = native_hashes(args.pink_apk)
    if android != pink:
        android_only = sorted(set(android) - set(pink))
        pink_only = sorted(set(pink) - set(android))
        changed = sorted(name for name in set(android) & set(pink) if android[name] != pink[name])
        raise SystemExit(
            "Android/Pink native libraries differ: "
            f"android-only={android_only}, pink-only={pink_only}, changed={changed}"
        )
    print(f"Android/Pink arm64 native parity verified: {len(android)} files")


if __name__ == "__main__":
    main()
