#!/usr/bin/env bash
# Runs after Flutter/Pods embed, before Xcode's final application signing.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 APP_PATH" >&2; exit 2; }
app=$1
mode=${PILIPLUSX_MPV_BUNDLE_MODE-legacy}
case "$mode" in
  legacy|shared-candidate-bootstrap) ;;
  *) echo "FAIL: unknown PILIPLUSX_MPV_BUNDLE_MODE: $mode" >&2; exit 2 ;;
esac
python3 - "$app" "$mode" <<'PY_BOOTSTRAP'
from pathlib import Path
import os, plistlib, sys, tempfile
info = Path(sys.argv[1]) / 'Contents/Info.plist'
if info.is_symlink() or not info.is_file():
    raise SystemExit('FAIL: regular application Info.plist required')
values = plistlib.loads(info.read_bytes())
key = 'MediaKitSharedBootstrapPending'
if sys.argv[2] == 'legacy':
    if key in values:
        raise SystemExit('FAIL: bootstrap pending; use a fresh normal build or shared candidate consumer')
else:
    if key in values and values[key] is not True:
        raise SystemExit('FAIL: invalid bootstrap pending value')
    values[key] = True
    fd, name = tempfile.mkstemp(prefix='.bootstrap-', dir=info.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            plistlib.dump(values, stream)
        os.chmod(name, info.stat().st_mode & 0o777)
        os.replace(name, info)
    finally:
        if os.path.lexists(name):
            os.unlink(name)
PY_BOOTSTRAP
if [[ "$mode" == shared-candidate-bootstrap ]]; then
  echo 'Bootstrap only: shared consumer must complete all final package gates'
  exit 0
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
archive="${PILIPLUSX_MPV_ARCHIVE:-$script_dir/../build/native-deps/libmpv-macos.tar.gz}"
expected=2965439e9d239a441263288140b2d8b09ee877478084916f63575a1775de97a4
if [[ ! -f "$archive" ]]; then
  "$script_dir/fetch_goodwu_mpv_archive.sh" "$archive"
fi
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { echo "FAIL: unreviewed mpv archive: $actual" >&2; exit 1; }
runtime_work="${PILIPLUSX_MPV_RUNTIME_WORK:-$script_dir/../build/native-deps/runtime-work}"
export PILIPLUSX_MPV_RUNTIME_DIR="${PILIPLUSX_MPV_RUNTIME_DIR:-$script_dir/../build/native-deps/mpv-runtime}"
if [[ ! -f "$PILIPLUSX_MPV_RUNTIME_DIR/manifest.json" ]]; then
  python3.11 "$script_dir/build_macos_mpv_runtime.py" "$PILIPLUSX_MPV_RUNTIME_DIR" --work-dir "$runtime_work"
fi
python3 "$script_dir/verify_macos_mpv_runtime.py" "$PILIPLUSX_MPV_RUNTIME_DIR"
export PILIPLUSX_MPV_X86_SLICE="${PILIPLUSX_MPV_X86_SLICE:-$script_dir/../build/native-deps/mpv-x86.dylib}"
if [[ ! -f "$PILIPLUSX_MPV_X86_SLICE" ]]; then
  python3.11 "$script_dir/build_macos_mpv_x86.py" "$app" "$archive" "$runtime_work" "$PILIPLUSX_MPV_X86_SLICE"
fi
python3 "$script_dir/verify_macos_mpv_slice.py" "$PILIPLUSX_MPV_X86_SLICE" "$app"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$script_dir/package_macos_goodwu_mpv_hdr.sh" "$app" "$archive" "$work/PiliPlusX.app"
"$script_dir/verify_macos_mpv_bundle.sh" "$work/PiliPlusX.app"
ditto "$work/PiliPlusX.app" "$app"
"$script_dir/verify_macos_mpv_bundle.sh" "$app"
