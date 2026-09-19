#!/usr/bin/env python3
"""Apply the repository's source-level Flutter patches to the OHOS SDK copy."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


PATCHES = (
    "modal_barrier.patch",
    "mouse_cursor.patch",
    "image_anim.patch",
    "layout_builder.patch",
    "navigation_drawer.patch",
    "popup_menu.patch",
    "fab.patch",
    "editable_text.patch",
    "text_field.patch",
    "scroll_position.patch",
    "scrollable.patch",
    "draggable_scrollable_sheet.patch",
    "scaffold.patch",
    "text.patch",
    "text_painter.patch",
    "sliver.patch",
    "refresh_indicator.patch",
)


def apply_selective_patch(root: Path, patch: Path, include: str) -> bool:
    check = subprocess.run(["git", "-C", str(root), "apply", "--check", f"--include={include}", str(patch)], capture_output=True)
    if check.returncode == 0:
        subprocess.run(["git", "-C", str(root), "apply", f"--include={include}", str(patch)], check=True)
        return True
    reverse = subprocess.run(["git", "-C", str(root), "apply", "--reverse", "--check", f"--include={include}", str(patch)], capture_output=True)
    if reverse.returncode == 0:
        return False
    raise SystemExit(f"OHOS selective Flutter patch drift: {include}\n{check.stderr.decode(errors='replace')}")


def patch_page_view(root: Path) -> None:
    path = root / "packages/flutter/lib/src/widgets/page_view.dart"
    text = path.read_text(encoding="utf-8")
    if "final ValueGetter<HorizontalDragGestureRecognizer> horizontalDragGestureRecognizer;" in text:
        return
    text = text.replace(
        "import 'package:flutter/foundation.dart' show clampDouble, precisionErrorTolerance;",
        "import 'package:flutter/foundation.dart' show clampDouble, precisionErrorTolerance, ValueGetter;",
    )
    text = text.replace(
        "import 'package:flutter/gestures.dart' show DragStartBehavior;",
        "import 'package:flutter/gestures.dart' show DragStartBehavior, HorizontalDragGestureRecognizer;",
    )
    text = text.replace(
        "    this.padEnds = true,\n  }) : assert(",
        "    this.padEnds = true,\n    this.horizontalDragGestureRecognizer = HorizontalDragGestureRecognizer.new,\n  }) : assert(",
    )
    marker = "  /// {@template flutter.widgets.PageView.allowImplicitScrolling}"
    text = text.replace(
        marker,
        "  final ValueGetter<HorizontalDragGestureRecognizer> horizontalDragGestureRecognizer;\n\n" + marker,
        1,
    )
    path.write_text(text, encoding="utf-8")


def patch_raw_text(root: Path) -> None:
    """Expose the newer rawText parameter used by the app's rich text spans."""
    inline = root / "packages/flutter/lib/src/painting/inline_span.dart"
    text = inline.read_text(encoding="utf-8")
    if "final String? rawText;" not in text:
        text = text.replace("const InlineSpan({this.style});", "const InlineSpan({this.style, this.rawText});")
        text = text.replace("  final TextStyle? style;", "  final TextStyle? style;\n\n  final String? rawText;")
        inline.write_text(text, encoding="utf-8")
    placeholder = root / "packages/flutter/lib/src/painting/placeholder_span.dart"
    text = placeholder.read_text(encoding="utf-8")
    if "super.rawText" not in text:
        text = text.replace("    super.style,\n  });", "    super.style,\n    super.rawText,\n  });", 1)
        placeholder.write_text(text, encoding="utf-8")
    widget = root / "packages/flutter/lib/src/widgets/widget_span.dart"
    text = widget.read_text(encoding="utf-8")
    if "super.rawText" not in text:
        text = text.replace("super.baseline, super.style})", "super.baseline, super.style, super.rawText})", 1)
        widget.write_text(text, encoding="utf-8")


def patch_target_platform_cases(root: Path) -> int:
    """Make OHOS select the existing Android/mobile behavior in build copy."""
    changed = 0
    for path in root.rglob("*.dart"):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        updated = re.sub(
            r"TargetPlatform\.android(?!\s*\|\|\s*TargetPlatform\.ohos)(?=(?:\s*\|\|\s*TargetPlatform\.\w+)*\s*=>)",
            "TargetPlatform.android || TargetPlatform.ohos",
            text,
        )
        updated, n = re.subn(
            r"case TargetPlatform\.android:(?!\s*\n\s*case TargetPlatform\.ohos:)",
            "case TargetPlatform.android:\n        case TargetPlatform.ohos:",
            updated,
        )
        changed += n
        if updated != text:
            path.write_text(updated, encoding="utf-8")
    return changed


