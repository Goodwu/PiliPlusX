#!/usr/bin/env bash

set -euo pipefail

# Experimental only. This packages an arm64 preview from the already-installed
# Homebrew mpv/libplacebo stack. It is deliberately not the production
# media_kit_libs_macos_video artifact: the preview is useful to prove the
# producer/output route before a reproducible universal build exists.

if [[ $# -ne 2 ]]; then
  echo "usage: $0 INPUT_APP OUTPUT_APP" >&2
  exit 2
fi

input_app=$1
output_app=$2
homebrew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}

if [[ ! -d "$input_app" ]]; then
  echo "input app does not exist: $input_app" >&2
  exit 1
fi
if [[ -e "$output_app" ]]; then
  echo "output already exists; choose a new path: $output_app" >&2
  exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
  echo "this preview recipe only supports an arm64 host" >&2
  exit 1
fi

mpv_source="$homebrew_prefix/opt/mpv/lib/libmpv.2.dylib"
if [[ ! -f "$mpv_source" ]]; then
  echo "Homebrew mpv was not found: $mpv_source" >&2
  exit 1
fi

mpv_version=$(brew list --versions mpv 2>/dev/null | awk '{print $2}' | head -n 1)
if [[ "$mpv_version" != 0.41.0* ]]; then
  echo "expected Homebrew mpv 0.41.0.x, got: ${mpv_version:-unknown}" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_app")"
ditto "$input_app" "$output_app"

frameworks="$output_app/Contents/Frameworks"
mpv_framework="$frameworks/Mpv.framework/Versions/A/Mpv"
seen_dir=$(mktemp -d "${TMPDIR:-/tmp}/modern-mpv-preview-seen.XXXXXX")
trap 'rmdir "$seen_dir" 2>/dev/null || true' EXIT

# The queue contains absolute Homebrew paths. Each basename is copied once;
# Homebrew's dylib names are versioned and unique in this dependency closure.
set -- "$mpv_source"
while [[ $# -gt 0 ]]; do
  source_path=$1
  shift
  base_name=$(basename "$source_path")
  marker="$seen_dir/$base_name"
  [[ -e "$marker" ]] && continue
  : > "$marker"

  if [[ ! -f "$source_path" ]]; then
    echo "missing Homebrew dependency: $source_path" >&2
    exit 1
  fi

  if [[ "$base_name" == libmpv.2.dylib ]]; then
    destination="$mpv_framework"
  else
    destination="$frameworks/$base_name"
  fi

  ditto "$source_path" "$destination"
  if [[ "$destination" == "$mpv_framework" ]]; then
    install_name_tool -id '@rpath/Mpv.framework/Versions/A/Mpv' "$destination"
  else
    install_name_tool -id "@rpath/$base_name" "$destination"
  fi

  while IFS= read -r dependency; do
    case "$dependency" in
      "$homebrew_prefix"/*)
        if [[ ! -f "$dependency" ]]; then
          echo "missing transitive Homebrew dependency: $dependency" >&2
          exit 1
        fi
        dependency_base=$(basename "$dependency")
        if [[ "$dependency_base" == libmpv.2.dylib ]]; then
          replacement='@rpath/Mpv.framework/Versions/A/Mpv'
        else
          replacement="@rpath/$dependency_base"
        fi
        install_name_tool -change "$dependency" "$replacement" "$destination"
        set -- "$@" "$dependency"
        ;;
    esac
  done < <(
    otool -L "$destination" |
      sed -n '2,$p' |
      sed -E 's/^[[:space:]]+([^ ]+) \(.*/\1/'
  )
done

codesign --force --deep --sign - "$output_app" >/dev/null

remaining_homebrew=$(
  find "$frameworks" -type f \( -name '*.dylib' -o -path '*/Mpv.framework/*/Mpv' \) -print0 |
    xargs -0 -n 1 otool -L 2>/dev/null |
    rg '/opt/homebrew/' || true
)
if [[ -n "$remaining_homebrew" ]]; then
  echo "absolute Homebrew dependency remains:" >&2
  echo "$remaining_homebrew" >&2
  exit 1
fi

if ! file "$mpv_framework" | rg -q 'arm64'; then
  echo "packaged Mpv.framework is not arm64" >&2
  exit 1
fi

echo "preview app: $output_app"
echo "mpv: $mpv_version"
echo "source: $mpv_source"
echo "Homebrew absolute dependencies: none"
