#!/usr/bin/env bash

set -euo pipefail

# Build the app and package the already-validated Homebrew mpv 0.41 arm64
# renderer. This is a reproducible local Apple-Silicon preview, not the
# production universal media-kit artifact.

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_APP" >&2
  exit 2
fi

output_app=$1
input_app="build/macos/Build/Products/Debug/PiliPlusX.app"

if [[ -e "$output_app" ]]; then
  echo "output already exists; choose a new path: $output_app" >&2
  exit 1
fi

flutter build macos --debug --no-pub
scripts/package_macos_modern_mpv_preview.sh "$input_app" "$output_app"
