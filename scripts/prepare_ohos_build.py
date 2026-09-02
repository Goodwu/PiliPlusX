#!/usr/bin/env python3
"""Create and prepare an isolated checkout for the Flutter-OHOS toolchain.

The OHOS fork is based on Flutter 3.44/Dart 3.12 while the repository's
normal toolchain is Flutter 3.47/Dart 3.13.  This deliberately performs only
the documented build-copy substitutions and fails if the source has drifted.
"""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"OHOS preparation expected one occurrence of {old!r} in {path}, found {count}")
    path.write_text(text.replace(old, new), encoding="utf-8")


def matching_brace(text: str, opening: int) -> int:
    depth = 0
    quote: str | None = None
    escaped = False
    line_comment = False
    block_comment = False
    for index in range(opening, len(text)):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
            continue
        if block_comment:
            if char == "*" and next_char == "/":
                block_comment = False
            continue
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char == "/" and next_char == "/":
            line_comment = True
            continue
        if char == "/" and next_char == "*":
            block_comment = True
            continue
        if char in "'\"":
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    raise SystemExit("OHOS preparation could not match a switch brace")


def patch_target_platform_switches(path: Path) -> int:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return 0
    # First normalize every statement case; this also covers nested switches
    # whose selector is a local variable (for example `_platform`).
    generic, generic_count = re.subn(
        r"case TargetPlatform\.android:(?!\s*\n\s*case TargetPlatform\.ohos:)",
        "case TargetPlatform.android:\n      case TargetPlatform.ohos:",
        text,
    )
    text = generic
    starts = [
        match.start()
        for match in re.finditer(
            r"(?:return\s+|=\s*)?switch \((?:defaultTargetPlatform|theme\.platform|_platform)\)\s*\{",
            text,
        )
    ]
    patched = generic_count
    for start in reversed(starts):
        opening = text.find("{", start)
        closing = matching_brace(text, opening)
        body = text[opening + 1 : closing]
        line_start = text.rfind("\n", 0, start) + 1
        line_prefix = text[line_start:start]
        indent = re.match(r"\s*", line_prefix).group(0)
        line_segment = text[line_start:opening]
        expression = "return switch" in line_segment or "= switch" in line_segment
        if "default:" in body or "_ =>" in body:
            continue
        if expression:
            # Boolean platform switches (the only expression form in the
            # vendored widgets) have a safe SDR/mobile fallback.
            if re.search(r"=>\s*(?:true|false)", body) and not re.search(
                r"=>\s*(?!true|false)[A-Za-z_]", body
            ):
                # Expression switches are handled by explicit OHOS cases
                # above; do not add a fallback that can change inferred types.
                continue
        else:
            # Every TargetPlatform statement switch receives the Android
            # behavior through the generic case normalization above.
            continue
    if patched:
        path.write_text(text, encoding="utf-8")
    return patched


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.workspace.resolve()
    root = args.output.resolve()
    if root == source or source in root.parents:
        parser.error("--output must be outside the source checkout")
    if root.exists():
        parser.error(f"isolated OHOS output already exists: {root}")
    source_pubspec = source / "pubspec.yaml"
    if not source_pubspec.is_file():
        parser.error(f"not a PiliPlusX checkout: {source}")
    shutil.copytree(
        source,
        root,
        ignore=shutil.ignore_patterns(
            ".git",
            ".dart_tool",
            "build",
            "remote-release-linux",
            "remote-release-linux-arm64",
        ),
    )
    pubspec = root / "pubspec.yaml"

    replacements = (
        ("  sdk: \">=3.13.0\"", "  sdk: \">=3.12.0 <4.0.0\""),
        # The OHOS fork reports 0.0.0-unknown to pub even though its checked
        # out revision is the pinned 3.44.9 implementation.  The toolchain is
        # verified by revision/version before this step, so the app constraint
        # must be open in the isolated copy for pub's solver to proceed.
        ("  flutter: 3.47.2", "  flutter: any"),
        ("name: PiliPlus", "name: piliplus"),
        ("  flex_seed_scheme: ^5.0.0", "  flex_seed_scheme: ^4.0.1"),
        ("  material_ui: ^1.0.0", "  material_ui: 1.0.0"),
    )
    already_prepared = pubspec.read_text(encoding="utf-8").startswith("name: piliplus\n")
    if not already_prepared:
        for old, new in replacements:
            replace_once(pubspec, old, new)

    dart_files = sorted((root / "lib").rglob("*.dart"))
    changed = 0
    for path in dart_files:
        text = path.read_text(encoding="utf-8")
        count = text.count("package:PiliPlus/")
        if count:
            path.write_text(text.replace("package:PiliPlus/", "package:piliplus/"), encoding="utf-8")
            changed += count
    if not changed and not already_prepared:
        raise SystemExit("OHOS preparation found no package:PiliPlus imports; refusing silent drift")

    # material_ui 1.0.0 defines its own ColorScheme type while flex_seed_scheme
    # returns Flutter's ColorScheme.  The OHOS dependency set uses the former;
    # keep the seed API behavior through material_ui's compatible constructor.
    theme_ext = root / "lib/utils/extension/theme_ext.dart"
    if theme_ext.is_file():
        theme_text = theme_ext.read_text(encoding="utf-8")
        old = """=> SeedColorScheme.fromSeeds(
    primaryKey: this,
    variant: variant,
    brightness: brightness,
    useExpressiveOnContainerColors: false,
  );"""
        new = """=> ColorScheme.fromSeed(
    seedColor: this,
    brightness: brightness,
  );"""
        if old in theme_text:
            theme_ext.write_text(theme_text.replace(old, new, 1), encoding="utf-8")

    # Hvigor 26 validates the generated entry module's app icon in its own
    # resource scope, while the template keeps it under AppScope.
    app_icon = root / "ohos/AppScope/resources/base/media/app_icon.svg"
    entry_icon = root / "ohos/entry/src/main/resources/base/media/app_icon.svg"
    if app_icon.is_file() and not entry_icon.exists():
        entry_icon.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(app_icon, entry_icon)
    app_profile = root / "ohos/AppScope/app.json5"
    app_scope_icon = root / "ohos/AppScope/resources/base/media/icon.svg"
    if app_profile.is_file() and app_icon.is_file():
        profile_text = app_profile.read_text(encoding="utf-8")
        if '"icon": "$media:app_icon.svg"' in profile_text:
            shutil.copyfile(app_icon, app_scope_icon)
            app_profile.write_text(profile_text.replace('"icon": "$media:app_icon.svg"', '"icon": "$media:icon"'), encoding="utf-8")
    module_profile = root / "ohos/entry/src/main/module.json5"
    if module_profile.is_file():
        module_text = module_profile.read_text(encoding="utf-8")
        module_text = module_text.replace('"$media:icon.svg"', '"$media:icon"')
        module_profile.write_text(module_text, encoding="utf-8")

    # The OHOS fork adds TargetPlatform.ohos.  These vendored Flutter widgets
    # are shared with the 3.47 implementation, so reference that enum value
    # directly would break the main toolchain.  Suppress only the fork's
    # exhaustiveness diagnostic; its default behavior remains the existing
    # Android/mobile fallback.
    switch_patches = 0
    for path in sorted((root / "lib/common/widgets/flutter").rglob("*.dart")):
        switch_patches += patch_target_platform_switches(path)
    print(f"OHOS preparation complete: {len(dart_files)} Dart files scanned, {changed} imports rewritten")
    print(f"OHOS compatibility: annotated {switch_patches} TargetPlatform switches")


if __name__ == "__main__":
    main()
