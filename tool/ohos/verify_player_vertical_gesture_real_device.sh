#!/usr/bin/env bash
set -euo pipefail

# Run the normal playing/fullscreen gate and inject both edge gestures while
# its authoritative fullscreen layout still has a live video surface.
# A successful uiInput command is not a gesture pass unless Flutter and the
# brightness/volume path are observable.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HDC_BIN=${HDC_BIN:-/Users/wuweiwei1/bin/hdc}
HDC_TARGET=${HDC_TARGET:-2PM0223A18006914}
SOURCE=${VERIFY_GESTURE_SOURCE:-BV1vY4y1N7TY}
OUT=${VERIFY_GESTURE_OUT:-/tmp/piliplusx-ohos-vertical-gesture-real-device-$(date +%Y%m%d-%H%M%S)}
GESTURE_COMMAND=${VERIFY_GESTURE_COMMAND:-swipe}
GESTURE_REGION=${VERIFY_GESTURE_REGION:-edge}
GESTURE_PHASE=${VERIFY_GESTURE_PHASE:-fullscreen}
VERTICAL_VIDEO=${VERIFY_VERTICAL_VIDEO:-0}
HAP=

while (($#)); do
  case "$1" in
    --source) SOURCE=${2:?missing value for --source}; shift 2 ;;
    --out) OUT=${2:?missing value for --out}; shift 2 ;;
    --region) GESTURE_REGION=${2:?missing value for --region}; shift 2 ;;
    --phase) GESTURE_PHASE=${2:?missing value for --phase}; shift 2 ;;
    --vertical) VERTICAL_VIDEO=1; shift ;;
    --hap) HAP=${2:?missing value for --hap}; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: verify_player_vertical_gesture_real_device.sh [--source BVID] [--hap FILE] [--out DIR]
       [--region edge|center] [--phase windowed|fullscreen] [--vertical]

Runs one playing Dolby Vision fullscreen cycle, waits for its fullscreen-stable
layout, then injects left and right vertical drags using derived coordinates.
It records evidence and does not claim hardware brightness/volume success from
uiInput alone. edge probes the portrait edge policy; center probes the
single-pointer fullscreen gesture path. --vertical asserts that the source
metadata is confirmed vertical and is passed to the fullscreen gate in either
phase.
USAGE
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$GESTURE_REGION" in
  edge|center) ;;
  *) echo "invalid --region: $GESTURE_REGION (expected edge or center)" >&2; exit 2 ;;
esac
case "$GESTURE_PHASE" in
  windowed|fullscreen) ;;
  *) echo "invalid --phase: $GESTURE_PHASE (expected windowed or fullscreen)" >&2; exit 2 ;;
esac
case "$VERTICAL_VIDEO" in
  0|1) ;;
  *) echo "invalid --vertical/VERIFY_VERTICAL_VIDEO: $VERTICAL_VIDEO" >&2; exit 2 ;;
esac
GATE_VERTICAL_ARGS=()
GATE_HAP_ARGS=()
GATE_BEFORE_FILE=
if [[ "$VERTICAL_VIDEO" == 1 ]]; then
  GATE_VERTICAL_ARGS=(--vertical)
fi
if [[ -n "$HAP" ]]; then
  GATE_HAP_ARGS=(--hap "$HAP")
fi
if [[ "$GESTURE_PHASE" == windowed ]]; then
  GATE_BEFORE_FILE="$OUT/continue-before-fullscreen"
fi

[[ -x "$HDC_BIN" ]] || { echo "HDC not executable: $HDC_BIN" >&2; exit 1; }
mkdir -p "$OUT"
if ! "$HDC_BIN" list targets -v 2>/dev/null | awk -v target="$HDC_TARGET" '
  $1 == target && ($2 == "Online" || $3 == "Online" || $4 == "Online" ||
                   $2 == "Connected" || $3 == "Connected" || $4 == "Connected") { found=1 }
  END { exit found ? 0 : 1 }
'; then
  echo "HDC target offline: $HDC_TARGET" >&2
  exit 1
fi

gate_out="$OUT/fullscreen-gate"
mkdir -p "$gate_out"
VERIFY_REQUIRE_HDR=${VERIFY_REQUIRE_HDR:-0} \
VERIFY_KEEP_SCREEN_ON=${VERIFY_KEEP_SCREEN_ON:-1} \
VERIFY_SCREEN_TIMEOUT_MS=${VERIFY_SCREEN_TIMEOUT_MS:-3600000} \
VERIFY_PAUSE_AFTER_STABLE_FILE="$OUT/continue-after-gesture" \
VERIFY_PAUSE_BEFORE_FULLSCREEN_FILE="$GATE_BEFORE_FILE" \
  HDC_BIN="$HDC_BIN" HDC_TARGET="$HDC_TARGET" \
  "$SCRIPT_DIR/verify_hdr_real_device.sh" --source "$SOURCE" "${GATE_HAP_ARGS[@]}" "${GATE_VERTICAL_ARGS[@]}" \
  --cycles 1 --out "$gate_out" &
gate_pid=$!
cleanup() {
  if kill -0 "$gate_pid" 2>/dev/null; then
    kill "$gate_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$GESTURE_PHASE" == windowed ]]; then
  stable="$gate_out/06-controls-click.json"
else
  stable="$gate_out/08-fullscreen-stable.json"
fi
for _ in $(seq 1 480); do
  [[ -s "$stable" ]] && break
  kill -0 "$gate_pid" 2>/dev/null || break
  sleep 0.25
