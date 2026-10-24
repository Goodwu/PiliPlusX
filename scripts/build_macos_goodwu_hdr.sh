#!/usr/bin/env bash

set -euo pipefail

# Build a verified macOS Debug candidate with the pinned mpv 0.41 runtime.
# The Xcode post-embed phase also protects the default product path.

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

# The Xcode post-embed phase already installs the pinned runtime into the
# default app. Copy only a verified product; do not depend on expiring artifacts.
scripts/verify_macos_mpv_bundle.sh "$input_app"
ditto "$input_app" "$output_app"
scripts/verify_macos_mpv_bundle.sh "$output_app"
