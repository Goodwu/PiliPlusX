#!/usr/bin/env python3
"""Remove OHOS-only TargetPlatform cases from packages built by standard Flutter.

The release dependency graph deliberately uses the OHOS fork of
flutter_inappwebview.  Flutter's stock SDK has no ``TargetPlatform.ohos``
enum value, so those unreachable branches must be removed for Android, iOS,
and macOS release builds.  The OHOS workflow does not invoke this script.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from urllib.parse import unquote, urlparse


PACKAGE = "flutter_inappwebview_platform_interface"


def package_root(workspace: Path) -> Path:
    config = json.loads(
        (workspace / ".dart_tool/package_config.json").read_text(encoding="utf-8")
    )
    for package in config["packages"]:
        if package["name"] != PACKAGE:
            continue
        uri = urlparse(package["rootUri"])
        if uri.scheme != "file":
            raise SystemExit(f"unsupported package root URI: {package['rootUri']}")
        return Path(unquote(uri.path)).resolve()
    raise SystemExit(f"package not found in package_config: {PACKAGE}")


def remove_ohos_cases(text: str) -> tuple[str, int]:
    # A Dart case arm ends at the next case/default label.  OHOS is never
    # selected by a stock Flutter SDK, therefore dropping that arm preserves
    # every supported platform's behavior without aliasing it to Android.
    pattern = re.compile(
        r"(?m)^[ \t]*case TargetPlatform\.ohos:\n"
        r"[\s\S]*?(?=^[ \t]*(?:case TargetPlatform\.|default:)|\Z)"
    )
    text, removed = pattern.subn("", text)
    text, comparisons = re.subn(
        r"(?:!isWeb\s*&&\s*)?defaultTargetPlatform\s*==\s*TargetPlatform\.ohos",
        "false",
        text,
    )
    if "TargetPlatform.ohos" in text:
        raise SystemExit("unhandled TargetPlatform.ohos expression remains")
    return text, removed + comparisons


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    root = package_root(args.workspace.resolve())
    changed = 0
    for path in root.rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        if "TargetPlatform.ohos" not in text:
            continue
        patched, count = remove_ohos_cases(text)
        if count == 0:
            raise SystemExit(f"no OHOS compatibility changes applied to {path}")
        path.write_text(patched, encoding="utf-8")
        changed += count
    if changed == 0:
        raise SystemExit(f"no TargetPlatform.ohos references found in {root}")
    view = args.workspace.resolve() / "lib/pages/video/view.dart"
    source = view.read_text(encoding="utf-8")
    needle = "            pointerDownFilter: _allowOuterVideoPointer,\n"
    if needle not in source:
        raise SystemExit(f"standard Flutter pointer-filter call missing from {view}")
    view.write_text(source.replace(needle, "", 1), encoding="utf-8")
    print(f"standard Flutter package compatibility: removed {changed} OHOS references")


if __name__ == "__main__":
    main()
