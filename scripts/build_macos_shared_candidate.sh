#!/usr/bin/env bash
# Build a product candidate from the reviewed shared-core publication.
set -euo pipefail
[[ $# -eq 4 || $# -eq 5 ]] || {
  echo "usage: $0 SHARED_WORK SHARED_PUBLICATION SHARED_RECIPE OUTPUT_APP [--local-video-diagnostics]" >&2
  exit 2
}
flutter_args=(--release --no-pub)
if [[ $# -eq 5 ]]; then
  [[ "$5" == --local-video-diagnostics ]] || {
    echo "FAIL: unknown candidate option: $5" >&2
    exit 2
  }
  flutter_args+=(--dart-define=PILIPLUS_LOCAL_VIDEO_DIAGNOSTICS=true)
fi
[[ ! -L "$4" ]] || { echo "FAIL: output must not be a symbolic link" >&2; exit 2; }
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
# Resolve caller-relative paths before entering the repository.
work=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$1")
published=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$2")
recipe=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$3")
output=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$4")
[[ ! -e "$output" ]] || { echo "FAIL: output already exists: $output" >&2; exit 2; }
[[ -f "$work/build-state.json" && -f "$published/slice-manifest.json" && -f "$recipe/verify_source.py" ]] || {
  echo "FAIL: reviewed shared build inputs are missing" >&2
  exit 2
}
cd "$repo_dir"
python3 "$script_dir/package_macos_shared_build.py" \
  "$repo_dir/build/macos/Build/Products/Release/PiliPlusX.app" \
  "$output" "$work" "$published" "$recipe" --check-paths
flutter build macos "${flutter_args[@]}"
python3 "$script_dir/package_macos_shared_build.py" \
  "$repo_dir/build/macos/Build/Products/Release/PiliPlusX.app" \
  "$output" "$work" "$published" "$recipe"
echo "Candidate packaged: $output (visible acceptance pending)"
