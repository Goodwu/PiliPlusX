#!/usr/bin/env python3
"""Validate a real-device HDR evidence record before it is accepted."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REQUIRED = (
    "platform",
    "device",
    "displayMode",
    "systemColorSpace",
    "source",
    "playerLog",
    "hdrSdrRatio",
)
REQUIRED_SOURCE = ("primaries", "transfer", "matrix")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("record", type=Path)
    args = parser.parse_args()
    record = json.loads(args.record.read_text(encoding="utf-8"))
    failures = [key for key in REQUIRED if not record.get(key)]

    source = record.get("source")
    if not isinstance(source, dict):
        failures.append("source")
    else:
        failures.extend(
            f"source.{key}" for key in REQUIRED_SOURCE if not source.get(key)
        )

    ratio = record.get("hdrSdrRatio")
    if not isinstance(ratio, (int, float)) or ratio <= 1.0:
        failures.append("hdrSdrRatio (> 1.0 required)")

    if failures:
        raise SystemExit("HDR evidence verification failed:\n- " + "\n- ".join(failures))
    print(f"HDR evidence verified: {record['platform']} / {record['device']}")


if __name__ == "__main__":
    main()