done
[[ -s "$stable" ]] || {
  echo "gesture phase layout was not produced: $stable" >&2
  wait "$gate_pid" || true
  exit 1
}

read -r left_x right_x center_x top bottom < <(
  python3 - "$stable" <<'PY'
import json
import re
import sys

root = json.loads(open(sys.argv[1], encoding='utf-8').read())
rects = []
sliders = []
def walk(node):
    attrs = node.get('attributes', {})
    bounds = attrs.get('bounds', '')
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
    if m and attrs.get('type') == 'Slider' and attrs.get('visible') != 'false':
        sliders.append(tuple(map(int, m.groups())))
    if m and attrs.get('type') in {'View', 'Stack', 'NodeContainer'}:
        x1, y1, x2, y2 = map(int, m.groups())
        if x2 - x1 >= 800 and y2 - y1 >= 400:
            rects.append((x1, y1, x2, y2))
    for child in node.get('children', []):
        walk(child)
walk(root)
if not rects:
    raise SystemExit('no fullscreen video bounds in stable layout')
x1, y1, x2, y2 = max(rects, key=lambda r: (r[2]-r[0])*(r[3]-r[1]))
if sliders:
    slider_top = min(item[1] for item in sliders)
    if y1 < slider_top < y2:
        y2 = slider_top
margin_x = max(80, (x2-x1)//20)
left = x1 + margin_x
right = x2 - margin_x
center = (x1 + x2) // 2
top = y1 + max(160, (y2-y1)//5)
bottom = y2 - max(160, (y2-y1)//5)
if not (x1 < left < x2 and x1 < right < x2 and y1 < top < bottom < y2):
    raise SystemExit(f'unsafe derived gesture coordinates: {(x1,y1,x2,y2)}')
print(left, right, center, top, bottom)
PY
)

if [[ "$GESTURE_REGION" == center ]]; then
  left_x=$center_x
  right_x=$center_x
fi

{
  echo "source=$SOURCE"
  echo "vertical=$VERTICAL_VIDEO"
  echo "region=$GESTURE_REGION"
  echo "stable_layout=$stable"
  echo "left: ($left_x,$bottom)->($left_x,$top)"
  echo "right: ($right_x,$bottom)->($right_x,$top)"
} >"$OUT/gesture-commands.txt"
cp "$stable" "$OUT/layout-before-gesture.json"

"$HDC_BIN" -t "$HDC_TARGET" shell hilog -r >"$OUT/hilog-clear.txt"
timeout 15 "$HDC_BIN" -t "$HDC_TARGET" shell uitest uiInput "$GESTURE_COMMAND" \
  "$left_x" "$bottom" "$left_x" "$top" 800 >"$OUT/left-command.txt" 2>&1
timeout 15 "$HDC_BIN" -t "$HDC_TARGET" shell uitest uiInput "$GESTURE_COMMAND" \
  "$right_x" "$bottom" "$right_x" "$top" 800 >"$OUT/right-command.txt" 2>&1
sleep 1
if "$HDC_BIN" -t "$HDC_TARGET" shell uitest dumpLayout -p /data/local/tmp/piliplusx-gesture-layout.json >/dev/null &&
   "$HDC_BIN" -t "$HDC_TARGET" file recv /data/local/tmp/piliplusx-gesture-layout.json \
     "$OUT/layout-after-gesture.json" >/dev/null; then
  :
else
  echo "warning: could not capture immediate post-gesture layout" >&2
fi
timeout 20 "$HDC_BIN" -t "$HDC_TARGET" shell hilog -x >"$OUT/hilog-gesture.txt" 2>&1 || true

# Keep the paused gate alive while the gesture events are flushed into its
# hilog stream. Releasing it after the probes preserves the same-process event
# trace; its later fullscreen-cycle result is diagnostic only and must not
# prevent this script from classifying the already-injected gesture.
: >"$OUT/continue-before-fullscreen"
: >"$OUT/continue-after-gesture"
wait "$gate_pid" 2>/dev/null || true
cp "$gate_out/hilog.txt" "$OUT/gate-hilog.txt" 2>/dev/null || true
cat "$OUT/gesture-commands.txt"
echo "gesture artifacts: $OUT"
echo "--- observable gesture records ---"
rg -n 'FlutterSurface (area|touch)|PlayerTouchTrace|setVolume|setBrightness|brightness|volume|hcpp_input.*(Down|Move|Up|Cancel)' \
  "$OUT/hilog-gesture.txt" "$OUT/gate-hilog.txt" 2>/dev/null || true

gesture_log="$OUT/gate-hilog.txt"
if [[ "$GESTURE_REGION" == center ]]; then
  if grep -Eq 'accept-single-pointer.*action=.*fullScreen' "$gesture_log" &&
     grep -Eq 'gesture pan-start action=.*fullScreen' "$gesture_log" &&
     grep -Fq 'gesture pan-update type=fullscreen' "$gesture_log"; then
    echo "gesture verdict: PASS (player accepted center vertical gesture)"
  else
    echo "gesture verdict: NOT OBSERVED (center gesture lacked player acceptance/pan callback)" >&2
    exit 1
  fi
else
  if grep -Fq 'gesture move-filter action=reject-portrait-edge' "$gesture_log"; then
    echo "gesture verdict: PASS (portrait edge gesture explicitly rejected by player policy)"
  else
    echo "gesture verdict: NOT OBSERVED (portrait edge rejection not recorded)" >&2
    exit 1
  fi
fi
