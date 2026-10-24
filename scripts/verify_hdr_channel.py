#!/usr/bin/env python3
"""Verify App HDR channels and the Android hand-off to media-kit.

Android device probing belongs to media-kit. Other platforms still implement
HdrPlatform's probe/configure/reset contract. Pink renaming must alter neither
channel identity nor this division of responsibilities.
"""
from pathlib import Path
import re

CHANNEL = "piliplusx/hdr_capabilities"
OLD_CHANNEL = "com.example.piliplusx/hdr_capabilities"
DART = "lib/plugin/pl_player/hdr_platform.dart"
ANDROID = "android/app/src/main/kotlin/com/example/piliplusx/MainActivity.kt"
FILES = (
    DART, ANDROID,
    "ios/Runner/AppDelegate.swift",
    "macos/Runner/MainFlutterWindow.swift",
    "windows/runner/flutter_window.cpp",
    "linux/runner/my_application.cc",
    "ohos/entry/src/main/ets/plugins/HarmonyChannel.ets",
)
OUTPUT_FIELDS = (
    "active", "failureReason", "sourceProcessing", "outputEncoding",
    "dynamicMetadataApplied", "supportedInputFormats", "supportedOutputFormats",
)


def verify(root: Path) -> list[str]:
    failures: list[str] = []

    def read(name: str) -> str:
        path = root / name
        if not path.is_file():
            failures.append(f"{name}: missing contract file")
            return ""
        return path.read_text(encoding="utf-8")

    for name in FILES:
        text = read(name)
        if text.count(CHANNEL) != 1:
            failures.append(f"{name}: expected one {CHANNEL!r}")
        if OLD_CHANNEL in text:
            failures.append(f"{name}: package-coupled HDR channel")
        methods = ("configureOutput", "resetOutput")
        if name != ANDROID:
            methods += ("probe",)
        else:
            methods += ("setWindowHdrMode",)
        for method in methods:
            # Quoted operation names, not comments describing retired methods.
            if not re.search(r"['\"]" + re.escape(method) + r"['\"]", text):
                failures.append(f"{name}: missing {method} operation")
        if name != DART:
            fields = OUTPUT_FIELDS
            if name != ANDROID:
                fields += ("nativeOutputCapable", "nativeOutputActive")
            for field in fields:
                if field not in text:
                    failures.append(f"{name}: missing {field} field")
        if name == ANDROID and re.search(r'call\.method\s*==\s*[\'"]probe[\'"]', text):
            failures.append("Android must delegate device capability probing to media-kit")

    selector = read("lib/plugin/pl_player/hdr_output.dart")
    for token in ("VideoRouteCapabilities.query(", "target: target", "sources: sources"):
        if token not in selector:
            failures.append(f"Android route query: missing {token}")
    if re.search(r"\bHdrCapabilities\.query\s*\(", selector):
        failures.append("Android route query restored obsolete Player API")
    controller = read("lib/plugin/pl_player/controller.dart")
    ports = read("lib/plugin/pl_player/models/player_lifecycle_ports.dart")
    for token in ("_lifecyclePorts.usesAndroidSession", "session: session"):
        if token not in controller:
            failures.append(f"Android Session factory hand-off: missing {token}")
    if not re.search(r"_lifecyclePorts\.newHdrSession\(\s*player,\s*videoOutputTarget,?\s*\)", controller):
        failures.append("Android Session factory hand-off is missing")
    if not re.search(r"androidSessionOverride\s*\?\?\s*Platform\.isAndroid", ports):
        failures.append("Android Session factory must default to the actual platform")
    if not re.search(r"createHdrSession\?\.call\(player,\s*target\)\s*\?\?\s*HdrVideoSession\(player,\s*target:\s*target\)", ports):
        failures.append("Android Session factory must default to the real media-kit Session")
    opens = re.findall(r"hdrVideoSession\.value!\.open\((.*?)\n\s*\);", controller, re.S)
    if len(opens) != 2 or any(
        "options: dataSource.routeOptions ?? _sourceRouteOptions" not in call
        for call in opens
    ):
        failures.append("Android initial and refresh opens must consume the source options snapshot")
    return failures


def main() -> None:
    failures = verify(Path.cwd())
    if failures:
        raise SystemExit("HDR channel verification failed:\n" + "\n".join(failures))
    print(f"HDR channel verified: {len(FILES)} endpoints; Android query/Session delegation")


if __name__ == "__main__":
    main()
