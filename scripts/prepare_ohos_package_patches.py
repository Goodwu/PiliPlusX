#!/usr/bin/env python3
"""Apply checked-in patches to packages whose APIs depend on the OHOS SDK fork."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlparse


def package_root(workspace: Path, package_name: str) -> Path:
    config = json.loads(
        (workspace / ".dart_tool/package_config.json").read_text(encoding="utf-8")
    )
    for package in config["packages"]:
        if package["name"] != package_name:
            continue
        uri = urlparse(package["rootUri"])
        if uri.scheme != "file":
            raise SystemExit(f"unsupported package root URI: {package['rootUri']}")
        return Path(unquote(uri.path)).resolve()
    raise SystemExit(f"package not found in package_config: {package_name}")


def apply_patch(root: Path, patch: Path) -> bool:
    check = subprocess.run(
        ["git", "-C", str(root), "apply", "--check", str(patch)],
        capture_output=True,
    )
    if check.returncode == 0:
        subprocess.run(["git", "-C", str(root), "apply", str(patch)], check=True)
        return True
    reverse = subprocess.run(
        ["git", "-C", str(root), "apply", "--reverse", "--check", str(patch)],
        capture_output=True,
    )
    if reverse.returncode == 0:
        return False
    raise SystemExit(
        f"OHOS package patch drift: {patch.name}\n"
        + check.stderr.decode(errors="replace")
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    package = package_root(workspace, "extended_nested_scroll_view")
    patch = workspace / "lib/scripts/extended_nested_scroll_view_pointer_filter.patch"
    applied = apply_patch(package, patch)
    print(
        "extended_nested_scroll_view pointer filter: "
        + ("applied" if applied else "already applied")
    )


if __name__ == "__main__":
    main()
