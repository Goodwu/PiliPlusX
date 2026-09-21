#!/usr/bin/env bash

set -euo pipefail

# Package the universal mpv 0.41 artifact produced by
# Goodwu/libmpv-darwin-build's experiment/mpv-041-b3-opengl branch.
# The artifact's arm64 libplacebo is intentionally supplied by the current
# Homebrew stack so its Vulkan/MoltenVK runtime closure is relocatable.

if [[ $# -ne 3 ]]; then
  echo "usage: $0 INPUT_APP GOODWU_ARCHIVE OUTPUT_APP" >&2
  exit 2
fi

input_app=$1
goodwu_archive=$2
output_app=$3
homebrew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}

[[ -d "$input_app" ]] || { echo "input app does not exist: $input_app" >&2; exit 1; }
[[ -f "$goodwu_archive" ]] || { echo "Goodwu archive does not exist: $goodwu_archive" >&2; exit 1; }
[[ ! -e "$output_app" ]] || { echo "output already exists: $output_app" >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "this packaging check requires an arm64 host" >&2; exit 1; }

brew_libplacebo="$homebrew_prefix/opt/libplacebo/lib/libplacebo.360.dylib"
brew_shaderc="$homebrew_prefix/opt/shaderc/lib/libshaderc_shared.1.dylib"
brew_vulkan="$homebrew_prefix/opt/vulkan-loader/lib/libvulkan.1.dylib"
brew_lcms2="$homebrew_prefix/opt/little-cms2/lib/liblcms2.2.dylib"
for dependency in "$brew_libplacebo" "$brew_shaderc" "$brew_vulkan" "$brew_lcms2"; do
  [[ -f "$dependency" ]] || { echo "missing Homebrew runtime dependency: $dependency" >&2; exit 1; }
done

mkdir -p "$(dirname "$output_app")"
ditto "$input_app" "$output_app"

frameworks="$output_app/Contents/Frameworks"
mpv_framework="$frameworks/Mpv.framework/Versions/A/Mpv"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/goodwu-mpv-package.XXXXXX")
trap 'rmdir "$work_dir" 2>/dev/null || true' EXIT
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
copy_dylib "$brew_libplacebo"

# Collect the arm64 libplacebo runtime closure from Homebrew. The copied names
# are normalized to the names used in the app bundle.
queue=("$brew_libplacebo" "$brew_shaderc" "$brew_vulkan" "$brew_lcms2")
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
  [[ -e "$destination" ]] || ditto "$source_path" "$destination"
  install_name_tool -id "@rpath/$(basename "$destination")" "$destination"

  while IFS= read -r dependency; do
    case "$dependency" in
      "$homebrew_prefix"/*)
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

if ! file "$mpv_framework" | rg -q 'x86_64.*arm64|arm64.*x86_64'; then
  echo "packaged Mpv.framework is not universal" >&2
  exit 1
fi
if find "$frameworks" -type f \( -name '*.dylib' -o -path '*/Mpv.framework/*/Mpv' \) -print0 |
  xargs -0 -n 1 otool -L 2>/dev/null | rg -q '/opt/homebrew/'; then
  echo "absolute Homebrew dependency remains" >&2
  exit 1
fi

echo "Goodwu mpv package: $output_app"
echo "archive: $goodwu_archive"
echo "Mpv.framework: universal mpv 0.41.0"
echo "Homebrew absolute dependencies: none"
