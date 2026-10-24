#!/usr/bin/env bash
# Resolve all imports before accepting the actual embedded runtime.
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'usage: verify_macos_mpv_load.sh APP_PATH' >&2; exit 2; }
app=$(cd "$1" && pwd)
frameworks="$app/Contents/Frameworks"
script_dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app_executable=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")
[[ -n "$app_executable" && "$app_executable" != */* && "$app_executable" != . && "$app_executable" != .. ]] || {
  echo 'FAIL: invalid application executable name' >&2; exit 1;
}
arches=$(lipo -archs "$app/Contents/MacOS/$app_executable")
[[ -n "$arches" ]] || { echo 'FAIL: application has no architectures' >&2; exit 1; }
for arch in $arches; do
  xcrun clang -arch "$arch" "$script_dir/native/macos_mpv_smoke.c" \
    -Wl,-rpath,"$frameworks" -o "$work/probe-$arch"
  # Sign generated probes before Rosetta execution, as for packaged binaries.
  /usr/bin/codesign --force --sign - "$work/probe-$arch"
  /usr/bin/arch -"$arch" "$work/probe-$arch" \
    "$frameworks/Mpv.framework/Versions/A/Mpv" || {
      echo "FAIL: $arch embedded mpv cannot load and initialize" >&2; exit 1;
    }
  echo "PASS: $arch embedded mpv loaded and initialized (no media/output)"
done
