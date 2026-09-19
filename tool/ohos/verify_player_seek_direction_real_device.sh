#!/usr/bin/env bash
set -euo pipefail

# Verify seek direction ownership on a real OHOS device. All swipes are
# injected through uiInput and classified from the Flutter touch trace.
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HDC_BIN=${HDC_BIN:-/Users/wuweiwei1/bin/hdc}
HDC_TARGET=${HDC_TARGET:-2PM0223A18006914}
SOURCE=${VERIFY_SEEK_DIRECTION_SOURCE:-BV1Wp4y1P7KU}
OUT=${VERIFY_SEEK_DIRECTION_OUT:-/tmp/piliplusx-ohos-seek-direction-$(date +%Y%m%d-%H%M%S)}
HAP=

while (($#)); do
  case "$1" in
    --source) SOURCE=${2:?missing value for --source}; shift 2 ;;
    --hap) HAP=${2:?missing value for --hap}; shift 2 ;;
    --out) OUT=${2:?missing value for --out}; shift 2 ;;
    -h|--help)
      echo "Usage: verify_player_seek_direction_real_device.sh [--source BVID] [--hap FILE] [--out DIR]"
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -x "$HDC_BIN" ]] || { echo "HDC not executable: $HDC_BIN" >&2; exit 1; }
if ! "$HDC_BIN" list targets -v 2>/dev/null | awk -v target="$HDC_TARGET" '
  $1 == target && ($2 == "Online" || $3 == "Online" || $4 == "Online" ||
                   $2 == "Connected" || $3 == "Connected" || $4 == "Connected") { found=1 }
  END { exit found ? 0 : 1 }
'; then
  echo "HDC target offline: $HDC_TARGET" >&2
  exit 1
fi
mkdir -p "$OUT"
pause_file="$OUT/continue-after-gestures"
rm -f "$pause_file"
gate_out="$OUT/fullscreen-gate"
mkdir -p "$gate_out"
# No post-stable fullscreen cycle: the gate must remain on the exact stable
# portrait frame while this script injects and classifies all three swipes.
gate_args=(--source "$SOURCE" --vertical --cycles 0 --out "$gate_out")
if [[ -n "$HAP" ]]; then gate_args+=(--hap "$HAP"); fi

VERIFY_REQUIRE_HDR=${VERIFY_REQUIRE_HDR:-0} \
VERIFY_KEEP_SCREEN_ON=${VERIFY_KEEP_SCREEN_ON:-1} \
VERIFY_SCREEN_TIMEOUT_MS=${VERIFY_SCREEN_TIMEOUT_MS:-3600000} \
VERIFY_PAUSE_AFTER_STABLE_FILE="$pause_file" \
  HDC_BIN="$HDC_BIN" HDC_TARGET="$HDC_TARGET" \
  "$SCRIPT_DIR/verify_hdr_real_device.sh" "${gate_args[@]}" &
