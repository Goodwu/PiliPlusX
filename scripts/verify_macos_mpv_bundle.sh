#!/usr/bin/env bash
# Static product gate; visible HDR playback still requires runtime acceptance.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 APP_PATH" >&2; exit 2; }
app=$1
# No environment variable can bypass the ordinary final product guard.
python3 - "$app" <<'PY_PENDING'
from pathlib import Path
import plistlib, sys
info = Path(sys.argv[1]) / 'Contents/Info.plist'
if info.is_symlink() or not info.is_file():
    raise SystemExit('FAIL: regular application Info.plist required')
values = plistlib.loads(info.read_bytes())
if 'MediaKitSharedBootstrapPending' in values:
    raise SystemExit('FAIL: shared bootstrap is pending; application is not a final product')
PY_PENDING
framework="$app/Contents/Frameworks/Mpv.framework/Versions/A/Mpv"
[[ -f "$framework" ]] || { echo 'FAIL: Mpv.framework missing' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for arch in arm64 x86_64; do
  lipo "$framework" -thin "$arch" -output "$work/$arch" || exit 1
  strings "$work/$arch" > "$work/$arch.txt"
  grep -Eq 'mpv v?0\.41\.0($|[^0-9])' "$work/$arch.txt" || {
    echo "FAIL: $arch Mpv.framework is not mpv 0.41.0" >&2; exit 1;
  }
  for marker in libplacebo gpu-next gl-cocoa videotoolbox-gl; do
    grep -Fq "$marker" "$work/$arch.txt" || {
      echo "FAIL: $arch Mpv.framework missing $marker" >&2; exit 1;
    }
  done
  if grep -Eq 'mpv v?0\.36\.' "$work/$arch.txt"; then
    echo "FAIL: legacy mpv found in $arch" >&2; exit 1
  fi
done
for lib in libplacebo.dylib libvulkan.1.dylib libshaderc_shared.1.dylib; do
  [[ -f "$app/Contents/Frameworks/$lib" ]] || { echo "FAIL: missing $lib" >&2; exit 1; }
done
find "$app/Contents/Frameworks" -type f \( -name '*.dylib' -o -path '*/Mpv.framework/*/Mpv' \) -print0 |
  xargs -0 -n 1 otool -L > "$work/dependencies.txt"
if grep -Eq '/opt/homebrew/|/usr/local/' "$work/dependencies.txt"; then
  echo 'FAIL: nonrelocatable runtime dependency' >&2; exit 1
fi
python3 "$(dirname "$0")/verify_macos_mpv_closure.py" "$app"
"$(dirname "$0")/verify_macos_mpv_load.sh" "$app"
codesign --verify --deep --strict "$app"
echo "PASS: both Mpv slices are 0.41.0; runtime closure, loading and signature verified"
shasum -a 256 "$framework"
