#!/usr/bin/env python3
"""Fail closed if any media-kit package resolves outside the pinned fork SHA."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


PACKAGE_RE = re.compile(r"^  (media_kit(?:[^:]*)):\n((?:    .*\n|\n)*)", re.MULTILINE)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("lockfile", type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--url", default="https://github.com/Goodwu/media-kit.git")
    args = parser.parse_args()

    text = args.lockfile.read_text(encoding="utf-8")
    matches = list(PACKAGE_RE.finditer(text))
    if not matches:
        raise SystemExit("no media-kit packages found in lockfile")

    failures: list[str] = []
    for match in matches:
        name, body = match.group(1), match.group(2)
        if "    source: git\n" not in body:
            failures.append(f"{name}: source is not git")
            continue
        resolved = re.search(r"^      resolved-ref: (.+)$", body, re.MULTILINE)
        url = re.search(r'^      url: "([^"]+)"$', body, re.MULTILINE)
        resolved_value = (
            resolved.group(1).strip().strip('"').strip("'")
            if resolved
            else None
        )
        if not resolved or resolved_value != args.commit:
            failures.append(f"{name}: resolved-ref is not {args.commit}")
        if not url or url.group(1) != args.url:
            failures.append(f"{name}: url is not {args.url}")

    if failures:
        raise SystemExit("media-kit lock verification failed:\n" + "\n".join(failures))
    print(f"media-kit lock verified: {len(matches)} packages at {args.commit}")


if __name__ == "__main__":
    main()
