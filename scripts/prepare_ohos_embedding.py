#!/usr/bin/env python3
"""Apply the reviewed Flutter OHOS embedding patch set.

The framework compatibility patches and the OHOS embedding patches have
different ownership and lifecycles.  Keep the embedding source changes here
so a clean Flutter OHOS checkout can be prepared without relying on a dirty
developer checkout or inline shell substitutions.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


EXPECTED_FLUTTER_COMMIT = "aa76d9bbeee7806a87dbd202d2550dfd11550b82"
PRODUCTION_PATCH = Path("tool/ohos/flutter_embedding/ohos_hcpp_embedding.patch")
NATIVE_PATCH = Path("tool/ohos/flutter_embedding/ohos_hcpp_native.patch")
TEST_PATCH = Path("tool/ohos/flutter_embedding/ohos_hcpp_embedding_test.patch")


def git(root: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        check=check,
        text=True,
        capture_output=True,
    )


def apply_once(root: Path, patch: Path) -> str:
    forward = git(root, "apply", "--check", str(patch), check=False)
    if forward.returncode == 0:
        git(root, "apply", str(patch))
        return "applied"
    reverse = git(root, "apply", "--reverse", "--check", str(patch), check=False)
    if reverse.returncode == 0:
        return "already-applied"
    detail = forward.stderr.strip() or reverse.stderr.strip()
    raise SystemExit(f"OHOS embedding patch drift: {patch}\n{detail}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--flutter-root", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, default=Path.cwd())
    parser.add_argument("--include-native-source", action="store_true")
    parser.add_argument("--include-tests", action="store_true")
    parser.add_argument("--allow-unknown-commit", action="store_true")
    args = parser.parse_args()

    root = args.flutter_root.resolve()
    workspace = args.workspace.resolve()
    if not (root / ".git").is_dir():
        parser.error(f"Flutter root is not a git checkout: {root}")
    commit = git(root, "rev-parse", "HEAD").stdout.strip()
    if commit != EXPECTED_FLUTTER_COMMIT and not args.allow_unknown_commit:
        raise SystemExit(
            f"unexpected Flutter OHOS commit: {commit}; "
            f"expected {EXPECTED_FLUTTER_COMMIT}"
        )

    patches = [PRODUCTION_PATCH]
    if args.include_native_source:
        patches.append(NATIVE_PATCH)
    if args.include_tests:
        patches.append(TEST_PATCH)

    results = []
    for relative in patches:
        patch = workspace / relative
        if not patch.is_file():
            raise SystemExit(f"missing OHOS embedding patch: {patch}")
        results.append(f"{relative.name}={apply_once(root, patch)}")
    print(
        "OHOS embedding preparation: "
        f"commit={commit} "
        + " ".join(results)
    )


if __name__ == "__main__":
    main()