def apply_patch(root: Path, patch: Path) -> bool:
    check = subprocess.run(["git", "-C", str(root), "apply", "--check", str(patch)], capture_output=True)
    if check.returncode == 0:
        subprocess.run(["git", "-C", str(root), "apply", str(patch)], check=True)
        return True
    reverse = subprocess.run(["git", "-C", str(root), "apply", "--reverse", "--check", str(patch)], capture_output=True)
    if reverse.returncode == 0:
        return False
    raise SystemExit(f"OHOS Flutter patch drift: {patch.name}\n{check.stderr.decode(errors='replace')}")


def patch_pointer_filter(root: Path) -> int:
    scrollable = root / "packages/flutter/lib/src/widgets/scrollable.dart"
    scrollable_text = scrollable.read_text(encoding="utf-8")
    scrollable_markers = (
        "this.pointerDownFilter,",
        "final bool Function(PointerDownEvent event)? pointerDownFilter;",
        "_FilteredVerticalDragGestureRecognizer:",
        "..pointerDownFilter = widget.pointerDownFilter",
        "class _FilteredVerticalDragGestureRecognizer",
    )
    scrollable_marker_state = [marker in scrollable_text for marker in scrollable_markers]
    custom_markers = (
        "this.pointerDownFilter,",
        "final bool Function(PointerDownEvent event)? pointerDownFilter;",
        "_VerticalDragGestureRecognizer:",
        "..pointerDownFilter = widget.pointerDownFilter",
        "typedef PointerDownFilter = bool Function(PointerDownEvent event);",
        "PointerDownFilter? pointerDownFilter;",
    )
    custom_marker_state = [marker in scrollable_text for marker in custom_markers]
    custom_applied = all(custom_marker_state)
    if custom_applied or all(scrollable_marker_state):
        scrollable_changed = False
    elif "_VerticalDragGestureRecognizer:" in scrollable_text and not any(scrollable_marker_state):
        custom_expected = (
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n  }) : assert(semanticChildCount == null || semanticChildCount >= 0);",
            "  /// {@template flutter.widgets.Scrollable.axisDirection}",
            "                      ..isDyAllowed = _isDyAllowed",
            "typedef IsDyAllowed = bool Function(double dy);",
            "  IsDyAllowed? isDyAllowed;",
            "  bool isPointerAllowed(PointerEvent event) {",
        )
        for expected in custom_expected:
            if scrollable_text.count(expected) != 1:
                raise SystemExit("OHOS Flutter pointer filter source drift in custom scrollable.dart")
        scrollable_text = scrollable_text.replace(
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n  }) : assert(semanticChildCount == null || semanticChildCount >= 0);",
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n    this.pointerDownFilter,\n  }) : assert(semanticChildCount == null || semanticChildCount >= 0);",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "  /// {@template flutter.widgets.Scrollable.axisDirection}",
            "  /// Optional admission filter for the vertical drag recognizer.\n  final bool Function(PointerDownEvent event)? pointerDownFilter;\n\n  /// {@template flutter.widgets.Scrollable.axisDirection}",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "                      ..isDyAllowed = _isDyAllowed",
            "                      ..isDyAllowed = _isDyAllowed\n                      ..pointerDownFilter = widget.pointerDownFilter",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "typedef IsDyAllowed = bool Function(double dy);",
            "typedef IsDyAllowed = bool Function(double dy);\ntypedef PointerDownFilter = bool Function(PointerDownEvent event);",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "  IsDyAllowed? isDyAllowed;",
            "  IsDyAllowed? isDyAllowed;\n  PointerDownFilter? pointerDownFilter;",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "  bool isPointerAllowed(PointerEvent event) {",
            "  bool isPointerAllowed(PointerEvent event) {\n    if (event is PointerDownEvent &&\n        pointerDownFilter?.call(event) == false) {\n      return false;\n    }",
            1,
        )
        scrollable.write_text(scrollable_text, encoding="utf-8")
        scrollable_changed = True
    elif any(custom_marker_state) or (any(scrollable_marker_state) and not all(scrollable_marker_state)):
        raise SystemExit("OHOS Flutter pointer filter is partially applied to scrollable.dart")
    else:
        scrollable_expected = (
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n  }) : assert(semanticChildCount == null || semanticChildCount >= 0);",
            "  /// {@template flutter.widgets.Scrollable.axisDirection}",
            "            VerticalDragGestureRecognizer:\n                GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(\n                  () => VerticalDragGestureRecognizer(supportedDevices: _configuration.dragDevices),\n                  (VerticalDragGestureRecognizer instance) {",
            "            VerticalDragGestureRecognizer:\n                GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(\n                  () => VerticalDragGestureRecognizer(supportedDevices: _configuration.dragDevices),\n                  (VerticalDragGestureRecognizer instance) {\n                    instance\n                      ..onDown = _handleDragDown",
        )
        for expected in scrollable_expected:
            if scrollable_text.count(expected) != 1:
                raise SystemExit("OHOS Flutter pointer filter source drift in scrollable.dart")
        scrollable_text = scrollable_text.replace(
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n  }) : assert(semanticChildCount == null || semanticChildCount >= 0);",
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n    this.pointerDownFilter,\n  }) : assert(semanticChildCount == null || semanticChildCount >= 0);",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "  /// {@template flutter.widgets.Scrollable.axisDirection}",
            "  /// Optional admission filter for the vertical drag recognizer.\n  final bool Function(PointerDownEvent event)? pointerDownFilter;\n\n  /// {@template flutter.widgets.Scrollable.axisDirection}",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "            VerticalDragGestureRecognizer:\n                GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(\n                  () => VerticalDragGestureRecognizer(supportedDevices: _configuration.dragDevices),\n                  (VerticalDragGestureRecognizer instance) {",
            "            _FilteredVerticalDragGestureRecognizer:\n                GestureRecognizerFactoryWithHandlers<_FilteredVerticalDragGestureRecognizer>(\n                  () => _FilteredVerticalDragGestureRecognizer(supportedDevices: _configuration.dragDevices),\n                  (_FilteredVerticalDragGestureRecognizer instance) {",
            1,
        )
        scrollable_text = scrollable_text.replace(
            "                  (_FilteredVerticalDragGestureRecognizer instance) {\n                    instance\n                      ..onDown = _handleDragDown",
            "                  (_FilteredVerticalDragGestureRecognizer instance) {\n                    instance\n                      ..pointerDownFilter = widget.pointerDownFilter\n                      ..onDown = _handleDragDown",
            1,
        )
        scrollable_text += """\n\ntypedef PointerDownFilter = bool Function(PointerDownEvent event);\n\nclass _FilteredVerticalDragGestureRecognizer extends VerticalDragGestureRecognizer {\n  _FilteredVerticalDragGestureRecognizer({\n    super.debugOwner,\n    super.supportedDevices,\n    super.allowedButtonsFilter,\n  });\n\n  PointerDownFilter? pointerDownFilter;\n\n  @override\n  bool isPointerAllowed(PointerEvent event) {\n    if (event is PointerDownEvent &&\n        pointerDownFilter?.call(event) == false) {\n      return false;\n    }\n    return super.isPointerAllowed(event);\n  }\n}\n"""
        if not all(marker in scrollable_text for marker in scrollable_markers):
            raise SystemExit("OHOS Flutter pointer filter transformation incomplete for scrollable.dart")
        scrollable.write_text(scrollable_text, encoding="utf-8")
        scrollable_changed = True

    scroll_view = root / "packages/flutter/lib/src/widgets/scroll_view.dart"
    scroll_view_text = scroll_view.read_text(encoding="utf-8")
    scroll_view_markers = (
        "this.pointerDownFilter,",
        "final bool Function(PointerDownEvent event)? pointerDownFilter;",
        "pointerDownFilter: pointerDownFilter,",
        "super.pointerDownFilter,",
    )
    scroll_view_marker_state = [marker in scroll_view_text for marker in scroll_view_markers]
    if any(scroll_view_marker_state) and not all(scroll_view_marker_state):
        raise SystemExit("OHOS Flutter pointer filter is partially applied to scroll_view.dart")
    if all(scroll_view_marker_state):
        scroll_view_changed = False
    else:
        scroll_view_expected = (
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n  }) : assert(",
            "  /// Returns the [AxisDirection] in which the scroll view scrolls.",
            "      hitTestBehavior: hitTestBehavior,\n      viewportBuilder:",
            "    super.hitTestBehavior,\n  });\n\n  /// The slivers",
        )
        for expected in scroll_view_expected:
            if scroll_view_text.count(expected) != 1:
                raise SystemExit("OHOS Flutter pointer filter source drift in scroll_view.dart")
        scroll_view_text = scroll_view_text.replace(
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n  }) : assert(",
            "    this.hitTestBehavior = HitTestBehavior.opaque,\n    this.pointerDownFilter,\n  }) : assert(",
            1,
        )
        scroll_view_text = scroll_view_text.replace(
            "  /// Returns the [AxisDirection] in which the scroll view scrolls.",
            "  final bool Function(PointerDownEvent event)? pointerDownFilter;\n\n  /// Returns the [AxisDirection] in which the scroll view scrolls.",
            1,
        )
        scroll_view_text = scroll_view_text.replace(
            "      hitTestBehavior: hitTestBehavior,\n      viewportBuilder:",
            "      hitTestBehavior: hitTestBehavior,\n      pointerDownFilter: pointerDownFilter,\n      viewportBuilder:",
            1,
        )
        scroll_view_text = scroll_view_text.replace(
            "    super.hitTestBehavior,\n  });\n\n  /// The slivers",
            "    super.hitTestBehavior,\n    super.pointerDownFilter,\n  });\n\n  /// The slivers",
            1,
        )
        if not all(marker in scroll_view_text for marker in scroll_view_markers):
            raise SystemExit("OHOS Flutter pointer filter transformation incomplete for scroll_view.dart")
        scroll_view.write_text(scroll_view_text, encoding="utf-8")
        scroll_view_changed = True
    return int(scrollable_changed) + int(scroll_view_changed)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--flutter-root", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, default=Path.cwd())
    parser.add_argument("--pointer-filter-only", action="store_true")
    args = parser.parse_args()
    root = args.flutter_root.resolve()
    patch_root = (args.workspace / "lib/scripts").resolve()
    if not (root / ".git").is_dir():
        parser.error(f"Flutter root is not a git checkout: {root}")
    if args.pointer_filter_only:
        changed = patch_pointer_filter(root)
        print(f"Flutter pointer filter: {changed} file(s) changed")
        return
    applied = 0
    for name in PATCHES:
        if apply_patch(root, patch_root / name):
            applied += 1
    selective = patch_root / "scrollable_gesture.patch"
    for include in (
        "packages/flutter/lib/src/painting/inline_span.dart",
        "packages/flutter/lib/src/painting/placeholder_span.dart",
        "packages/flutter/lib/src/painting/text_span.dart",
        "packages/flutter/lib/src/widgets/widget_span.dart",
        "packages/flutter/lib/src/material/tabs.dart",
        "packages/flutter/lib/src/widgets/gesture_detector.dart",
        "packages/flutter/lib/src/gestures/tap_and_drag.dart",
        "packages/flutter/lib/src/widgets/selectable_region.dart",
        "packages/flutter/lib/src/widgets/text_selection.dart",
    ):
        if apply_selective_patch(root, selective, include):
            applied += 1
    applied += patch_pointer_filter(root)
    patch_page_view(root)
    patch_raw_text(root)
    selectable = root / "packages/flutter/lib/src/widgets/selectable_region.dart"
    selectable_text = selectable.read_text(encoding="utf-8")
    if "Selectable? get selectable" not in selectable_text:
        selectable_text = selectable_text.replace(
            "  final StaticSelectionContainerDelegate _selectionDelegate = StaticSelectionContainerDelegate();",
            "  final StaticSelectionContainerDelegate _selectionDelegate = StaticSelectionContainerDelegate();\n  Selectable? get selectable => _selectable;\n  StaticSelectionContainerDelegate get selectionDelegate => _selectionDelegate;",
        )
        selectable.write_text(selectable_text, encoding="utf-8")
    platform_cases = patch_target_platform_cases(root / "packages/flutter/lib/src")
    print(f"OHOS Flutter compatibility patches: {applied}/{len(PATCHES) + 9} applied; TargetPlatform cases: {platform_cases}")


if __name__ == "__main__":
    main()
