#!/usr/bin/env python3
"""Validate tags accepted by the public four-platform release workflow."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


TAG_RE = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)(?P<suffix>-[0-9A-Za-z][0-9A-Za-z.-]*)?$")


def classify(tag: str) -> tuple[str, bool]:
    match = TAG_RE.fullmatch(tag)
    if not match:
        raise ValueError(
            "release tag must be vMAJOR.MINOR.PATCH or a prerelease such as v1.2.3-rc.1"
        )
    return match.group("version"), match.group("suffix") is not None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    version, prerelease = classify(args.tag)
    output = f"tag={args.tag}\nversion={version}\nprerelease={'true' if prerelease else 'false'}\n"
    if args.github_output:
        args.github_output.write_text(output, encoding="utf-8")
    else:
        print(output, end="")


if __name__ == "__main__":
    main()
