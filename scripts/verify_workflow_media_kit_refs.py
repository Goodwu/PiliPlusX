#!/usr/bin/env python3
"""Ensure every release workflow uses the same immutable media-kit commit."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SHA_RE = r"[0-9a-f]{40}"
LOCK_RE = re.compile(
    rf"verify_media_kit_lock\.py\s+pubspec\.lock\s+--commit\s+({SHA_RE})"
)
MANIFEST_RE = re.compile(rf"--media-kit-commit\s+({SHA_RE})")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", required=True)
    parser.add_argument(
        "--workflow-dir", type=Path, default=Path(".github/workflows")
    )
    args = parser.parse_args()

    if not re.fullmatch(SHA_RE, args.commit):
        parser.error("--commit must be a full 40-character lowercase SHA")
    workflows = sorted(args.workflow_dir.glob("*.yml"))
    if not workflows:
        raise SystemExit(f"no workflow files found in {args.workflow_dir}")

    failures: list[str] = []
    lock_count = 0
    manifest_count = 0
    for workflow in workflows:
        text = workflow.read_text(encoding="utf-8")
        # Orchestrators only call reusable build workflows and therefore do
        # not resolve Dart packages themselves.
        if not re.search(r"(?:flutter pub get|flutter build|fastforge package)", text):
            continue
        lock_refs = LOCK_RE.findall(text)
        manifest_refs = MANIFEST_RE.findall(text)
        lock_count += len(lock_refs)
        manifest_count += len(manifest_refs)
        if not lock_refs:
            failures.append(f"{workflow}: no immutable lock verification reference")
        if any(ref != args.commit for ref in lock_refs):
            failures.append(f"{workflow}: lock verification references {lock_refs}")
        if any(ref != args.commit for ref in manifest_refs):
            failures.append(f"{workflow}: manifest references {manifest_refs}")

    if failures:
        raise SystemExit("workflow media-kit reference verification failed:\n" + "\n".join(failures))
    print(
        f"workflow media-kit references verified: {lock_count} lock checks, "
        f"{manifest_count} manifest references at {args.commit}"
    )


if __name__ == "__main__":
    main()
