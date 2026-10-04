#!/usr/bin/env bash

set -euo pipefail

# Package the universal mpv 0.41 artifact produced by
# Goodwu/libmpv-darwin-build's experiment/mpv-041-b3-opengl branch.
# Runtime libraries must match the archive's libplacebo 349 ABI. A universal
# runtime directory can be supplied after building matching dependencies.

if [[ $# -ne 3 ]]; then
  echo "usage: $0 INPUT_APP GOODWU_ARCHIVE OUTPUT_APP" >&2
  exit 2
fi

input_app=$1
goodwu_archive=$2
output_app=$3
script_dir=$(cd "$(dirname "$0")" && pwd)

[[ -d "$input_app" ]] || { echo "input app does not exist: $input_app" >&2; exit 1; }
[[ -f "$goodwu_archive" ]] || { echo "Goodwu archive does not exist: $goodwu_archive" >&2; exit 1; }
archive_sha=$(shasum -a 256 "$goodwu_archive" | awk '{print $1}')
[[ "$archive_sha" == 2965439e9d239a441263288140b2d8b09ee877478084916f63575a1775de97a4 ]] || {
  echo "unreviewed Goodwu archive: $archive_sha" >&2; exit 1;
}
[[ ! -e "$output_app" ]] || { echo "output already exists: $output_app" >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "this packaging check requires an arm64 host" >&2; exit 1; }

runtime_dir=${PILIPLUSX_MPV_RUNTIME_DIR:-$script_dir/../build/native-deps/mpv-runtime}
python3 "$script_dir/verify_macos_mpv_runtime.py" "$runtime_dir"
runtime_libplacebo="$runtime_dir/libplacebo.dylib"
runtime_shaderc="$runtime_dir/libshaderc_shared.1.dylib"
runtime_vulkan="$runtime_dir/libvulkan.1.dylib"
runtime_lcms2="$runtime_dir/liblcms2.2.dylib"
for dependency in "$runtime_libplacebo" "$runtime_shaderc" "$runtime_vulkan" "$runtime_lcms2"; do
  [[ -f "$dependency" ]] || { echo "missing pinned runtime dependency: $dependency" >&2; exit 1; }
done

mkdir -p "$(dirname "$output_app")"
ditto "$input_app" "$output_app"

frameworks="$output_app/Contents/Frameworks"
mpv_framework="$frameworks/Mpv.framework/Versions/A/Mpv"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/goodwu-mpv-package.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
tar -xzf "$goodwu_archive" -C "$work_dir"
archive_root=$(find "$work_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$archive_root" ]] || { echo "archive has no top-level directory" >&2; exit 1; }

mkdir -p "$(dirname "$mpv_framework")"

copy_dylib() {
  local source=$1
  local destination_base
  destination_base=$(basename "$source")
  local destination="$frameworks/$destination_base"
  if [[ "$destination_base" == libmpv.dylib ]]; then
    destination="$mpv_framework"
  elif [[ "$destination_base" == libplacebo.dylib || "$destination_base" == libplacebo.*.dylib ]]; then
    destination="$frameworks/libplacebo.dylib"
  fi
  ditto "$source" "$destination"
  if [[ "$destination" == "$mpv_framework" ]]; then
    install_name_tool -id '@rpath/Mpv.framework/Versions/A/Mpv' "$destination"
  else
    install_name_tool -id "@rpath/$(basename "$destination")" "$destination"
  fi
}

for source in "$archive_root"/*.dylib; do
  [[ "$(basename "$source")" != libplacebo.dylib ]] && copy_dylib "$source"
done
# The reviewed archive expects a dylib name while a fresh Pods/SPM embed
# supplies the same libass ABI in Ass.framework. Never rely on old packaging.
ass_framework="$frameworks/Ass.framework/Versions/A/Ass"
[[ -f "$ass_framework" ]] || { echo 'missing embedded Ass.framework' >&2; exit 1; }
ditto "$ass_framework" "$frameworks/libass.dylib"
install_name_tool -id '@rpath/libass.dylib' "$frameworks/libass.dylib"
rebuilt_slice=${PILIPLUSX_MPV_X86_SLICE:-$script_dir/../build/native-deps/mpv-x86.dylib}
if [[ -n "$rebuilt_slice" ]]; then
  python3 "$(dirname "$0")/verify_macos_mpv_slice.py" "$rebuilt_slice" "$input_app"
  lipo "$mpv_framework" -thin arm64 -output "$work_dir/mpv-arm64"
  lipo -create "$work_dir/mpv-arm64" "$rebuilt_slice" -output "$work_dir/mpv-universal"
  ditto "$work_dir/mpv-universal" "$mpv_framework"
  install_name_tool -id '@rpath/Mpv.framework/Versions/A/Mpv' "$mpv_framework"
fi
copy_dylib "$runtime_libplacebo"

# Collect the supplied libplacebo runtime closure. The copied names
# are normalized to the names used in the app bundle.
queue=("$runtime_libplacebo" "$runtime_shaderc" "$runtime_vulkan" "$runtime_lcms2")
seen_dir="$work_dir/seen"
mkdir -p "$seen_dir"
while [[ ${#queue[@]} -gt 0 ]]; do
  source_path=${queue[0]}
  queue=("${queue[@]:1}")
  base_name=$(basename "$source_path")
  marker="$seen_dir/$base_name"
  [[ -e "$marker" ]] && continue
  : > "$marker"

  destination="$frameworks/$base_name"
  [[ "$base_name" == libplacebo.*.dylib ]] && destination="$frameworks/libplacebo.dylib"
  # Existing embedded copies may be an older runtime. Always replace them
  # with the verified source, including when reusing an Xcode product folder.
  ditto "$source_path" "$destination"
  install_name_tool -id "@rpath/$(basename "$destination")" "$destination"

  while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/usr/local/*)
        dependency_base=$(basename "$dependency")
        replacement="@rpath/$dependency_base"
        [[ "$dependency_base" == libplacebo.*.dylib ]] && replacement='@rpath/libplacebo.dylib'
        install_name_tool -change "$dependency" "$replacement" "$destination"
        [[ -f "$dependency" ]] && queue+=("$dependency")
        ;;
      @rpath/libplacebo.*.dylib)
        install_name_tool -change "$dependency" '@rpath/libplacebo.dylib' "$destination"
        ;;
    esac
  done < <(otool -L "$destination" | sed -n '2,$p' | sed -E 's/^[[:space:]]+([^ ]+) \(.*/\1/')
done

# Normalize any dependency paths already present in the Goodwu archive and
# keep libmpv's framework name compatible with media_kit's loader.
find "$frameworks" -type f \( -name '*.dylib' -o -path '*/Mpv.framework/*/Mpv' \) -print0 |
  while IFS= read -r -d '' file; do
    while IFS= read -r dependency; do
      case "$dependency" in
        @rpath/libplacebo.*.dylib)
          install_name_tool -change "$dependency" '@rpath/libplacebo.dylib' "$file"
          ;;
      esac
    done < <(otool -L "$file" | sed -n '2,$p' | sed -E 's/^[[:space:]]+([^ ]+) \(.*/\1/')
  done

codesign --force --deep --sign - "$output_app" >/dev/null
codesign --verify --deep --strict "$output_app"

if ! file "$mpv_framework" | grep -Eq 'x86_64.*arm64|arm64.*x86_64'; then
  echo "packaged Mpv.framework is not universal" >&2
  exit 1
fi
if find "$frameworks" -type f \( -name '*.dylib' -o -path '*/Mpv.framework/*/Mpv' \) -print0 |
  xargs -0 -n 1 otool -L 2>/dev/null | grep -q '/opt/homebrew/'; then
  echo "absolute Homebrew dependency remains" >&2
  exit 1
fi

echo "Goodwu mpv package: $output_app"
echo "archive: $goodwu_archive"
echo "Mpv.framework: universal mpv 0.41.0"
echo "Homebrew absolute dependencies: none"

"$(dirname "$0")/verify_macos_mpv_bundle.sh" "$output_app"
