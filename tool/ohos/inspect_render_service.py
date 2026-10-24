#!/usr/bin/env python3
"""Extract the video surface color contract from an OHOS RenderService dump."""

import argparse
import json
import re
import sys
from pathlib import Path


SURFACE_RE = re.compile(
    r"Name \[(?P<name>[^]]+)\].*?colorSpace: (?P<color_space>\d+)"
    r"(?:, uifirstColorGamut: (?P<gamut>\d+))?"
)
BUFFER_RE = re.compile(
    r"default-size = \[(?P<width>\d+)x(?P<height>\d+)\].*?"
    r"name = (?P<name>[^,]+), uniqueId = (?P<unique_id>\d+)"
)
BUFFER_DETAIL_RE = re.compile(
    r"config = \[(?P<width>\d+)x(?P<height>\d+),.*?\]"
    r".*?\[metadataType: (?P<metadata_type>\d+)\]"
    r".*?bufferWith = (?P<buffer_width>\d+), bufferHeight = (?P<buffer_height>\d+)"
)


def inspect(path: Path, surface_name: str) -> dict:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    surface = None
    for line in lines:
        match = SURFACE_RE.search(line)
        if match and match.group("name") == surface_name:
            surface = {
                "name": surface_name,
                "color_space": int(match.group("color_space")),
                "uifirst_color_gamut": (
                    int(match.group("gamut")) if match.group("gamut") else None
                ),
            }

    if surface is None:
        raise ValueError(f"surface not found: {surface_name}")

    for index, line in enumerate(lines):
        match = BUFFER_RE.search(line)
        if not match or match.group("name") != surface_name:
            continue
        surface["unique_id"] = int(match.group("unique_id"))
        surface["default_width"] = int(match.group("width"))
        surface["default_height"] = int(match.group("height"))
        for detail in lines[index + 1 : index + 8]:
            detail_match = BUFFER_DETAIL_RE.search(detail)
            if detail_match:
                surface["buffer_width"] = int(detail_match.group("buffer_width"))
                surface["buffer_height"] = int(detail_match.group("buffer_height"))
                surface["metadata_type"] = int(detail_match.group("metadata_type"))
                break
        break
    return surface


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--surface-name", default="media_kit_ohos_native_surface_0Surface")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument(
        "--reset-on-identity-change",
        action="store_true",
        help="start a new baseline when RenderService assigns a new surface id",
    )
    parser.add_argument(
        "--expected-color-space",
        type=int,
        help="fail when the observed video surface color space is not this value",
    )
    args = parser.parse_args()

    try:
        current = inspect(args.snapshot, args.surface_name)
    except (OSError, ValueError) as error:
        print(f"render-service inspection failed: {error}", file=sys.stderr)
        return 2

    if args.expected_color_space is not None and current["color_space"] != args.expected_color_space:
        print(json.dumps({**current, "expected_color_space": args.expected_color_space}, sort_keys=True))
        return 1

    if args.baseline and args.baseline.exists():
        try:
            baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"invalid render-service baseline: {error}", file=sys.stderr)
            return 2
        if (
            current.get("unique_id") is not None
            and baseline.get("unique_id") is not None
            and current["unique_id"] != baseline["unique_id"]
        ):
            if not args.reset_on_identity_change:
                print(json.dumps({**current, "baseline_identity_changed": True}, sort_keys=True))
                return 3
            args.baseline.write_text(
                json.dumps(current, sort_keys=True, indent=2) + "\n", encoding="utf-8"
            )
            current["baseline_color_space"] = current["color_space"]
            current["baseline_identity_changed"] = True
            print(json.dumps(current, sort_keys=True))
            return 0
        current["baseline_color_space"] = baseline["color_space"]
        if current["color_space"] != baseline["color_space"]:
            print(json.dumps(current, sort_keys=True))
            return 1
    elif args.baseline:
        args.baseline.write_text(
            json.dumps(current, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
        current["baseline_color_space"] = current["color_space"]

    print(json.dumps(current, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
