#!/usr/bin/env bash
set -euo pipefail

# Lifecycle diagnostic only. The swipe is intentionally started while the
# video is playing. A frozen-frame run cannot reproduce the historical gray
# fullscreen failure and must not be used as its regression gate. The
# force-stop below is a cold-restart control: a killed process is not expected
# to deliver a Flutter Cancel to its old Dart isolate.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$SCRIPT_DIR/verify_hdr_real_device.sh"
LAYOUT_TOOL="$SCRIPT_DIR/ohos_ui_layout.py"
TARGET="${HDC_TARGET:-2PM0223A18006914}"
HDC="${HDC_BIN:-$HOME/.local/harmony-tools/bin/hdc}"
PACKAGE="com.example.piliplusx"
SOURCE=""
HAP=""
OUT="${VERIFY_OUT_DIR:-/tmp/piliplusx-ohos-surface-recreate-$(date +%Y%m%d-%H%M%S)}"
TIMEOUT_BIN="${VERIFY_HDC_TIMEOUT_BIN:-$(command -v gtimeout || command -v timeout || true)}"
COMMAND_TIMEOUT="${VERIFY_HDC_COMMAND_TIMEOUT:-60}"

while (($#)); do
  case "$1" in
    --source) SOURCE="${2:?missing source}"; shift 2 ;;
    --hap) HAP="${2:?missing hap}"; shift 2 ;;
    --out) OUT="${2:?missing output directory}"; shift 2 ;;
    -h|--help)
      echo "usage: verify_surface_recreate_real_device.sh --source <BVID> [--hap FILE] [--out DIR]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$SOURCE" ]] || { echo "--source is required" >&2; exit 2; }
[[ -x "$HDC" ]] || { echo "HDC not executable: $HDC" >&2; exit 1; }
if ! "$HDC" list targets -v 2>/dev/null | awk -v target="$TARGET" '
  $1 == target && ($2 == "Online" || $3 == "Online" || $4 == "Online" ||
                   $2 == "Connected" || $3 == "Connected" || $4 == "Connected") { found=1 }
  END { exit found ? 0 : 1 }
'; then
  echo "HDC target is not connected: $TARGET (set HDC_TARGET explicitly for another device)" >&2
  exit 1
fi
mkdir -p "$OUT"

run_hdc() {
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" --signal=TERM --kill-after=2 "$COMMAND_TIMEOUT" "$HDC" -t "$TARGET" "$@"
  else
    "$HDC" -t "$TARGET" "$@"
  fi
}

# Establish a known playing, landscape state and keep its evidence separate
# from this lifecycle experiment.
BASE_OUT="$OUT/continuous-baseline"
baseline_args=(--source "$SOURCE" --cycles 1 --out "$BASE_OUT")
[[ -n "$HAP" ]] && baseline_args+=(--hap "$HAP")
VERIFY_RESET_PLAYBACK_START=1 VERIFY_ALLOW_VISUAL_PLAYBACK=1 "$VERIFY" "${baseline_args[@]}"

run_hdc shell hilog -r >/dev/null 2>&1 || true
run_hdc shell hilog >"$OUT/lifecycle-hilog.txt" 2>&1 &
HILOG_PID=$!
cleanup() {
  kill "$HILOG_PID" 2>/dev/null || true
  wait "$HILOG_PID" 2>/dev/null || true
}
trap cleanup EXIT

# The baseline leaves the app in landscape with the source playing. Resolve a
# point from the current layout, then hold a slow drag while force-stopping the
# app. This records the cold-restart/surface identity boundary; it does not
# claim that the old Flutter isolate received Cancel.
REMOTE_LAYOUT="/data/local/tmp/piliplusx-surface-recreate-layout.json"
LOCAL_LAYOUT="$OUT/before-recreate.json"
run_hdc shell uitest dumpLayout -p "$REMOTE_LAYOUT" >/dev/null
run_hdc file recv "$REMOTE_LAYOUT" "$LOCAL_LAYOUT" >/dev/null
read -r x1 y1 _ < <(python3 "$LAYOUT_TOOL" video-wake "$LOCAL_LAYOUT")
x2=$((x1 + 360))
y2=$((y1 + 80))
printf 'pointer-experiment start=(%s,%s) end=(%s,%s) duration=%s\n' \
  "$x1" "$y1" "$x2" "$y2" "${VERIFY_POINTER_DURATION_MS:-8000}" \
  | tee "$OUT/experiment.txt"

run_hdc shell uitest uiInput swipe "$x1" "$y1" "$x2" "$y2" \
  "${VERIFY_POINTER_DURATION_MS:-8000}" >/dev/null 2>&1 &
SWIPE_PID=$!
sleep "${VERIFY_RECREATE_DELAY:-0.6}"
run_hdc shell aa force-stop "$PACKAGE" >/dev/null 2>&1 || true
run_hdc shell aa start -a EntryAbility -b "$PACKAGE" >/dev/null
wait "$SWIPE_PID" 2>/dev/null || true
sleep "${VERIFY_RECREATE_SETTLE:-8}"

# Capture the new process/layout without starting a second verifier run. The
# verifier itself force-stops/starts the app, which would otherwise mix a
# second cold start into this experiment and make the lifecycle timestamps
# ambiguous. Continuous-playback re-entry is a separate gate.
run_hdc shell pidof "$PACKAGE" >"$OUT/reentry-pid.txt" 2>&1 || true
run_hdc shell uitest dumpLayout -p /data/local/tmp/piliplusx-surface-recreate-reentry.json \
  >/dev/null 2>&1 || true
run_hdc file recv /data/local/tmp/piliplusx-surface-recreate-reentry.json \
  "$OUT/reentry-layout.json" >/dev/null 2>&1 || true
run_hdc shell snapshot_display -f /data/local/tmp/piliplusx-surface-recreate-reentry.jpeg \
  >/dev/null 2>&1 || true
run_hdc file recv /data/local/tmp/piliplusx-surface-recreate-reentry.jpeg \
  "$OUT/reentry.jpeg" >/dev/null 2>&1 || true
run_hdc shell hilog -x >"$OUT/reentry-hilog.txt" 2>&1 || true

grep -E 'nativeSurface|surface|Cancel|cancel|destroy|recreate|HDR decision' \
  "$OUT/lifecycle-hilog.txt" "$OUT/reentry-hilog.txt" \
  >"$OUT/lifecycle-relevant.log" || true
echo "lifecycle experiment complete: $OUT"
echo "interpretation: cold-restart/surface evidence only; old-process Cancel is not expected, and this is not a frozen-frame gray-screen verdict"
