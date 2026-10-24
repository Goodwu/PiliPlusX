#!/usr/bin/env python3
"""Derive Xcode's Runner Info.plist input for legacy or bootstrap builds."""

from __future__ import annotations

import os
from pathlib import Path
import plistlib
import sys
import tempfile


PENDING_KEY = "MediaKitSharedBootstrapPending"
MODES = {"legacy", "shared-candidate-bootstrap"}


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"FAIL: {message}")


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        if path.is_symlink():
            fail(f"{label} must not be a symlink: {path}")
        info = path.stat()
    except OSError as error:
        fail(f"cannot stat {label} {path}: {error}")
    if not path.is_file():
        fail(f"{label} must be a regular file: {path}")
    return info


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        fail("usage: prepare_macos_bundle_info.py SOURCE OUTPUT")
    source, output = Path(argv[1]), Path(argv[2])
    mode = os.environ.get("PILIPLUSX_MPV_BUNDLE_MODE", "legacy")
    if mode not in MODES:
        fail(f"unknown PILIPLUSX_MPV_BUNDLE_MODE: {mode!r}")

    source_stat = regular_file(source, "source plist")
    if output.exists() or output.is_symlink():
        regular_file(output, "derived plist")
    if source.resolve() == output.resolve():
        fail("source and derived plist must be different files")
    if output.exists():
        output_stat = output.stat()
        if (source_stat.st_dev, source_stat.st_ino) == (output_stat.st_dev, output_stat.st_ino):
            fail("source and derived plist refer to the same file")

    try:
        values = plistlib.loads(source.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        fail(f"cannot parse source plist: {error}")
    if not isinstance(values, dict):
        fail("source plist top level must be a dictionary")
    if PENDING_KEY in values:
        fail(f"source plist contains reserved key {PENDING_KEY}")

    derived = dict(values)
    if mode == "shared-candidate-bootstrap":
        derived[PENDING_KEY] = True
    payload = plistlib.dumps(derived, fmt=plistlib.FMT_XML, sort_keys=True)
    if output.exists() and output.read_bytes() == payload:
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    current_mode = output.stat().st_mode & 0o777 if output.exists() else 0o644
    fd, temporary_name = tempfile.mkstemp(prefix=".PiliPlusX-BundleInfo-", dir=output.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, current_mode)
        os.replace(temporary, output)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
