#!/usr/bin/env bash

set -euo pipefail

# Build a macOS app and replace the bundled legacy libmpv with the universal
# mpv 0.41 artifact from Goodwu/libmpv-darwin-build's validated experiment.
# Requires an authenticated gh CLI; the artifact is downloaded by run ID so
# the exact producer commit remains auditable.

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_APP" >&2
  exit 2
fi

output_app=$1
input_app="build/macos/Build/Products/Debug/PiliPlusX.app"
repo="${GOODWU_LIBMPV_REPO:-Goodwu/libmpv-darwin-build}"
run_id="${GOODWU_LIBMPV_RUN_ID:-34097910903}"

if [[ -e "$output_app" ]]; then
  echo "output already exists; choose a new path: $output_app" >&2
  exit 1
fi

flutter build macos --debug --no-pub

artifact_dir=$(mktemp -d "${TMPDIR:-/tmp}/goodwu-libmpv-artifact.XXXXXX")
trap 'rmdir "$artifact_dir" 2>/dev/null || true' EXIT
gh run download "$run_id" --repo "$repo" --dir "$artifact_dir"

archive=$(find "$artifact_dir" -type f -name 'libmpv-libs_*_macos-universal-video-default.tar.gz' -print -quit)
if [[ -z "$archive" ]]; then
  echo "universal Goodwu libmpv archive not found in run $run_id" >&2
  exit 1
fi

scripts/package_macos_goodwu_mpv_hdr.sh "$input_app" "$archive" "$output_app"
