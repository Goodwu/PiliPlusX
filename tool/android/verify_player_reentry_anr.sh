#!/usr/bin/env bash
set -euo pipefail

# Exercise the Android playback ANR sequence without manual gaps: re-enter a
# real video, touch the player while it is still playing, wait past Android's
# input-ANR threshold, then return to the feed and repeat.  UI coordinates for
# the feed card are derived from a fresh accessibility dump; the player touch
# is deliberately the known failing point from the captured ANR.

ADB_BIN=${ADB_BIN:-adb}
ADB_SERIAL=${ADB_SERIAL:-emulator-5554}
PACKAGE=${VERIFY_ANDROID_PACKAGE:-com.example.piliplusx}
ACTIVITY=${VERIFY_ANDROID_ACTIVITY:-.MainActivity}
BVID=${VERIFY_ANDROID_BVID:-BV1T7t96BECu}
CYCLES=${VERIFY_ANDROID_CYCLES:-5}
OUT=${VERIFY_ANDROID_OUT:-/tmp/piliplusx-android-reentry-anr-$(date +%Y%m%d-%H%M%S)}
PLAY_START_WAIT=${VERIFY_ANDROID_PLAY_START_WAIT:-3}
FRAME_PROBE_WAIT=${VERIFY_ANDROID_FRAME_PROBE_WAIT:-1}
FRAME_READY_ATTEMPTS=${VERIFY_ANDROID_FRAME_READY_ATTEMPTS:-12}
ANR_WAIT=${VERIFY_ANDROID_ANR_WAIT:-7}
RETURN_WAIT=${VERIFY_ANDROID_RETURN_WAIT:-2}
PLAYER_TOUCH_X=${VERIFY_ANDROID_PLAYER_TOUCH_X:-375}
PLAYER_TOUCH_Y=${VERIFY_ANDROID_PLAYER_TOUCH_Y:-330}

usage() {
  cat <<'USAGE'
Usage: verify_player_reentry_anr.sh [--cycles N] [--out DIR]

Runs an already-installed Android build through repeated fixed-video -> player
touch -> feed transitions.  The video is opened through the app's registered
`bilibili://video/<BVID>` route so a mutable recommendation feed cannot change
the source under test. It fails closed on an ANR or missing live video frames.
Environment overrides: ADB_BIN, ADB_SERIAL, VERIFY_ANDROID_{PACKAGE,ACTIVITY,
BVID,CYCLES,OUT,PLAY_START_WAIT,FRAME_PROBE_WAIT,ANR_WAIT,RETURN_WAIT,
FRAME_READY_ATTEMPTS,PLAYER_TOUCH_X,PLAYER_TOUCH_Y}.
USAGE
}

