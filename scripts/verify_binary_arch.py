#!/usr/bin/env python3
"""Fail closed when a native release executable has the wrong architecture."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


EXPECTED = {
    "linux": "ELF 64-bit",
    "windows": "PE32+",
    "ios": "Mach-O 64-bit",
    "macos": "Mach-O 64-bit",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--platform", choices=EXPECTED, required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    args = parser.parse_args()
    if not args.binary.is_file():
        parser.error(f"binary does not exist: {args.binary}")
    try:
        description = subprocess.check_output(
            ["file", "-b", str(args.binary)], text=True, stderr=subprocess.STDOUT
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        parser.error(f"unable to inspect binary: {error}")
    required = EXPECTED[args.platform]
    architecture = "x86-64" if args.arch == "x86_64" else "(aarch64|ARM aarch64|arm64)"
    import re
    if required not in description or not re.search(architecture, description):
        parser.error(
            f"wrong {args.platform} architecture: expected {required} {architecture}; "
            f"got {description}"
        )
    print(f"binary architecture: OK ({args.platform}, {args.arch})")


if __name__ == "__main__":
    main()
