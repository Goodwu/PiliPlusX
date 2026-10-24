#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tool/ohos/sync_ohos_workspace.sh [options]

Options:
  --remote-host HOST     SSH host (default: dev)
  --remote-project DIR   Remote source directory
  --check-only           Verify checksums without synchronizing
  -h, --help             Show this help
USAGE
}

remote_host=${REMOTE_HOST:-dev}
remote_project=${REMOTE_PROJECT:-/home/wuweiwei1/PiliPlusX-ohos-344}
media_kit_source=${MEDIA_KIT_SOURCE:-/Users/wuweiwei1/src/media-kit}
remote_media_kit=${REMOTE_MEDIA_KIT:-/home/wuweiwei1/media-kit-ohos}
native_build_source=${NATIVE_BUILD_SOURCE:-/Users/wuweiwei1/src/ohos-native-build/libmpv-ohos-build}
remote_native_build=${REMOTE_NATIVE_BUILD:-/home/wuweiwei1/libmpv-ohos-build}
check_only=0

while (($#)); do
  case "$1" in
    --remote-host) remote_host=${2:?missing value for --remote-host}; shift 2 ;;
    --remote-project) remote_project=${2:?missing value for --remote-project}; shift 2 ;;
    --check-only) check_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

source_root=$(pwd -P)
manifest=$(mktemp "${TMPDIR:-/tmp}/piliplusx-ohos-manifest.XXXXXX")
remote_manifest=$(mktemp "${TMPDIR:-/tmp}/piliplusx-ohos-remote-manifest.XXXXXX")
trap 'rm -f "$manifest" "$remote_manifest"' EXIT

write_local_manifest() {
  (
    cd "$source_root"
    find . \
      \( -name .git -o -name .dart_tool -o -name build -o -name .symlinks \
         -o -name ephemeral -o -name oh_modules -o -name '*.bak-codex-*' \) -prune \
      -o -type f -print
  ) | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$source_root/$file"
  done | sed 's#  .*/#  #'
}

write_local_manifest >"$manifest"
[[ -d $media_kit_source ]] || {
  echo "media-kit source directory not found: $media_kit_source" >&2
  exit 1
}
[[ -d $native_build_source ]] || {
  echo "native OHOS build source directory not found: $native_build_source" >&2
  exit 1
}

if ((check_only == 0)); then
  echo "syncing $source_root -> $remote_host:$remote_project" >&2
  rsync -a --checksum --delete \
    --exclude='.git/' \
    --exclude='.dart_tool/' \
    --exclude='build/' \
    --exclude='.symlinks/' \
    --exclude='ephemeral/' \
    --exclude='oh_modules/' \
    --exclude='*.bak-codex-*' \
    -e 'ssh -oClearAllForwardings=yes' \
    "$source_root/" "$remote_host:$remote_project/"
  echo "syncing $media_kit_source -> $remote_host:$remote_media_kit" >&2
  rsync -a --checksum --delete \
    --exclude='.git/' \
    --exclude='.dart_tool/' \
    --exclude='build/' \
    --exclude='*.bak-codex-*' \
    -e 'ssh -oClearAllForwardings=yes' \
    "$media_kit_source/" "$remote_host:$remote_media_kit/"
fi

echo "checking source manifest" >&2
/Users/wuweiwei1/.codex/skills/ssh-remote-exec/scripts/ssh-remote-exec.sh \
  --ssh-opt '-oClearAllForwardings=yes' "$remote_host" -- "$remote_project" <<'REMOTE' >"$remote_manifest"
set -euo pipefail
cd "$1"
find . \
  \( -name .git -o -name .dart_tool -o -name build -o -name .symlinks \
     -o -name ephemeral -o -name oh_modules -o -name '*.bak-codex-*' \) -prune \
  -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
  sha256sum "$file"
done | sed 's#  .*/#  #'
REMOTE

if ! diff -u "$manifest" "$remote_manifest"; then
  echo "OHOS source synchronization check failed" >&2
  exit 1
fi

echo "OHOS source synchronization verified: $(wc -l <"$manifest" | tr -d ' ') files" >&2
rsync -an --checksum --delete \
  --exclude='.git/' --exclude='.dart_tool/' --exclude='build/' \
  --exclude='*.bak-codex-*' \
  -e 'ssh -oClearAllForwardings=yes' \
  "$media_kit_source/" "$remote_host:$remote_media_kit/" | \
  if read -r unexpected; then
    echo "media-kit synchronization check failed: $unexpected" >&2
    exit 1
  fi
echo "media-kit source synchronization verified" >&2

echo "checking native OHOS build source synchronization" >&2
if ((check_only == 0)); then
  rsync -a --checksum \
    --exclude='.git/' \
    --exclude='libmpv/' \
    --exclude='*.bak-codex-*' \
    -e 'ssh -oClearAllForwardings=yes' \
    "$native_build_source/" "$remote_host:$remote_native_build/"
fi
rsync -an --checksum \
  --exclude='.git/' --exclude='libmpv/' --exclude='*.bak-codex-*' \
  -e 'ssh -oClearAllForwardings=yes' \
  "$native_build_source/" "$remote_host:$remote_native_build/" | \
  if read -r unexpected; then
    echo "native OHOS build source synchronization check failed: $unexpected" >&2
    exit 1
  fi
echo "native OHOS build source synchronization verified" >&2