while (($#)); do
  case "$1" in
    --cycles) CYCLES=${2:?missing value}; shift 2 ;;
    --out) OUT=${2:?missing value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$CYCLES" =~ ^[1-9][0-9]*$ ]] || { echo "cycles must be positive" >&2; exit 2; }
[[ "$FRAME_READY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || {
  echo "frame-ready attempts must be positive" >&2
  exit 2
}
command -v "$ADB_BIN" >/dev/null || { echo "adb not found: $ADB_BIN" >&2; exit 1; }
command -v magick >/dev/null || { echo "ImageMagick magick is required" >&2; exit 1; }
[[ "$($ADB_BIN -s "$ADB_SERIAL" get-state 2>/dev/null)" == device ]] || {
  echo "Android device unavailable: $ADB_SERIAL" >&2
  exit 1
}

mkdir -p "$OUT"
summary="$OUT/summary.tsv"
printf 'cycle\tcard\tvideo_rmse\tresult\n' > "$summary"

capture() {
  "$ADB_BIN" -s "$ADB_SERIAL" exec-out screencap -p > "$1"
}

dump_layout() {
  local output=$1
  "$ADB_BIN" -s "$ADB_SERIAL" shell uiautomator dump /sdcard/piliplusx-anr-window.xml >/dev/null
  "$ADB_BIN" -s "$ADB_SERIAL" exec-out cat /sdcard/piliplusx-anr-window.xml > "$output"
}

window_anr_signature() {
  awk '
    /^  ANR time:/ { in_anr = 1 }
    in_anr { print }
    in_anr && /^  Display #0 / { exit }
  ' "$1"
}

assert_route_identity() {
  local prefix=$1
  local layout="$OUT/$prefix-route.xml"
  dump_layout "$layout"
  if ! rg -Fq "content-desc=\"$BVID\"" "$layout"; then
    echo "expected BVID is absent from current detail page: $BVID" >&2
    return 1
  fi
}

assert_not_anr() {
  local label=$1
  local window="$OUT/$label-window.txt"
  local logcat="$OUT/$label-logcat.txt"
  "$ADB_BIN" -s "$ADB_SERIAL" shell dumpsys window > "$window"
  "$ADB_BIN" -s "$ADB_SERIAL" logcat -d -v threadtime > "$logcat"
  local current_window_anr
  current_window_anr=$(window_anr_signature "$window")
  if rg -q 'mNotResponding=true' "$window" ||
    { [[ -n "$current_window_anr" ]] &&
      [[ "$current_window_anr" != "$WINDOW_ANR_BASELINE" ]]; } ||
    rg -qi "ANR in $PACKAGE|is unresponsive|Input dispatching timed out" "$logcat"; then
    echo "ANR detected at $label" >&2
    capture "$OUT/$label-anr.png" || true
    return 1
  fi
}

frame_rmse() {
  local before=$1 after=$2 crop_before=$3 crop_after=$4
  magick "$before" -crop 1080x518+0+112 "$crop_before"
  magick "$after" -crop 1080x518+0+112 "$crop_after"
  compare -metric RMSE "$crop_before" "$crop_after" null: 2>&1 || true
}

wait_for_video_progress() {
  local prefix=$1
  local attempt rmse normalized
  capture "$OUT/$prefix-before-touch.png"
  for attempt in $(seq 1 "$FRAME_READY_ATTEMPTS"); do
    sleep "$FRAME_PROBE_WAIT"
    capture "$OUT/$prefix-playing-probe-$attempt.png"
    rmse=$(frame_rmse "$OUT/$prefix-before-touch.png" \
      "$OUT/$prefix-playing-probe-$attempt.png" \
      "$OUT/$prefix-before-touch-video.png" \
      "$OUT/$prefix-playing-probe-$attempt-video.png")
    normalized=$(printf '%s' "$rmse" | sed -n 's/.*(\([^)]*\)).*/\1/p' | tail -1)
    if [[ -n "$normalized" ]] && awk -v value="$normalized" 'BEGIN { exit !(value > 0) }'; then
      cp "$OUT/$prefix-playing-probe-$attempt.png" "$OUT/$prefix-playing-probe.png"
      cp "$OUT/$prefix-playing-probe-$attempt-video.png" \
        "$OUT/$prefix-playing-probe-video.png"
      printf '%s\n' "$normalized"
      return 0
    fi
  done
  return 1
}

"$ADB_BIN" -s "$ADB_SERIAL" shell am force-stop "$PACKAGE"
"$ADB_BIN" -s "$ADB_SERIAL" logcat -c
"$ADB_BIN" -s "$ADB_SERIAL" shell dumpsys window > "$OUT/window-anr-baseline.txt"
WINDOW_ANR_BASELINE=$(window_anr_signature "$OUT/window-anr-baseline.txt")
"$ADB_BIN" -s "$ADB_SERIAL" shell am start -W -n "$PACKAGE/$ACTIVITY" > "$OUT/cold-start.txt"
sleep "$RETURN_WAIT"
assert_not_anr cold-start

for cycle in $(seq 1 "$CYCLES"); do
  prefix=$(printf 'cycle-%02d' "$cycle")
  # No diagnostic capture is inserted between route entry and its player touch:
  # this keeps the transient player/control state comparable across cycles.
  "$ADB_BIN" -s "$ADB_SERIAL" shell am start -W \
    -a android.intent.action.VIEW -d "bilibili://video/$BVID" \
    -n "$PACKAGE/$ACTIVITY" > "$OUT/$prefix-route-start.txt"
  sleep "$PLAY_START_WAIT"
  assert_route_identity "$prefix" || {
    printf '%s\t%s\t\tFAIL:route-identity\n' "$cycle" "$BVID" >> "$summary"
    exit 1
  }
  # Do not send the ANR trigger until the video has objectively produced a
  # changing frame. This is the Android equivalent of the OHOS ready barrier:
  # it avoids treating a loading/black detail page as a player re-entry.
  normalized=$(wait_for_video_progress "$prefix") || {
    echo "no video frame progression before touch at cycle $cycle" >&2
    printf '%s\t%s\t\tFAIL:no-frame-before-touch\n' "$cycle" "$BVID" >> "$summary"
    exit 1
  }
  "$ADB_BIN" -s "$ADB_SERIAL" shell input tap "$PLAYER_TOUCH_X" "$PLAYER_TOUCH_Y"
  sleep "$ANR_WAIT"
  capture "$OUT/$prefix-after-touch.png"
  assert_not_anr "$prefix-post-touch" || {
    printf '%s\t%s\t\tFAIL:anr\n' "$cycle" "$BVID" >> "$summary"
    exit 1
  }

  printf '%s\t%s\t%s\tPASS\n' "$cycle" "$BVID" "$normalized" >> "$summary"

  "$ADB_BIN" -s "$ADB_SERIAL" shell input keyevent 4
  sleep "$RETURN_WAIT"
  assert_not_anr "$prefix-after-back" || exit 1
done

printf 'overall=PASS\ncycles=%s\n' "$CYCLES" > "$OUT/verdict.env"
echo "Android player re-entry ANR verdict: PASS ($CYCLES cycles)"
echo "artifacts: $OUT"
