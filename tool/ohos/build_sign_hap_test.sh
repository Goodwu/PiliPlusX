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
"$ssh_wrapper" --ssh-opt '-oClearAllForwardings=yes' "$remote_host" -- "$remote_project" "$version" "$build_number" "$keep_permission" "$build_mode" "$remote_media_kit" >"$unsigned" <<'REMOTE'
set -euo pipefail
src=$1
version=$2
build_number=$3
keep_permission=$4
build_mode=$5
remote_media_kit=$6
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
 cd "$build_root"
export PUB_CACHE=/home/wuweiwei1/.pub-cache-ohos-build
 flutter pub get >&2
 python3 "$src/scripts/prepare_ohos_material_ui.py" --workspace "$build_root" >&2
 flutter build hap --"$build_mode" --no-codesign --build-name "$version" --build-number "$build_number" >&2
 hap="$build_root/build/ohos/hap/entry-default-unsigned.hap"
[[ -s $hap ]] || { echo "unsigned HAP was not produced" >&2; exit 1; }
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

echo "[3/3] signed HAP: $output" >&2
if [[ -n $install_target ]]; then
  [[ -x $hdc ]] || { echo "hdc is not executable: $hdc" >&2; exit 1; }
  echo "installing on hdc target $install_target" >&2
  "$hdc" -t "$install_target" install -r "$output"
  "$hdc" -t "$install_target" shell aa force-stop com.example.piliplusx
  "$hdc" -t "$install_target" shell aa start -a EntryAbility -b com.example.piliplusx
fi
