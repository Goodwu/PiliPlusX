#!/usr/bin/env bash
set -euo pipefail

# Build an unsigned HAP on dev, temporarily remove permissions which are not
# present in the local debug profile, then sign it locally with 小白调试助手.
# The remote source tree is restored by trap before this script exits.

usage() {
  cat <<'USAGE'
Usage:
  tool/ohos/build_sign_hap_test.sh [options]

Options:
  --version NAME          HAP version name (default: 2.1.3)
  --build-number NUMBER   HAP version code (default: current timestamp)
  --build-mode MODE       Flutter build mode: debug or release (default: debug)
  --dart-define DEFINE    Flutter dart-define passed to the remote build (repeatable)
  --output FILE           Signed HAP output path
  --remote-host HOST      SSH host (default: dev)
  --remote-project DIR    Remote PiliPlusX checkout
  --profile FILE           Signing profile
  --cert FILE              Signing certificate
  --key FILE               Signing private key
  --signer FILE            HarmonyOS signer executable
  --config FILE            JSON config containing keystorePwd
  --install TARGET         Install and start on hdc target after signing
  --keep-permission        Do not remove WRITE_IMAGEVIDEO for the test build
  -h, --help               Show this help
USAGE
}

ssh_wrapper=${SSH_REMOTE_EXEC_WRAPPER:-/Users/wuweiwei1/.codex/skills/ssh-remote-exec/scripts/ssh-remote-exec.sh}
sync_script=${OHOS_SYNC_SCRIPT:-$(dirname "$0")/sync_ohos_workspace.sh}
hdc=${HDC:-/Users/wuweiwei1/bin/hdc}
remote_host=${REMOTE_HOST:-dev}
remote_project=${REMOTE_PROJECT:-/home/wuweiwei1/PiliPlusX-ohos-344}
remote_media_kit=${REMOTE_MEDIA_KIT:-/home/wuweiwei1/media-kit-ohos}
version=${HAP_VERSION:-2.1.3}
build_number=${HAP_BUILD_NUMBER:-$(date +%s)}
build_mode=${HAP_BUILD_MODE:-debug}
install_target=
keep_permission=0
dart_defines=()

store_dir=${XIAOBAI_STORE_DIR:-$HOME/Documents/hap_installer/store}
signer=${XIAOBAI_SIGNER:-$HOME/Downloads/小白调试助手.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/macos/signer}
cert=${XIAOBAI_CERT:-$store_dir/xiaobai-debug.cer}
profile=${XIAOBAI_PROFILE:-$store_dir/com_example_piliplusx.p7b}
key=${XIAOBAI_KEY:-$store_dir/key.pem}
config=${XIAOBAI_SIGN_CONFIG:-$HOME/Documents/hap_installer/signConfig.json}
output=${HAP_OUTPUT:-$HOME/Downloads/PiliPlusX-ohos-xiaobai-${version}-signed.hap}

while (($#)); do
  case "$1" in
    --version) version=${2:?missing value for --version}; shift 2 ;;
    --build-number) build_number=${2:?missing value for --build-number}; shift 2 ;;
    --build-mode) build_mode=${2:?missing value for --build-mode}; shift 2 ;;
    --dart-define) dart_defines+=("${2:?missing value for --dart-define}"); shift 2 ;;
    --output) output=${2:?missing value for --output}; shift 2 ;;
    --remote-host) remote_host=${2:?missing value for --remote-host}; shift 2 ;;
    --remote-project) remote_project=${2:?missing value for --remote-project}; shift 2 ;;
    --profile) profile=${2:?missing value for --profile}; shift 2 ;;
    --cert) cert=${2:?missing value for --cert}; shift 2 ;;
    --key) key=${2:?missing value for --key}; shift 2 ;;
    --signer) signer=${2:?missing value for --signer}; shift 2 ;;
    --config) config=${2:?missing value for --config}; shift 2 ;;
    --install) install_target=${2:?missing value for --install}; shift 2 ;;
    --keep-permission) keep_permission=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "invalid version: $version" >&2; exit 2;
}
[[ $build_number =~ ^[0-9]+$ ]] || { echo "invalid build number" >&2; exit 2; }
[[ $build_mode == debug || $build_mode == release ]] || {
  echo "invalid build mode: $build_mode" >&2; exit 2;
}
for define in "${dart_defines[@]}"; do
  if [[ "$define" == PILIPLUS_PROCESS_LIVE_TEST=true && "$build_mode" != debug ]]; then
    echo "PILIPLUS_PROCESS_LIVE_TEST is restricted to debug HAPs" >&2
    exit 2
  fi
  if [[ "$define" == PILIPLUS_PROCESS_LIVE_DIRECT_PAGE_POP=true && "$build_mode" != debug ]]; then
    echo "PILIPLUS_PROCESS_LIVE_DIRECT_PAGE_POP is restricted to debug HAPs" >&2
    exit 2
  fi
