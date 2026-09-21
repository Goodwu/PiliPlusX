#!/usr/bin/env bash

# Download the reviewed macOS mpv 0.41 release asset and reject a changed
# archive before it can be bundled into a release application.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 DESTINATION" >&2
  exit 2
fi

destination=$1
repo="${GOODWU_LIBMPV_REPO:-Goodwu/libmpv-darwin-build}"
release_tag="${GOODWU_LIBMPV_RELEASE_TAG:-v0.41.0-piliplusx.1}"
asset_name="${GOODWU_LIBMPV_ASSET:-libmpv-libs_develop_macos-universal-video-default.tar.gz}"
expected_sha256="${GOODWU_LIBMPV_ARCHIVE_SHA256:-2965439e9d239a441263288140b2d8b09ee877478084916f63575a1775de97a4}"

temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$temp_root"
work_dir=$(mktemp -d "$temp_root/goodwu-libmpv.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
gh release download "$release_tag" --repo "$repo" --pattern "$asset_name" --dir "$work_dir"
archive="$work_dir/$asset_name"
[[ -f "$archive" ]] || { echo "mpv release asset is missing: $asset_name" >&2; exit 1; }
actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
[[ "$actual_sha256" == "$expected_sha256" ]] || {
  echo "unexpected Goodwu mpv archive SHA-256: $actual_sha256" >&2
  exit 1
}
mkdir -p "$(dirname "$destination")"
cp "$archive" "$destination"
echo "Goodwu mpv archive verified: $actual_sha256"
