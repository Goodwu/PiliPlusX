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


# The OHOS build cache is intentionally pinned to the media-kit revision that
# is already provisioned on the build host.  The normal checkout may move to
# a newer/private revision that is not available to the older OHOS pub fork.
OHOS_MEDIA_KIT_REF = "0dd1535ec622c0e8560551b15800c75c3a07da95"


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
    parser.add_argument(
        "--media-kit-source",
        type=Path,
        help="Use the synchronized local media-kit checkout for the OHOS HDR bridge.",
    )
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
            ".symlinks",
            "ephemeral",
            "remote-release-linux",
            "remote-release-linux-arm64",
            # Local agent instructions can be ignored symlinks into a user's
            # private configuration directory.  rsync preserves that link
            # for remote builds, where its target does not exist; copytree's
            # default symlink-following would then make a code build fail.
            # They are not runtime/build inputs for the isolated OHOS tree.
            "AGENTS.md",
        ),
    )
    # This is a developer-local media-kit path override.  It is deliberately
    # not part of the reproducible OHOS dependency graph.
    local_overrides = root / "pubspec_overrides.yaml"
    if local_overrides.exists():
        local_overrides.unlink()
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

    # The Windows override is useful to the desktop build, but it makes the
    # OHOS Dart 3.12 solver require a non-existent desktop path.  OHOS uses
    # the universal and OHOS media-kit packages only.
    pubspec_text = pubspec.read_text(encoding="utf-8")
    for package in ("media_kit_libs_windows_video", "media_kit_libs_video"):
        pubspec_text, removed = re.subn(
            rf"\n  {package}:\n(?: {{4,}}.*\n)*",
            "\n",
            pubspec_text,
        )
        if removed != 1:
            raise SystemExit(
                f"OHOS preparation expected one {package} entry, found {removed}"
            )
    pubspec_text, removed = re.subn(
        r"\n  media_kit_libs_video: 1\.0\.5\n",
        "\n",
        pubspec_text,
    )
    if removed != 1:
        raise SystemExit(
            "OHOS preparation expected one direct media_kit_libs_video dependency, "
            f"found {removed}"
        )
    pubspec_text = pubspec_text.replace(
        "ref: 0fa6afe9cd9af8d8437919257d81a27c643f2f63",
        f"ref: {OHOS_MEDIA_KIT_REF}",
    )
    if args.media_kit_source is not None:
        media_kit_source = args.media_kit_source.resolve()
        required_media_kit_paths = {
            "media_kit": media_kit_source / "media_kit",
            "media_kit_video": media_kit_source / "media_kit_video",
            "media_kit_libs_ohos": media_kit_source / "libs/ohos/media_kit_libs_ohos",
        }
        missing = [str(path) for path in required_media_kit_paths.values() if not path.is_dir()]
        if missing:
            raise SystemExit(f"media-kit source is incomplete: {', '.join(missing)}")
        for package, path in required_media_kit_paths.items():
            pattern = rf"  {package}:\n    git:\n(?:      .*\n)+"
            replacement = f"  {package}:\n    path: {path}\n"
            pubspec_text, replaced = re.subn(pattern, replacement, pubspec_text)
            if replaced != 1:
                raise SystemExit(
                    f"OHOS preparation expected one git override for {package}, found {replaced}"
                )
        ohos_platform_view = (
            media_kit_source
            / "media_kit_video/lib/src/video/platform_view_video_ohos.dart"
        )
        ohos_platform_view_target = (
            required_media_kit_paths["media_kit_video"]
            / "lib/src/video/platform_view_video.dart"
        )
        if not ohos_platform_view.is_file():
            raise SystemExit(
                f"OHOS preparation requires the OHOS platform view source: {ohos_platform_view}"
            )
        shutil.copy2(ohos_platform_view, ohos_platform_view_target)
        print(
            "OHOS preparation: selected media-kit OHOS platform view implementation",
            flush=True,
        )
    pubspec.write_text(pubspec_text, encoding="utf-8")

    # The OHOS build uses the synchronized media-kit source. Keep the
    # native-surface configuration because OHOS now consumes that API. The
    # initial stale candidate, a stale rebuild candidate, and the current
    # output handoff must each retain a real asynchronous disposeForRebuild
    # barrier; never replace any of them with the synchronous dispose
    # compatibility path.
    controller = root / "lib/plugin/pl_player/controller.dart"
    if controller.is_file():
        controller_text = controller.read_text(encoding="utf-8")
        dispose_barriers = re.findall(
            r"await platform\.disposeForRebuild\(\);",
            controller_text,
        )
        if len(dispose_barriers) != 3 or "await Future<void>.sync(platform.dispose);" in controller_text:
            raise SystemExit(
                "OHOS preparation expected exactly three real media-kit async "
                "disposeForRebuild barrier and no synchronous dispose bypass, "
                f"found {len(dispose_barriers)} barrier(s)"
            )

    # The isolated package name is lowercase. Rewrite both production and
    # checked-in regression-test imports so `flutter test` resolves the same
    # local package graph as `flutter build hap`.
    dart_files = sorted(
        path
        for directory in (root / "lib", root / "test")
        if directory.is_dir()
        for path in directory.rglob("*.dart")
    )
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
    root_build_profile = root / "ohos/build-profile.json5"
    legacy_build_profile = root / "ohos/关于build-profile.json5"
    if not root_build_profile.exists() and legacy_build_profile.is_file():
        shutil.copyfile(legacy_build_profile, root_build_profile)

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