gate_pid=$!
cleanup() {
  : >"$pause_file"
  if kill -0 "$gate_pid" 2>/dev/null; then kill "$gate_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

stable="$gate_out/08-fullscreen-stable.json"
for _ in $(seq 1 480); do
  [[ -s "$stable" ]] && break
  kill -0 "$gate_pid" 2>/dev/null || break
  sleep 0.25
done
[[ -s "$stable" ]] || { echo "fullscreen stable layout was not produced" >&2; wait "$gate_pid" || true; exit 1; }
sleep 1

read -r x1 y1 x2 y2 < <(python3 - "$stable" <<'PY'
import json, re, sys
root = json.load(open(sys.argv[1], encoding='utf-8'))
rects, sliders = [], []
def walk(node):
    a = node.get('attributes', {})
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', a.get('bounds', ''))
    if m and a.get('type') in {'View', 'Stack', 'NodeContainer'}:
        rect = tuple(map(int, m.groups()))
        if rect[2] - rect[0] >= 800 and rect[3] - rect[1] >= 400:
            rects.append(rect)
    if m and a.get('type') == 'Slider' and a.get('visible') != 'false':
        sliders.append(tuple(map(int, m.groups())))
    for child in node.get('children', []): walk(child)
walk(root)
if not rects: raise SystemExit('no fullscreen video bounds')
x1, y1, x2, y2 = max(rects, key=lambda r: (r[2]-r[0])*(r[3]-r[1]))
if sliders:
    slider_top = min(s[1] for s in sliders)
    if y1 < slider_top < y2: y2 = slider_top
margin = max(120, (y2-y1)//5)
print(x1, y1 + margin, x2, y2 - margin)
PY
)

center_y=$(((y1 + y2) / 2))
diag_start_y=$((center_y + (y2 - y1) / 6))
diag_end_y=$((center_y - (y2 - y1) / 6))
horizontal_start_x=$((x1 + (x2 - x1) / 5))
horizontal_end_x=$((x2 - (x2 - x1) / 5))
center_x=$(((x1 + x2) / 2))

run_swipe() {
  local name="$1" sx="$2" sy="$3" ex="$4" ey="$5"
  local log="$OUT/$name-hilog.txt"
  "$HDC_BIN" -t "$HDC_TARGET" shell hilog -r >"$OUT/$name-hilog-clear.txt"
  timeout 15 "$HDC_BIN" -t "$HDC_TARGET" shell uitest uiInput swipe "$sx" "$sy" "$ex" "$ey" 800 >"$OUT/$name-command.txt" 2>&1
  sleep 1
  # Keep a per-swipe snapshot for diagnosis.  The authoritative Flutter
  # trace is collected from the long-lived gate below: `hilog -x` is a ring
  # snapshot and does not reliably contain the delayed Flutter settings-log
  # forwarding immediately after uiInput returns.
  timeout 20 "$HDC_BIN" -t "$HDC_TARGET" shell hilog -x >"$log" 2>&1 || true
  printf '%s\t(%s,%s)->(%s,%s)\n' "$name" "$sx" "$sy" "$ex" "$ey" >>"$OUT/gestures.tsv"
}

: >"$OUT/gestures.tsv"
run_swipe horizontal "$horizontal_start_x" "$center_y" "$horizontal_end_x" "$center_y"
run_swipe diagonal "$horizontal_start_x" "$diag_start_y" "$horizontal_end_x" "$diag_end_y"
run_swipe vertical "$center_x" "$y2" "$center_x" "$y1"

# Let the long-lived hilog reader receive the delayed Flutter settings-log
# records while the gate is still paused.  Releasing the gate first would add
# its own fullscreen-transition gestures and make positional classification
# ambiguous.
# Flutter settings-log forwarding on the OHOS device is asynchronous; the
# later swipes can arrive in the capture file several seconds after uiInput
# has returned. Wait for the three authoritative decisions rather than using
# a fixed snapshot delay, while keeping a bounded fail-closed timeout.
trace_wait_seconds=${VERIFY_GESTURE_TRACE_WAIT_SECONDS:-30}
trace_decisions=0
for ((trace_second=0; trace_second<trace_wait_seconds; trace_second++)); do
  cp "$gate_out/hilog.txt" "$OUT/gate-hilog-pre-release.txt" 2>/dev/null || true
  trace_decisions="$({ grep -Ec 'gesture move-filter action=' "$OUT/gate-hilog-pre-release.txt" || true; } | tail -n 1)"
  if [[ "$trace_decisions" =~ ^[0-9]+$ ]] && (( trace_decisions >= 3 )); then
    break
  fi
  sleep 1
done
cp "$gate_out/hilog.txt" "$OUT/gate-hilog-pre-release.txt" 2>/dev/null || true
: >"$pause_file"
wait "$gate_pid" 2>/dev/null || true
cp "$gate_out/hilog.txt" "$OUT/gate-hilog.txt" 2>/dev/null || true

gate_log="$OUT/gate-hilog-pre-release.txt"
mapfile -t decisions < <(
  grep -E 'gesture move-filter action=' "$gate_log" |
    sed -E 's/.*gesture move-filter action=([^ ]+).*/\1/' |
    tail -n 3
)
horizontal_ok=0
diagonal_horizontal=0
vertical_horizontal=0
if [[ "${decisions[0]:-}" == horizontal ]]; then
  horizontal_ok=1
fi
if [[ "${decisions[1]:-}" == horizontal ]]; then
  diagonal_horizontal=1
fi
if [[ "${decisions[2]:-}" == horizontal ]]; then
  vertical_horizontal=1
fi

cat "$OUT/gestures.tsv"
echo "horizontal seek records: $horizontal_ok"
echo "diagonal horizontal-seek records: $diagonal_horizontal"
echo "vertical horizontal-seek records: $vertical_horizontal"
echo "direction decisions: ${decisions[*]:-none}"
echo "gesture artifacts: $OUT"
if (( ${#decisions[@]} != 3 )); then
  echo "seek-direction verdict: FAIL (expected exactly three post-stable direction decisions)" >&2
  exit 1
fi
if (( horizontal_ok != 1 )); then
  echo "seek-direction verdict: FAIL (clear horizontal swipe was not classified as seek)" >&2
  exit 1
fi
if (( diagonal_horizontal != 0 || vertical_horizontal != 0 )); then
  echo "seek-direction verdict: FAIL (non-horizontal swipe entered seek)" >&2
  exit 1
fi
echo "seek-direction verdict: PASS (only clear horizontal swipe entered seek)"