done
for required in "$ssh_wrapper" "$signer" "$cert" "$profile" "$key" "$config"; do
  [[ -e $required ]] || { echo "missing required file: $required" >&2; exit 1; }
done
[[ -x $sync_script ]] || { echo "OHOS sync script is not executable: $sync_script" >&2; exit 1; }

"$sync_script" --remote-host "$remote_host" --remote-project "$remote_project"

mkdir -p "$(dirname "$output")"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/piliplusx-hap.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
unsigned="$work_dir/entry-default-unsigned.hap"
rm -f "$output"

echo "[1/3] build unsigned HAP on $remote_host: $version/$build_number" >&2
"$ssh_wrapper" --ssh-opt '-oClearAllForwardings=yes' "$remote_host" -- "$remote_project" "$version" "$build_number" "$keep_permission" "$build_mode" "$remote_media_kit" "${dart_defines[@]}" >"$unsigned" <<'REMOTE'
set -euo pipefail
src=$1
version=$2
build_number=$3
keep_permission=$4
build_mode=$5
remote_media_kit=$6
shift 6
dart_define_args=()
while (($#)); do
  dart_define_args+=(--dart-define "$1")
  shift
done
build_parent=$(mktemp -d "${TMPDIR:-/tmp}/piliplusx-ohos-build.XXXXXX")
 build_root="$build_parent/workspace"
 cleanup() { rm -rf "$build_parent"; }
 trap cleanup EXIT

python3 "$src/scripts/prepare_ohos_build.py" \
  --workspace "$src" \
  --output "$build_root" \
  --media-kit-source "$remote_media_kit" >&2
python3 "$src/scripts/prepare_ohos_flutter.py" \
  --flutter-root /home/wuweiwei1/tools/flutter-ohos \
  --workspace "$src" >&2
 module="$build_root/ohos/entry/src/main/module.json5"
 backup="$module.codex-hap-test-backup"

[[ -d $src && -f $module ]] || { echo "remote project/module not found" >&2; exit 1; }
cp "$module" "$backup"
restore() { if [[ -f $backup ]]; then mv "$backup" "$module"; fi; }
# Keep both cleanup actions: replacing the earlier trap leaked the complete
# remote build tree after every successful or failed build.
trap 'restore; cleanup' EXIT

if [[ $keep_permission != 1 ]]; then
  python3 - "$module" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()
pattern = r'      \{\n        name: "ohos\.permission\.WRITE_IMAGEVIDEO",.*?\n      \},\n(?=      \{\n        name:)'
s, count = re.subn(pattern, '', s, count=1, flags=re.S)
if count not in (0, 1):
    raise SystemExit(f'unexpected WRITE_IMAGEVIDEO block count: {count}')
p.write_text(s)
PY
fi

export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export HOS_SDK_HOME=/home/wuweiwei1/ohos-sdk/command-line-tools/sdk
export OHOS_SDK_HOME=$HOS_SDK_HOME
export PATH=/home/wuweiwei1/tools/flutter-ohos/bin:/home/wuweiwei1/flutter/bin:/home/wuweiwei1/ohos-sdk/command-line-tools/bin:/home/wuweiwei1/ohos-sdk/hvigor/bin:/home/wuweiwei1/ohos-sdk/hvigor/bin:/home/wuweiwei1/ohos-sdk/command-line-tools/tool/node/bin:$PATH
export PUB_CACHE=/home/wuweiwei1/.pub-cache-ohos-build

# Build the reviewed embedding HAR before the app build.  Flutter's OHOS
# builder consumes mode-specific cached HARs, so changing ETS source alone can
# silently leave the final HAP on the old modules.abc.  Merge only the
# embedding source/type trees into the cached HAR and preserve its native
# libflutter.so and release module metadata.  Every replacement gets a
# recoverable backup in the SDK directory.
embedding_project=/home/wuweiwei1/tools/flutter-ohos/engine/src/flutter/shell/platform/ohos/flutter_embedding
embedding_hvigor=/home/wuweiwei1/ohos-sdk/command-line-tools/hvigor/bin/hvigorw
embedding_har="$embedding_project/flutter/build/default/outputs/default/flutter.har"
export DEVECO_SDK_HOME=/home/wuweiwei1/ohos-sdk/command-line-tools/sdk
if [[ -x $embedding_hvigor && -d $embedding_project/flutter ]]; then
  # Apply the reviewed production embedding patch set. Native source changes
  # remain opt-in until a matching libflutter.so build is verified.
  flutter_root=/home/wuweiwei1/tools/flutter-ohos
  python3 "$src/scripts/prepare_ohos_embedding.py" \
    --flutter-root "$flutter_root" \
    --workspace "$src" >&2
  # Hvigor can keep the embedding HAR's modules.abc as UP-TO-DATE even after
  # the external ETS source was patched.  Remove only this generated module
  # output so the next assembleHar recompiles the reviewed source; source and
  # native engine files are untouched.
  rm -rf "$embedding_project/flutter/build/default"
  echo "building OHOS embedding HAR: $embedding_project" >&2
  (cd "$embedding_project" && "$embedding_hvigor" --mode module \
    -p module=flutter@default -p product=default assembleHar --no-daemon) >&2
  [[ -s $embedding_har ]] || {
    echo "embedding HAR was not produced: $embedding_har" >&2
    exit 1
  }

  merge_embedding_har() {
    local cached_har="$1"
    local backup="${cached_har}.codex-hcpp-premerge"
    local work new_work
    [[ -f $cached_har ]] || return 0
    [[ -e $backup ]] || cp -p "$cached_har" "$backup"
    work=$(mktemp -d /tmp/flutter-hcpp-har-merge.XXXXXX)
    new_work=$(mktemp -d /tmp/flutter-hcpp-har-new.XXXXXX)
    gzip -cd "$cached_har" | tar -xf - -C "$work"
    gzip -cd "$embedding_har" | tar -xf - -C "$new_work"
    rm -rf "$work/package/src/main/ets" "$work/package/src/main/cpp/types"
    cp -a "$new_work/package/src/main/ets" "$work/package/src/main/"
    cp -a "$new_work/package/src/main/cpp/types" "$work/package/src/main/cpp/"
    tar -C "$work" -cf - package | gzip -n >"$cached_har.tmp"
    mv "$cached_har.tmp" "$cached_har"
    rm -rf "$work" "$new_work"
    local marker_strings
    marker_strings=$(mktemp)
    gzip -cd "$cached_har" | strings >"$marker_strings"
    if ! grep -Fq HcppInputRect "$marker_strings"; then
      rm -f "$marker_strings"
      echo "merged HAR missing HCPP marker: $cached_har" >&2
      exit 1
    fi
    rm -f "$marker_strings"
    echo "OHOS embedding HAR synchronized: $cached_har" >&2
  }

  embedding_sdk=/home/wuweiwei1/tools/flutter-ohos/bin/cache/artifacts/engine
  merge_embedding_har "$embedding_sdk/ohos-arm64/flutter.har"
  merge_embedding_har "$embedding_sdk/ohos-arm64/flutter_embedding_debug.har"
  merge_embedding_har "$embedding_sdk/ohos-arm64-release/flutter.har"
  merge_embedding_har "$embedding_sdk/ohos-arm64-profile/flutter.har"
else
  echo "OHOS embedding build prerequisites missing; refusing stale-HAR build" >&2
  exit 1
fi

cd "$build_root"
flutter pub get >&2
python3 "$src/scripts/prepare_ohos_package_patches.py" --workspace "$build_root" >&2
python3 "$src/scripts/prepare_ohos_material_ui.py" --workspace "$build_root" >&2
# The OHOS package is expanded from the cached HAR into the temporary build
# workspace.  The checked-out flutter-ohos source is not automatically used by
# that expansion, so inject the reviewed embedding files into the exact
# package root that Hvigor will compile.  Without this step source-level SHA
# checks can pass while the HAP still contains the old modules.abc.
# Hvigor may resolve the package through the versioned .ohpm store or through
# the entry module's linked oh_modules tree.  Synchronize every resolved copy;
# checking only .ohpm can leave modules.abc on a stale package while source/HAR
# checks still pass.
mapfile -t flutter_ohos_pkgs < <(find -L "$build_root/ohos" \
  -type d -path '*/oh_modules/@ohos/flutter_ohos' -print | sort -u)
(( ${#flutter_ohos_pkgs[@]} > 0 )) || {
  echo "expanded @ohos/flutter_ohos package not found after flutter pub get" >&2
  exit 1
}
flutter_ohos_src="$flutter_root/engine/src/flutter/shell/platform/ohos/flutter_embedding/flutter"
for flutter_ohos_pkg in "${flutter_ohos_pkgs[@]}"; do
  for rel in \
    src/main/ets/plugin/platform/PlatformViewsControllerHybrid.ets \
    src/main/ets/embedding/ohos/FlutterPage.ets \
    src/main/ets/view/DynamicView/dynamicView.ets \
    src/main/ets/view/FlutterView.ets \
    src/main/cpp/types/libflutter/index.d.ets; do
    src_file="$flutter_ohos_src/$rel"
    dst_file="$flutter_ohos_pkg/$rel"
    [[ -f "$src_file" && -f "$dst_file" ]] || {
      echo "HCPP embedding source/package file missing: $rel ($flutter_ohos_pkg)" >&2
      exit 1
    }
    cp "$src_file" "$dst_file"
    cmp -s "$src_file" "$dst_file" || {
      echo "HCPP embedding sync verification failed: $rel ($flutter_ohos_pkg)" >&2
      exit 1
    }
done
echo "OHOS embedding package synchronized: $flutter_ohos_pkg" >&2
done
# The temporary workspace is fresh, but Flutter/Hvigor can still carry a
# generated entry build directory from package preparation.  Remove only
# those generated directories so HarCompileArkTS cannot reuse an abc compiled
# before the reviewed embedding source was injected.
rm -rf "$build_root/ohos/entry/build" "$build_root/ohos/build"
echo "OHOS generated build outputs cleared before HAP compile" >&2
 flutter build hap --"$build_mode" --no-codesign --build-name "$version" --build-number "$build_number" "${dart_define_args[@]}" >&2
 hap="$build_root/build/ohos/hap/entry-default-unsigned.hap"
[[ -s $hap ]] || { echo "unsigned HAP was not produced" >&2; exit 1; }
abc_strings=$(mktemp)
unzip -p "$hap" ets/modules.abc | strings >"$abc_strings"
for marker in HcppInputRect hcpp_input_rects_map attachmentEpoch stale-attachment; do
  if ! grep -Fq "$marker" "$abc_strings"; then
    echo "unsigned HAP modules.abc missing required HCPP marker: $marker" >&2
    echo "HCPP package diagnostics before cleanup:" >&2
    find -L "$build_root/ohos/oh_modules/.ohpm" -type d \
      -path '*/oh_modules/@ohos/flutter_ohos' -print 2>/dev/null | sort -u >&2 || true
    find "$build_root/ohos/entry/build" -name dep_info.json -print \
      -exec grep -o '"@ohos/flutter_ohos":"[^"]*"' {} \; 2>/dev/null >&2 || true
    exit 1
  fi
done
echo "unsigned HAP modules.abc HCPP markers: present" >&2
cat "$hap"
REMOTE

[[ -s $unsigned ]] || { echo "downloaded unsigned HAP is empty" >&2; exit 1; }
echo "[2/3] sign and verify locally" >&2
password=$(sed -n 's/.*"keystorePwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config")
[[ -n $password ]] || { echo "keystorePwd not found in config" >&2; exit 1; }

"$signer" sign-app \
  -mode localSign \
  -keyAlias xiaobai \
  -appCertFile "$cert" \
  -profileFile "$profile" \
  -inFile "$unsigned" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$key" \
  -keystorePwd "$password" \
  -outFile "$output" \
  -compatibleVersion 15 \
  -signCode 1 >&2
[[ -s $output ]] || { echo "signed HAP was not produced" >&2; exit 1; }
"$signer" verify-app -inFile "$output" >&2

# Keep a durable, local identity record next to every signed HAP.  The HAP
# itself is the runtime artifact; these hashes make it possible to distinguish
# a newly signed package from an older package that happens to use the same
# filename, and keep the ABC/native markers auditable after the build workspace
# has been cleaned up.
manifest="${output}.manifest.txt"
abc_manifest=$(mktemp)
trap 'rm -rf "$work_dir" "$abc_manifest"' EXIT
unzip -p "$output" ets/modules.abc | strings >"$abc_manifest"
{
  echo "hap=$output"
  echo "hap_sha256=$(shasum -a 256 "$output" | awk '{print $1}')"
  echo "libflutter_sha256=$(unzip -p "$output" libs/arm64-v8a/libflutter.so | shasum -a 256 | awk '{print $1}')"
  echo "libmpv_sha256=$(unzip -p "$output" libs/arm64-v8a/libmpv.so | shasum -a 256 | awk '{print $1}')"
  echo "abc_sha256=$(unzip -p "$output" ets/modules.abc | shasum -a 256 | awk '{print $1}')"
  echo "abc_marker_HcppInputRect=$(grep -Fc HcppInputRect "$abc_manifest" || true)"
  echo "abc_marker_hcpp_input_rects_map=$(grep -Fc hcpp_input_rects_map "$abc_manifest" || true)"
  echo "abc_marker_attachmentEpoch=$(grep -Fc attachmentEpoch "$abc_manifest" || true)"
  echo "abc_marker_stale_attachment=$(grep -Fc stale-attachment "$abc_manifest" || true)"
  echo "abc_marker_cancelTimestamp=$(grep -Fc cancelTimestamp "$abc_manifest" || true)"
  echo "native_diagnostic_markers=$(grep -E 'OHOS color contract|OHOS color hint after set_color|OHOS target mapping|OHOS consumer color mismatch' <(unzip -p "$output" libs/arm64-v8a/libmpv.so | strings) | tr '\n' ';')"
} >"$manifest"
echo "artifact manifest: $manifest" >&2

echo "[3/3] signed HAP: $output" >&2
if [[ -n $install_target ]]; then
  [[ -x $hdc ]] || { echo "hdc is not executable: $hdc" >&2; exit 1; }
  echo "installing on hdc target $install_target" >&2
  "$hdc" -t "$install_target" install -r "$output"
  "$hdc" -t "$install_target" shell aa force-stop com.example.piliplusx
  "$hdc" -t "$install_target" shell aa start -a EntryAbility -b com.example.piliplusx
fi
