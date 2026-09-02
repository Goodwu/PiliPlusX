#!/usr/bin/env python3
"""Keep the HDR capability channel independent of application package names."""

from pathlib import Path


CHANNEL = "piliplusx/hdr_capabilities"
OLD_CHANNEL = "com.example.piliplusx/hdr_capabilities"
FILES = (
    "lib/plugin/pl_player/hdr_platform.dart",
    "android/app/src/main/kotlin/com/example/piliplusx/MainActivity.kt",
    "ios/Runner/AppDelegate.swift",
    "macos/Runner/MainFlutterWindow.swift",
    "windows/runner/flutter_window.cpp",
    "linux/runner/my_application.cc",
    "ohos/entry/src/main/ets/plugins/HarmonyChannel.ets",
)


def main() -> None:
    failures: list[str] = []
    for name in FILES:
        path = Path(name)
        text = path.read_text(encoding="utf-8")
        count = text.count(CHANNEL)
        if count != 1:
            failures.append(f"{name}: expected one {CHANNEL!r}, found {count}")
        if OLD_CHANNEL in text:
            failures.append(f"{name}: contains package-coupled HDR channel")
        for method in ("probe", "configureOutput", "resetOutput"):
            if method not in text:
                failures.append(f"{name}: missing {method} operation")
        if name != "lib/plugin/pl_player/hdr_platform.dart":
            for field in ("nativeOutputCapable", "nativeOutputActive"):
                if field not in text:
                    failures.append(f"{name}: missing capability field {field}")
            for field in ("active", "failureReason"):
                if field not in text:
                    failures.append(f"{name}: missing output result field {field}")
    android_helper = Path("lib/plugin/pl_player/hdr_android.dart").read_text(
        encoding="utf-8"
    )
    for method in ("setWindowHdrMode", "setColorSpace"):
        if method not in android_helper:
            failures.append(f"Android HDR helper: missing {method} operation")
    for method in ("probe", "configureOutput", "resetOutput"):
        if method in android_helper:
            failures.append(
                f"Android HDR helper: cross-platform operation {method} must use HdrPlatform"
            )
    if failures:
        raise SystemExit("HDR channel verification failed:\n" + "\n".join(failures))
    print(f"HDR channel verified: {CHANNEL} ({len(FILES)} endpoints)")


if __name__ == "__main__":
    main()
