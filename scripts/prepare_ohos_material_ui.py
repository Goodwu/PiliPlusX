#!/usr/bin/env python3
"""Apply the checked-in material_ui compatibility patches in the build cache."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import re
from pathlib import Path
from urllib.parse import urlparse


PATCHES = (
    "modal_barrier_material.patch",
    "navigation_drawer.patch",
    "popup_menu.patch",
    "fab.patch",
    "text_field.patch",
    "scaffold.patch",
    "refresh_indicator.patch",
    "tabs.patch",
    "bottom_sheet_android.patch",
)


def patch_target_platform_cases(package: Path) -> int:
    changed = 0
    for path in package.rglob("*.dart"):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        updated = text
        updated, n = re.subn(r"case TargetPlatform\.android:(?!\s*\n\s*case TargetPlatform\.ohos:)", "case TargetPlatform.android:\n      case TargetPlatform.ohos:", updated)
        changed += n
        updated, n = re.subn(r"TargetPlatform\.android\s*\|\|(?!\s*TargetPlatform\.ohos)", "TargetPlatform.android || TargetPlatform.ohos ||", updated)
        changed += n
        updated, n = re.subn(r"TargetPlatform\.android(?!\s*(?:\|\||:))\s+=>", "TargetPlatform.android || TargetPlatform.ohos =>", updated)
        changed += n
        if updated != text:
            path.write_text(updated, encoding="utf-8")
    return changed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, default=Path.cwd())
    args = parser.parse_args()
    cache = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))
    candidates = sorted((cache / "hosted/pub.dev").glob("material_ui-*/"))
    package_config = args.workspace / ".dart_tool/package_config.json"
    if package_config.is_file():
        config = json.loads(package_config.read_text(encoding="utf-8"))
        root_uri = next(
            (item.get("rootUri") for item in config.get("packages", []) if item.get("name") == "material_ui"),
            None,
        )
        if root_uri:
            selected = Path(urlparse(root_uri).path).resolve()
            if selected.is_dir():
                candidates = [selected]
    if not candidates:
        parser.error(f"material_ui package not found under {cache}")
    package = candidates[-1]
    applied = 0
    for name in PATCHES:
        patch = args.workspace / "lib/scripts/material" / name
        check = subprocess.run(["git", "-C", str(package), "apply", "--check", str(patch)], capture_output=True)
        if check.returncode == 0:
            subprocess.run(["git", "-C", str(package), "apply", str(patch)], check=True)
            applied += 1
        else:
            reverse = subprocess.run(["git", "-C", str(package), "apply", "--reverse", "--check", str(patch)], capture_output=True)
            if reverse.returncode != 0:
                raise SystemExit(f"material_ui patch drift: {name}\n{check.stderr.decode(errors='replace')}")
    cases = patch_target_platform_cases(package)
    cupertino = package.parent / "cupertino_ui-1.0.1"
    if cupertino.is_dir():
        cases += patch_target_platform_cases(cupertino)
    # The app vendors a few Flutter widgets; apply the same build-copy-only
    # platform normalization to those sources as well.
    if (args.workspace / "lib").is_dir():
        cases += patch_target_platform_cases(args.workspace / "lib")
    print(f"OHOS material_ui compatibility patches: {applied}/{len(PATCHES)} applied; TargetPlatform cases: {cases}")


if __name__ == "__main__":
    main()
