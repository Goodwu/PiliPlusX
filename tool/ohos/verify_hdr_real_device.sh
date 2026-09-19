#!/usr/bin/env bash
set -euo pipefail

# Resolve every tap from the current uitest layout; do not use screenshot
# scaled coordinates. Usage: script --source <BVID> [--hap signed.hap]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${HDC_TARGET:-2PM0223A18006914}"
HDC="${HDC_BIN:-$HOME/.local/harmony-tools/bin/hdc}"
SOURCE=""
HAP=""
ROOT="${VERIFY_OUT_DIR:-/tmp/piliplusx-ohos-verify-$(date +%Y%m%d-%H%M%S)}"
PACKAGE="com.example.piliplusx"
TOGGLE_COUNT="${VERIFY_TOGGLE_COUNT:-0}"
CYCLES="${VERIFY_CYCLES:-0}"
FREEZE_FRAME="${VERIFY_FREEZE_FRAME:-0}"
VERTICAL_VIDEO="${VERIFY_VERTICAL_VIDEO:-0}"
WAKE_MODE="${VERIFY_WAKE_MODE:-video-wake}"
# The lower edge of an OHOS XComponent can be outside the Flutter hit-test
# path even though its stale accessibility tree still exposes controls. Use a
# center video tap specifically to wake the transient control bar before a
# fullscreen-button click; keep WAKE_MODE for playback-state sampling.
CONTROL_WAKE_MODE="${VERIFY_CONTROL_WAKE_MODE:-video-center}"
HDC_CAPTURE_RETRIES="${VERIFY_HDC_CAPTURE_RETRIES:-8}"
HDC_CAPTURE_WAIT="${VERIFY_HDC_CAPTURE_WAIT:-2}"
# HAP installation on a physical OHOS device can take longer than the
# per-operation UI budget; keep the default long enough for install while
# allowing callers to tighten it for already-installed re-entry probes.
HDC_COMMAND_TIMEOUT="${VERIFY_HDC_COMMAND_TIMEOUT:-60}"
HDC_TIMEOUT_BIN="${VERIFY_HDC_TIMEOUT_BIN:-$(command -v gtimeout || command -v timeout || true)}"
KEEP_SCREEN_ON="${VERIFY_KEEP_SCREEN_ON:-1}"
SCREEN_TIMEOUT_MS="${VERIFY_SCREEN_TIMEOUT_MS:-3600000}"
REUSE_CURRENT_APP="${VERIFY_REUSE_CURRENT_APP:-0}"
PREPARE_ONLY="${VERIFY_PREPARE_ONLY:-0}"
REENTRY_PLAYBACK_ONLY="${VERIFY_REENTRY_PLAYBACK_ONLY:-0}"
PAUSE_AFTER_STABLE_FILE="${VERIFY_PAUSE_AFTER_STABLE_FILE:-}"
PAUSE_AFTER_READY_FILE="${VERIFY_PAUSE_AFTER_READY_FILE:-}"
PAUSE_BEFORE_FULLSCREEN_FILE="${VERIFY_PAUSE_BEFORE_FULLSCREEN_FILE:-}"
LOG_PID=""
FULLSCREEN_CONSUMED_OFFSET_FILE=""
# `auto` derives the input proof channel from the source/output decision in
# this run. Native HDR must retain the HCPP binding; an explicitly classified
# SDR Texture output has no HCPP attachment and is bound by Flutter markers.
INPUT_CHANNEL="${VERIFY_INPUT_CHANNEL:-auto}"
RESOLVED_INPUT_CHANNEL=""

while (($#)); do
  case "$1" in
    --source) SOURCE="${2:?missing source}"; shift 2 ;;
    --hap) HAP="${2:?missing hap}"; shift 2 ;;
    --out) ROOT="${2:?missing output directory}"; shift 2 ;;
    --toggle-count) TOGGLE_COUNT="${2:?missing toggle count}"; shift 2 ;;
    --cycles) CYCLES="${2:?missing cycles count}"; shift 2 ;;
    --freeze-frame) FREEZE_FRAME=1; shift ;;
    --vertical) VERTICAL_VIDEO=1; shift ;;
    -h|--help)
      cat <<'USAGE'
usage: verify_hdr_real_device.sh --source <BVID> [options]

options:
  --hap FILE             install this signed HAP before verification
  --out DIR              write screenshots, layouts, and hilog here
  --toggle-count N       repeat fullscreen transitions while playing
  --cycles N              repeat complete fullscreen exit/enter rounds
  --freeze-frame         pause before repeated fullscreen transitions
  --vertical              source metadata is confirmed vertical; fullscreen
                         must remain portrait and must not rotate landscape

environment:
  VERIFY_KEEP_SCREEN_ON=0 disable the reversible wakeup/timeout guard
  VERIFY_SCREEN_TIMEOUT_MS=3600000 temporary auto-screen-off timeout
  VERIFY_ALLOW_VISUAL_PLAYBACK=1 accept changing central video frames when
    OHOS omits semantic playing state; diagnostic evidence only
  VERIFY_CONTROL_WAKE_MODE=video-center wake the transient control bar from
    a Flutter-reachable video point before clicking fullscreen
  VERIFY_PAUSE_AFTER_READY_FILE=FILE pause only after fullscreen direction,
    control-bar and playback readiness checks have passed
  VERIFY_REUSE_CURRENT_APP=1 reuse the already-running app process instead of
    force-stopping/starting it; intended for same-process page re-entry probes
  VERIFY_PREPARE_ONLY=1 stop after target-video/playback/orientation/control
    layout preparation; pair the output with the single-trial button script
  VERIFY_INPUT_LOG_SETTLE_WAIT=360 maximum wait per raw fullscreen action for
    ordered Flutter pointer-down, pointer-up, callback and FullscreenTrace;
    native handler/orientation/playback never substitute for these markers
  VERIFY_FINAL_LOG_DRAIN_WAIT=150 retain the single root Hilog stream after
    the final action before it is stopped and supplemented with hilog -x
  VERIFY_FAILURE_LOG_DRAIN_WAIT=150 retain that same root stream only after a
    raw fullscreen action recorded INCONCLUSIVE; late records remain
    diagnostic and cannot change its verdict or trigger another action
  VERIFY_INPUT_CHANNEL=auto|hcpp|flutter choose the raw-input proof channel;
    auto accepts only an explicit nativeHdr/native-hdr or sdr/texture decision
USAGE
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$SOURCE" ]] || { echo "--source is required" >&2; exit 2; }
[[ -x "$HDC" ]] || { echo "HDC not executable: $HDC" >&2; exit 1; }
if [[ "$REUSE_CURRENT_APP" != 0 && "$REUSE_CURRENT_APP" != 1 ]]; then
  echo "invalid VERIFY_REUSE_CURRENT_APP: $REUSE_CURRENT_APP" >&2
  exit 2
fi
if [[ "$PREPARE_ONLY" != 0 && "$PREPARE_ONLY" != 1 ]]; then
  echo "invalid VERIFY_PREPARE_ONLY: $PREPARE_ONLY" >&2
  exit 2
fi
if [[ "$REENTRY_PLAYBACK_ONLY" != 0 && "$REENTRY_PLAYBACK_ONLY" != 1 ]]; then
  echo "invalid VERIFY_REENTRY_PLAYBACK_ONLY: $REENTRY_PLAYBACK_ONLY" >&2
  exit 2
fi
if [[ "$REENTRY_PLAYBACK_ONLY" == 1 && "$REUSE_CURRENT_APP" != 1 ]]; then
  echo "VERIFY_REENTRY_PLAYBACK_ONLY requires VERIFY_REUSE_CURRENT_APP=1" >&2
  exit 2
fi
if ! "$HDC" list targets -v 2>/dev/null | awk -v target="$TARGET" '
  $1 == target && ($2 == "Online" || $3 == "Online" || $4 == "Online" ||
                   $2 == "Connected" || $3 == "Connected" || $4 == "Connected") { found=1 }
  END { exit found ? 0 : 1 }
'; then
  echo "HDC target is not online: $TARGET (set HDC_TARGET explicitly for another device)" >&2
  exit 1
fi
[[ "$TOGGLE_COUNT" =~ ^[0-9]+$ ]] || { echo "invalid --toggle-count: $TOGGLE_COUNT" >&2; exit 2; }
[[ "$CYCLES" =~ ^[0-9]+$ ]] || { echo "invalid --cycles: $CYCLES" >&2; exit 2; }
[[ "$VERTICAL_VIDEO" == 0 || "$VERTICAL_VIDEO" == 1 ]] || {
  echo "invalid --vertical/VERIFY_VERTICAL_VIDEO: $VERTICAL_VIDEO" >&2
  exit 2
}
[[ "$INPUT_CHANNEL" == auto || "$INPUT_CHANNEL" == hcpp || "$INPUT_CHANNEL" == flutter ]] || {
  echo "invalid VERIFY_INPUT_CHANNEL: $INPUT_CHANNEL (expected auto, hcpp or flutter)" >&2
  exit 2
}
[[ "$WAKE_MODE" == video-wake || "$WAKE_MODE" == video-center ]] || {
  echo "invalid VERIFY_WAKE_MODE: $WAKE_MODE (expected video-wake or video-center)" >&2
  exit 2
}
[[ "$CONTROL_WAKE_MODE" == video-wake || "$CONTROL_WAKE_MODE" == video-center ]] || {
  echo "invalid VERIFY_CONTROL_WAKE_MODE: $CONTROL_WAKE_MODE (expected video-wake or video-center)" >&2
  exit 2
}
if [[ "$TOGGLE_COUNT" != 0 && "$CYCLES" != 0 ]]; then
  echo "--toggle-count and --cycles are mutually exclusive" >&2
  exit 2
fi
if [[ "$PREPARE_ONLY" == 1 && ("$TOGGLE_COUNT" != 0 || "$CYCLES" != 0) ]]; then
  echo "VERIFY_PREPARE_ONLY=1 cannot be combined with cycles or toggles" >&2
  exit 2
fi
FULLSCREEN_ORIENTATION=landscape
if [[ "$VERTICAL_VIDEO" == 1 ]]; then
  FULLSCREEN_ORIENTATION=portrait
  # Vertical sources often leave black bars at the bottom of the portrait
  # page. Wake the actual video body by default; callers may still override
  # this with VERIFY_WAKE_MODE=video-wake/video-center.
  if [[ -z "${VERIFY_WAKE_MODE+x}" ]]; then
    WAKE_MODE=video-center
  fi
fi
mkdir -p "$ROOT"
: >"$ROOT/events.tsv"

mark_event() {
  printf '%s mono=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(python3 -c 'import time; print(f"{time.monotonic():.6f}")')" \
    "$*" >>"$ROOT/events.tsv"
}

run_hdc() {
  if [[ -n "$HDC_TIMEOUT_BIN" ]]; then
    "$HDC_TIMEOUT_BIN" --signal=TERM --kill-after=2 "$HDC_COMMAND_TIMEOUT" \
      "$HDC" -t "$TARGET" "$@"
  else
    "$HDC" -t "$TARGET" "$@"
  fi
}

restore_screen_timeout() {
  if [[ "$KEEP_SCREEN_ON" == "1" ]]; then
    run_hdc shell power-shell timeout -r >/dev/null 2>&1 || true
    mark_event "screen-timeout-restored"
  fi
}

stop_hilog_capture() {
  if [[ -n "$LOG_PID" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
    LOG_PID=""
  fi
}

start_hilog_capture() {
  timeout "$LOG_SECONDS" "$HDC" -t "$TARGET" shell hilog >>"$ROOT/hilog.txt" 2>&1 &
  LOG_PID=$!
  mark_event "hilog-capture-start seconds=$LOG_SECONDS pid=$LOG_PID"
}

cleanup_verification() {
  stop_hilog_capture
  restore_screen_timeout
}

if [[ "$KEEP_SCREEN_ON" == "1" ]]; then
  [[ "$SCREEN_TIMEOUT_MS" =~ ^[0-9]+$ ]] || {
    echo "invalid VERIFY_SCREEN_TIMEOUT_MS: $SCREEN_TIMEOUT_MS" >&2
    exit 2
  }
  trap cleanup_verification EXIT
  run_hdc shell power-shell wakeup >/dev/null
  run_hdc shell power-shell timeout -o "$SCREEN_TIMEOUT_MS" >/dev/null
  mark_event "screen-kept-awake timeout-ms=$SCREEN_TIMEOUT_MS"
fi

pull_layout() {
  local name="$1" remote="/data/local/tmp/piliplusx-layout.json"
  local attempt
  for ((attempt=1; attempt<=HDC_CAPTURE_RETRIES; attempt++)); do
    if run_hdc shell uitest dumpLayout -p "$remote" >/dev/null &&
       run_hdc file recv "$remote" "$ROOT/$name" >/dev/null &&
       [[ -s "$ROOT/$name" ]]; then
      return 0
    fi
    mark_event "layout-retry $name attempt=$attempt"
    sleep "$HDC_CAPTURE_WAIT"
  done
  echo "failed to capture layout after $HDC_CAPTURE_RETRIES attempts: $name" >&2
  return 1
}

is_target_app_layout() {
  local layout="$1"
  python3 - "$layout" "$PACKAGE" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
actual = ""
def walk(node):
    if isinstance(node, dict):
        yield node
        for child in node.get("children", []):
            yield from walk(child)
for node in walk(data):
    candidate = node.get("attributes", {}).get("bundleName", "")
    if candidate:
        actual = candidate
        break
if actual != expected:
    print(actual or "<unknown>", file=sys.stderr)
    raise SystemExit(1)
PY
}

assert_target_app_layout() {
  local layout="$1" actual
  if grep -Eq '"(text|originalText)":"会议中"' "$layout"; then
    mark_event "foreground-system-overlay overlay=feishu-meeting layout=$(basename "$layout")"
    echo "system overlay is covering the player: feishu meeting" >&2
    return 1
  fi
  if actual=$(is_target_app_layout "$layout" 2>&1); then
    return 0
  fi
  mark_event "foreground-app-mismatch expected=$PACKAGE actual=$actual layout=$(basename "$layout")"
  echo "foreground app changed while sampling: expected=$PACKAGE actual=$actual" >&2
  return 1
}

read_bounds() {
  python3 - "$1" "$2" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
needle = sys.argv[2]
found = []
def walk(node):
    if isinstance(node, dict):
        attrs = node.get('attributes', {})
        if attrs.get('text') == needle or attrs.get('originalText') == needle:
            m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', attrs.get('bounds', ''))
            if m:
                x1, y1, x2, y2 = map(int, m.groups())
                found.append(((x1+x2)//2, (y1+y2)//2, attrs.get('bounds')))
        for child in node.get('children', []): walk(child)
walk(data)
if not found:
    raise SystemExit(f'element not found: {needle!r}')
print(*found[0])
PY
}

click_text() {
  local layout="$1" text="$2" x y bounds
  read -r x y bounds < <(read_bounds "$layout" "$text")
  echo "click text=$text center=($x,$y) bounds=$bounds"
  mark_event "click-text $text center=$x,$y"
  run_hdc shell uitest uiInput click "$x" "$y" >/dev/null
}

click_text_contains() {
  local layout="$1" needle="$2" x y bounds
  read -r x y bounds < <(python3 - "$layout" "$needle" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
needle = sys.argv[2]
found = []
def walk(node):
    if isinstance(node, dict):
        attrs = node.get('attributes', {})
        value = attrs.get('text') or attrs.get('originalText') or ''
        if needle in value:
            m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', attrs.get('bounds', ''))
            if m:
                x1, y1, x2, y2 = map(int, m.groups())
                found.append(((x1+x2)//2, (y1+y2)//2, attrs.get('bounds')))
        for child in node.get('children', []):
            walk(child)
walk(data)
if not found:
    raise SystemExit(f'element containing text not found: {needle!r}')
print(*found[0])
PY
  )
  echo "click text-containing=$needle center=($x,$y) bounds=$bounds"
  mark_event "click-text-containing $needle center=$x,$y"
  run_hdc shell uitest uiInput click "$x" "$y" >/dev/null
}

click_layout_point() {
  local mode="$1" layout="$2" x y bounds
  read -r x y bounds < <(python3 "$SCRIPT_DIR/ohos_ui_layout.py" "$mode" "$layout")
  echo "click $mode center=($x,$y) bounds=$bounds"
  mark_event "click-$mode center=$x,$y"
  run_hdc shell uitest uiInput click "$x" "$y" >/dev/null
}

click_fullscreen_button_raw() {
  local layout="$1" x y bounds
  read -r x y bounds < <(
    python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh "$layout"
  )
  echo "raw fullscreen button down/up center=($x,$y) bounds=$bounds"
  mark_event "raw-fullscreen-button center=$x,$y bounds=$bounds"
  # uiInput may invoke Semantics.onTap rather than dispatching a physical
  # pointer. The fullscreen acceptance barrier requires the button Listener's
  # pointer down/up records, so emit the complete touch lifecycle explicitly.
  run_hdc shell uinput -T -d "$x" "$y" >/dev/null
  sleep "${VERIFY_FULLSCREEN_TOUCH_DOWN_WAIT:-0.08}"
  run_hdc shell uinput -T -u "$x" "$y" >/dev/null
}

ensure_fullscreen_controls_visible() {
  local layout="$1" mode="${2:-$CONTROL_WAKE_MODE}"
  # A center tap toggles an already visible control bar off. Resolve the
  # current semantic button first and wake only when the newest layout does
  # not expose it; this keeps the click window aligned with the user's
  # transient-control-bar behavior.
  if python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button \
      "$layout" >/dev/null 2>&1; then
    mark_event "fullscreen-controls-already-visible layout=$(basename "$layout")"
    return 0
  fi
  click_layout_point "$mode" "$layout"
  # The control layer's accessibility node is published before its slide
  # animation reaches the hit-test position. Give the wake event one bounded
  # animation window before taking the fresh semantic coordinate.
  sleep "${VERIFY_CONTROL_WAIT:-0.35}"
}

read_fullscreen_label() {
  python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-label "$1"
}

assert_fullscreen_label() {
  local layout="$1" expected="$2" actual
  actual="$(read_fullscreen_label "$layout")" || {
    echo "fullscreen semantic state not exposed: $layout" >&2
    return 1
  }
  echo "fullscreen semantic state: $actual"
  mark_event "fullscreen-semantic-state layout=$(basename "$layout") state=$actual"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected fullscreen semantic state: expected=$expected actual=$actual" >&2
    return 1
  fi
}

wait_for_fullscreen_label_after_wake() {
  local stable_layout="$1" prefix="$2" expected="$3"
  local attempts="${VERIFY_CONTROL_RETRIES:-8}"
  local wait_seconds="${VERIFY_CONTROL_RETRY_WAIT:-0.1}"
  local attempt layout
  for ((attempt=1; attempt<=attempts; attempt++)); do
    layout="$ROOT/${prefix}-post-controls-${attempt}.json"
    pull_layout "$(basename "$layout")"
    if assert_fullscreen_label "$layout" "$expected"; then
      cp "$layout" "$ROOT/${prefix}-post-controls.json"
      mark_event "fullscreen-post-controls-ready prefix=${prefix} attempt=${attempt}"
      return 0
    fi
    if (( attempt < attempts )); then
      sleep "$wait_seconds"
      click_layout_point "$CONTROL_WAKE_MODE" "$stable_layout"
    fi
  done
  echo "fullscreen control did not reappear after wake: ${prefix}" >&2
  mark_event "fullscreen-post-controls-failed prefix=${prefix} expected=${expected}"
  return 1
}

reset_playback_to_start() {
  local layout="$1" prefix="$2" x y bounds state position attempt current_layout
  read -r x y bounds < <(python3 "$SCRIPT_DIR/ohos_ui_layout.py" video-seek-start "$layout")
  echo "seek playback-start center=($x,$y) bounds=$bounds"
  mark_event "seek-playback-start center=$x,$y bounds=$bounds"
  run_hdc shell uitest uiInput click "$x" "$y" >/dev/null
  sleep "${VERIFY_SEEK_WAIT:-0.3}"
  pull_layout "${prefix}-after-seek.json" || {
    mark_event "playback-after-seek-layout-failed prefix=$prefix"
    return 1
  }
  current_layout="$ROOT/${prefix}-after-seek.json"
  read -r state position < <(read_playback_state "$ROOT/${prefix}-after-seek.json")
  mark_event "playback-after-seek state=$state position=${position:-unknown}"
  # A seek from an ended source may leave the player paused while the control
  # bar is already hidden. Prefer a play action from the authoritative seek
  # dump before waking the video: a wake tap can dismiss an otherwise visible
  # transient control bar. Only wake when the seek dump has no play action.
  local play_action_present=0
  if read_bounds "$ROOT/${prefix}-after-seek.json" 播放 >/dev/null 2>&1; then
    play_action_present=1
  fi
  local retries="${VERIFY_PLAYING_STATE_RETRIES:-8}"
  local wait_seconds="${VERIFY_PLAYING_STATE_WAIT:-1}"
  for ((attempt=1; attempt<=retries; attempt++)); do
    read -r state position < <(read_playback_state "$current_layout")
    if [[ "$state" == playing ]]; then
      cp "$current_layout" "$ROOT/${prefix}-after-play.json"
      mark_event "playback-after-seek-playing attempt=$attempt position=${position:-unknown}"
      return 0
    fi
    play_action_present=0
    if read_bounds "$current_layout" 播放 >/dev/null 2>&1; then
      play_action_present=1
    fi
    if [[ "$state" == paused || "$play_action_present" == 1 ]]; then
      click_text "$current_layout" 播放
    else
      click_layout_point "$WAKE_MODE" "$current_layout"
    fi
    sleep "${VERIFY_CONTROL_WAIT:-0.1}"
    if (( attempt < retries )); then
      sleep "$wait_seconds"
    fi
    if ! pull_layout "${prefix}-play-attempt-${attempt}.json"; then
      mark_event "playback-after-seek-layout-failed prefix=$prefix attempt=$attempt"
      return 1
    fi
    current_layout="$ROOT/${prefix}-play-attempt-${attempt}.json"
    read -r state position < <(read_playback_state "$current_layout")
    mark_event "playback-after-seek-retry attempt=$attempt state=$state position=${position:-unknown}"
  done
  cp "$current_layout" "$ROOT/${prefix}-after-play.json"
  mark_event "playback-after-seek-failed position=${position:-unknown}"
  echo "playback did not resume after seeking to start: $prefix" >&2
  return 1
}

fill_search_input() {
  local layout="$1" value="$2" x y bounds
  # Coordinates extracted from a prior UI dump are valid only while the
  # target remains the foreground root.  In particular, never send text or a
  # clear-button tap into an application that took foreground during launch.
  assert_target_app_layout "$layout" || return 1
  read -r x y bounds < <(python3 "$SCRIPT_DIR/ohos_ui_layout.py" search-input "$layout")
  echo "input search center=($x,$y) bounds=$bounds value=$value"
  local clear_x clear_y clear_bounds
  if read -r clear_x clear_y clear_bounds < <(
    python3 "$SCRIPT_DIR/ohos_ui_layout.py" search-clear "$layout" 2>/dev/null
  ); then
    run_hdc shell uitest uiInput click "$clear_x" "$clear_y" >/dev/null
    sleep 0.1
  fi
  run_hdc shell uitest uiInput click "$x" "$y" >/dev/null
  run_hdc shell uitest uiInput inputText "$x" "$y" "$value" >/dev/null
}

capture_display() {
  local name="$1"
  local remote="/data/local/tmp/piliplusx-verify-${name}.jpeg"
  local attempt
  mark_event "capture-start $name"
  for ((attempt=1; attempt<=HDC_CAPTURE_RETRIES; attempt++)); do
    if run_hdc shell snapshot_display -f "$remote" >/dev/null &&
       run_hdc file recv "$remote" "$ROOT/${name}.jpeg" >/dev/null &&
       [[ -s "$ROOT/${name}.jpeg" ]]; then
      mark_event "capture-done $name"
      return 0
    fi
    mark_event "capture-retry $name attempt=$attempt"
    sleep "$HDC_CAPTURE_WAIT"
  done
  echo "failed to capture display after $HDC_CAPTURE_RETRIES attempts: $name" >&2
  return 1
}

capture_render_service() {
  local name="$1"
  local snapshot="$ROOT/${name}-renderservice.txt"
  local stable_sample=0
  if [[ "$name" == *-fullscreen-stable ]]; then
    stable_sample=1
  fi
  if run_hdc shell hidumper -s RenderService -a allInfo >"$snapshot" 2>&1; then
    mark_event "renderservice-done $name"
    local baseline="$ROOT/render-service-color-baseline.json"
    local baseline_args=()
    if [[ "$name" == *-fullscreen-stable ]]; then
      baseline_args=(--baseline "$baseline" --reset-on-identity-change)
      if [[ "${VERIFY_REQUIRE_COLOR_CONTRACT:-0}" == "1" ]]; then
        baseline_args+=(--expected-color-space
          "${VERIFY_EXPECTED_RENDER_COLOR_SPACE:-7}")
      fi
    elif [[ -f "$baseline" ]]; then
      baseline_args=(--baseline "$baseline")
    fi
    local contract
    if contract="$(python3 "$SCRIPT_DIR/inspect_render_service.py" "$snapshot" \
        "${baseline_args[@]}" 2>/dev/null)"; then
      printf '%s\n' "$contract" >"$ROOT/${name}-render-color.json"
      mark_event "render-color-contract $name $contract"
    else
      local status=$?
      if [[ "$status" == 1 ]]; then
        printf '%s\n' "$contract" >"$ROOT/${name}-render-color.json"
        if [[ "$name" == *-fullscreen-stable ]]; then
          mark_event "COLOR_CONTRACT_MISMATCH $name $contract"
          echo "RenderService video color contract changed at $name: $contract" >&2
          return 1
        fi
        mark_event "COLOR_CONTRACT_TRANSIENT $name $contract"
        echo "warning: RenderService video color contract changed during transition at $name: $contract" >&2
        return 0
      elif [[ "$status" == 3 ]]; then
        printf '%s\n' "$contract" >"$ROOT/${name}-render-color.json"
        mark_event "render-color-identity-transition $name $contract"
        return 0
      fi
      mark_event "render-color-contract-unavailable $name status=$status"
      if [[ "${VERIFY_REQUIRE_COLOR_CONTRACT:-0}" == "1" &&
            "$stable_sample" == 1 ]]; then
        echo "RenderService video color contract unavailable at $name" >&2
        return 1
      fi
      mark_event "render-color-contract-unavailable-transition $name status=$status"
      echo "warning: RenderService video color contract unavailable during transition at $name" >&2
    fi
  else
    mark_event "renderservice-failed $name"
    rm -f "$snapshot"
    if [[ "${VERIFY_REQUIRE_COLOR_CONTRACT:-0}" == "1" &&
          "$stable_sample" == 1 ]]; then
      return 1
    fi
  fi
}

verify_hap_native_diagnostics() {
  [[ -n "$HAP" ]] || return 0
  local marker_blob
  marker_blob="$(unzip -p "$HAP" libs/arm64-v8a/libmpv.so 2>/dev/null | strings || true)"
  local required_marker
  local required_markers=(
    'OHOS color contract'
    'OHOS color hint after set_color'
    'OHOS target mapping'
    'OHOS consumer color mismatch'
  )
  if [[ "${VERIFY_REQUIRE_NATIVE_DIAGNOSTICS:-0}" == "1" ]]; then
    for required_marker in "${required_markers[@]}"; do
      if ! grep -Fq "$required_marker" <<<"$marker_blob"; then
        echo "HAP native diagnostic marker missing: $required_marker ($HAP)" >&2
        return 1
      fi
    done
  elif [[ -z "$(grep -E 'OHOS color contract|OHOS color hint after set_color|OHOS target mapping|OHOS consumer color mismatch' <<<"$marker_blob" || true)" ]]; then
    if [[ "${VERIFY_REQUIRE_NATIVE_DIAGNOSTICS:-0}" == "1" ]]; then
      echo "HAP native diagnostics missing: $HAP" >&2
      return 1
    fi
    echo "warning: HAP native diagnostics not found: $HAP" >&2
    return 0
  fi
  if [[ -n "${VERIFY_EXPECTED_LIBMPV_SHA256:-}" ]]; then
    local actual_sha
    actual_sha="$(unzip -p "$HAP" libs/arm64-v8a/libmpv.so | shasum -a 256 | awk '{print $1}')"
    if [[ "$actual_sha" != "$VERIFY_EXPECTED_LIBMPV_SHA256" ]]; then
      echo "HAP libmpv SHA256 mismatch: expected=$VERIFY_EXPECTED_LIBMPV_SHA256 actual=$actual_sha" >&2
      return 1
    fi
    echo "HAP libmpv SHA256: $actual_sha"
  fi
  echo "HAP native diagnostics: present"
}

capture_toggle_state() {
  local prefix="$1"
  pull_layout "${prefix}.json"
  if [[ "$prefix" == *-fullscreen-stable ]]; then
    record_screen_orientation "$ROOT/${prefix}.json" "$prefix"
  fi
  capture_display "$prefix"
  capture_render_service "$prefix"
}

hilog_offset() {
  if [[ -s "$ROOT/hilog.txt" ]]; then
    wc -c <"$ROOT/hilog.txt" | tr -d '[:space:]'
  else
    echo 0
  fi
}

require_target_pid() {
  local pid
  pid="$(run_hdc shell pidof "$PACKAGE" 2>/dev/null | tr -d '\r[:space:]')"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "target application is not running as one stable process: ${pid:-<none>}" >&2
    return 1
  fi
  printf '%s\n' "$pid"
}

assert_active_flutter_attachment() {
  local expected_pid="$1"
  python3 - "$ROOT/hilog.txt" "$expected_pid" <<'PY'
import re
import sys

path, pid = sys.argv[1:]
text = open(path, encoding='utf-8', errors='replace').read()
# The log is sampled only after the verifier has launched/reused the target
# app. Bind all three lifecycle records to the current process so an old
# attachment from a replacement process cannot authorize an input coordinate.
pid_prefix = re.compile(rf'\b{re.escape(pid)}\b.*?')
attachments = []
for match in re.finditer(
    r'hcpp_input attachment platformViewId=(\d+) epoch=(\d+) action=create',
    text,
):
    line_start = text.rfind('\n', 0, match.start()) + 1
    line_end = text.find('\n', match.end())
    if line_end == -1:
        line_end = len(text)
    line = text[line_start:line_end]
    if not pid_prefix.search(line):
        continue
    attachments.append((match.start(), int(match.group(1)), int(match.group(2))))
if not attachments:
    raise SystemExit('no current-process Flutter attachment marker')
attachment_offset, view_id, epoch = attachments[-1]
ready_pattern = re.compile(
    rf'\b{re.escape(pid)}\b.*?nativeSurfaceReady: '
    rf'\{{viewId: {view_id}, .*?generation: (\d+)',
)
ready = ready_pattern.search(text, attachment_offset)
if not ready:
    raise SystemExit(f'no nativeSurfaceReady marker for attachment viewId={view_id}')
generation = ready.group(1)
attached = re.search(
    rf'\b{re.escape(pid)}\b.*?native XComponent surface attached: .*?'
    rf'generation={generation}\b',
    text[ready.end():],
)
if not attached:
    raise SystemExit(
        f'no native-surface attached marker for viewId={view_id} generation={generation}'
    )
print(f'viewId={view_id} epoch={epoch} generation={generation}')
PY
}

assert_active_flutter_texture_view() {
  local expected_pid="$1"
  python3 - "$ROOT/hilog.txt" "$expected_pid" <<'PY'
import re
import sys

path, pid = sys.argv[1:]
text = open(path, encoding='utf-8', errors='replace').read()
views = []
for line in text.splitlines():
    if not re.search(rf'\b{re.escape(pid)}\b', line):
        continue
    match = re.search(r'PlayerTouchTrace.*\bviewId=(\d+)\b', line)
    if match:
        views.append(match.group(1))
unique = sorted(set(views))
if len(unique) != 1:
    raise SystemExit('no unique current-process Flutter Texture view marker')
print(f'viewId={unique[0]} epoch=0 topology=texture')
PY
}

resolve_input_channel() {
  local requested="$INPUT_CHANNEL" decision
  decision="$(grep -E 'HDR decision: .*output=(nativeHdr|sdr).*surface=(native-hdr|texture)|HDR native decision applied: output=nativeHdr' "$ROOT/hilog.txt" | tail -n 1 || true)"
  if [[ -z "$decision" ]]; then
    echo "no explicit source/output decision available for input proof channel" >&2
    return 1
  fi
  case "$requested" in
    auto)
      if [[ "$decision" =~ output=nativeHdr.*surface=native-hdr|HDR\ native\ decision\ applied:\ output=nativeHdr ]]; then
        RESOLVED_INPUT_CHANNEL=hcpp
      elif [[ "$decision" =~ output=sdr.*surface=texture ]]; then
        RESOLVED_INPUT_CHANNEL=flutter
      else
        echo "unsupported output decision for auto input proof: $decision" >&2
        return 1
      fi
      ;;
    hcpp)
      [[ "$decision" =~ output=nativeHdr.*surface=native-hdr|HDR\ native\ decision\ applied:\ output=nativeHdr ]] || {
        echo "HCPP proof requested without current nativeHdr/native-hdr decision" >&2; return 1;
      }
      RESOLVED_INPUT_CHANNEL=hcpp
      ;;
    flutter)
      [[ "$decision" =~ output=sdr.*surface=texture ]] || {
        echo "Flutter Texture proof requested without current SDR/Texture decision" >&2; return 1;
      }
      RESOLVED_INPUT_CHANNEL=flutter
      ;;
  esac
  mark_event "input-proof-channel channel=$RESOLVED_INPUT_CHANNEL decision=$(printf '%s' "$decision" | tr ' ' '_')"
}

resolve_active_input_identity() {
  local expected_pid="$1"
  if [[ "$RESOLVED_INPUT_CHANNEL" == hcpp ]]; then
    assert_active_flutter_attachment "$expected_pid"
  elif [[ "$RESOLVED_INPUT_CHANNEL" == flutter ]]; then
    assert_active_flutter_texture_view "$expected_pid"
  else
    echo "input proof channel has not been resolved" >&2
    return 1
  fi
}

wait_for_fullscreen_request() {
  local expected="$1" start_offset="${2:-0}"
  local attempts=${VERIFY_FULLSCREEN_REQUEST_WAIT_TICKS:-40}
  local pattern callback_pattern current_offset
  if [[ "$expected" == enter ]]; then
    pattern='FullscreenTrace.*trigger status=true'
    callback_pattern='PlayerTouchTrace.*fullscreen-button callback target=true'
  else
    pattern='FullscreenTrace.*trigger status=false'
    callback_pattern='PlayerTouchTrace.*fullscreen-button callback target=false'
  fi
  for ((i=1; i<=attempts; i++)); do
    current_offset="$(hilog_offset)"
    if (( current_offset > start_offset )) && python3 - \
      "$ROOT/hilog.txt" "$start_offset" "$callback_pattern" "$pattern" "$expected" <<'PY'
import re
import sys

path, offset, callback, request, direction = sys.argv[1:]
with open(path, 'rb') as f:
    f.seek(int(offset))
    text = f.read().decode('utf-8', errors='replace')
patterns = [
    r'PlayerTouchTrace.*fullscreen-button pointer-down\b',
    r'PlayerTouchTrace.*fullscreen-button pointer-up\b',
    callback,
    request,
]
positions = [re.search(pattern, text) for pattern in patterns]
if all(positions) and [match.start() for match in positions] == \
        sorted(match.start() for match in positions):
    raise SystemExit(0)

raise SystemExit(1)
PY
    then
      mark_event "fullscreen-request-observed direction=$expected attempt=$i"
      return 0
    fi
    sleep 0.2
  done
  mark_event "fullscreen-request-missing direction=$expected"
  echo "fullscreen button callback/request was not observed after ${expected} button input" >&2
  return 1
}

run_single_fullscreen_input() {
  local expected="$1" action_layout="$2" trial_label="${3:-$expected}" trial_root
  local action_pid attachment view_id epoch
  # The root verifier owns one continuous Hilog stream from before the first
  # raw fullscreen action until the final delayed-marker drain.  A trial gets
  # a byte offset in that stream and cannot begin until its predecessor has
  # consumed an ordered Flutter four-marker sequence.
  action_pid="$(require_target_pid)" || return 1
  attachment="$(resolve_active_input_identity "$action_pid")" || {
    mark_event "fullscreen-attachment-missing prefix=${trial_label} pid=${action_pid}"
    return 1
  }
  if [[ "$attachment" =~ viewId=([0-9]+)[[:space:]]epoch=([0-9]+) ]]; then
    view_id="${BASH_REMATCH[1]}"
    epoch="${BASH_REMATCH[2]}"
  else
    mark_event "fullscreen-attachment-unparseable prefix=${trial_label} value=${attachment}"
    return 1
  fi
  trial_root="$ROOT/fullscreen-input-${trial_label}-trial"
  mark_event "fullscreen-input-trial-start expected=$expected pid=$action_pid view-id=$view_id epoch=$epoch input-channel=$RESOLVED_INPUT_CHANNEL"
  if VERIFY_BUTTON_TRIAL_OUT="$trial_root" \
      VERIFY_BUTTON_TRIAL_MODE=continuous \
      VERIFY_BUTTON_TRIAL_SETTLE_WAIT="${VERIFY_INPUT_LOG_SETTLE_WAIT:-360}" \
      VERIFY_BUTTON_TRIAL_INPUT_CHANNEL="$RESOLVED_INPUT_CHANNEL" \
      HDC_TARGET="$TARGET" HDC_BIN="$HDC" \
      "$SCRIPT_DIR/verify_player_button_input_trial_real_device.sh" \
        --button-layout "$action_layout" --expected "$expected" \
        --shared-hilog "$ROOT/hilog.txt" \
        --consumed-offset "$FULLSCREEN_CONSUMED_OFFSET_FILE" \
        --action-pid "$action_pid" --view-id "$view_id" --epoch "$epoch" \
        --trial-id "$trial_label"; then
    mark_event "fullscreen-input-trial-observed expected=$expected"
    return 0
  fi
  mark_event "fullscreen-input-trial-inconclusive expected=$expected"
  # A status=INCONCLUSIVE action record proves raw input was issued. Keep the
  # already-running root stream for delayed-marker diagnosis, but do not
  # reparse it into PASS and do not permit the caller to issue another raw
  # action. Precondition failures have no action record and return promptly.
  if [[ -s "$trial_root/action-record.json" ]] &&
      python3 - "$trial_root/action-record.json" <<'PY'
import json, sys
try:
    record = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if record.get('status') == 'INCONCLUSIVE' else 1)
PY
  then
    local failure_drain="${VERIFY_FAILURE_LOG_DRAIN_WAIT:-150}"
    if [[ ! "$failure_drain" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "invalid VERIFY_FAILURE_LOG_DRAIN_WAIT: $failure_drain" >&2
      return 1
    fi
    mark_event "hilog-failure-drain-start trial=$trial_label seconds=$failure_drain verdict=INCONCLUSIVE"
    sleep "$failure_drain"
    mark_event "hilog-failure-drain-complete trial=$trial_label verdict=INCONCLUSIVE"
    if refresh_hilog_snapshot; then
      mark_event "hilog-failure-snapshot-appended trial=$trial_label verdict=INCONCLUSIVE"
    else
      mark_event "hilog-failure-snapshot-failed trial=$trial_label verdict=INCONCLUSIVE"
    fi
  fi
  echo "fullscreen input trial did not produce a complete callback/request record" >&2
  return 1
}

read_playback_state() {
  python3 - "$1" <<'PY'
import json
import re
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
nodes = []

def walk(node):
    if not isinstance(node, dict):
        return
    nodes.append(node)
    for child in node.get("children", []):
        walk(child)

walk(data)
texts = []
for node in nodes:
    attrs = node.get("attributes", {})
    texts.extend(str(attrs.get(key, "")) for key in (
        "text", "originalText", "description", "contentDescription",
        "accessibilityText", "accessibilityValue", "id", "resourceId",
    ))
joined = " ".join(texts)

if re.search(r"缓冲|加载中|加载|buffering|loading", joined, re.IGNORECASE):
    state = "buffering"
elif re.search(r"重播|已结束|播放完毕|播放完成", joined, re.IGNORECASE):
    # A rounded Slider percentage is not an EOF signal. Only an explicit
    # completion/replay affordance may authorize a long-run restart.
    state = "completed"
else:
    actions = []
    for node in nodes:
        attrs = node.get("attributes", {})
        if attrs.get("visible") == "false":
            continue
        if attrs.get("clickable") == "false":
            continue
        value = attrs.get("text") or attrs.get("originalText") or ""
        if value:
            actions.append(value.strip())
    if any(value in ("暂停", "Pause") for value in actions):
        state = "playing"
    elif any(value in ("播放", "Play") for value in actions):
        state = "paused"
    else:
        state = "unknown"

position = ""
for node in nodes:
    attrs = node.get("attributes", {})
    if attrs.get("type") != "Slider" or attrs.get("visible") == "false":
        continue
    for key in ("value", "currentValue", "progress", "position", "accessibilityValue"):
        candidate = str(attrs.get(key, "")).strip()
        if candidate and candidate.lower() not in ("none", "null"):
            position = candidate
            break
    if not position:
        # The OHOS accessibility tree may expose the progress value only in
        # Slider text (for example "66% ,进度条"), while the native control
        # buttons remain outside the dump. Preserve that evidence without
        # pretending it proves the playing/paused semantic state.
        for key in ("text", "originalText", "accessibilityText", "accessibilityValue"):
            candidate = str(attrs.get(key, "")).strip()
            if re.search(r"\d+(?:\.\d+)?%", candidate):
                position = re.search(r"\d+(?:\.\d+)?%", candidate).group(0)
                break
    if position:
        break

print(f"{state}\t{position}")
PY
}

record_playback_state() {
  local layout="$1" context="$2" state position
  read -r state position < <(read_playback_state "$layout")
  position="${position:-unknown}"
  mark_event "playback-state context=$context state=$state position=$position"
  echo "$context: playback-state=$state position=$position"
  PLAYBACK_LAST_STATE="$state"
  PLAYBACK_LAST_POSITION="$position"
}

record_screen_orientation() {
  local layout="$1" name="$2"
  local orientation
  orientation="$(python3 - "$layout" <<'PY'
import json
import re
import sys

layout = sys.argv[1]
data = json.load(open(layout, encoding="utf-8"))
bounds = data.get("attributes", {}).get("bounds", "")
match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
if not match:
    raise SystemExit(f"screen layout has no root bounds: {bounds!r}")
x1, y1, x2, y2 = map(int, match.groups())
width, height = x2 - x1, y2 - y1
print("landscape" if width > height else "portrait")
PY
  )"
  echo "$name: $orientation"
  mark_event "screen-orientation $name=$orientation"
}

assert_orientation() {
  local layout="$1" name="$2" expected="$3" orientation
  record_screen_orientation "$layout" "$name"
  orientation="$(python3 - "$layout" <<'PY'
import json
import re
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
bounds = data.get("attributes", {}).get("bounds", "")
match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
if not match:
    raise SystemExit(1)
x1, y1, x2, y2 = map(int, match.groups())
print("landscape" if x2 - x1 > y2 - y1 else "portrait")
PY
  )"
  if [[ "$orientation" != "$expected" ]]; then
    echo "unexpected orientation for $name: expected=$expected actual=$orientation" >&2
    return 1
  fi
  mark_event "orientation-verified $name=$expected"
}

assert_landscape_fullscreen() {
  assert_orientation "$1" "$2" landscape
}

layout_orientation() {
  python3 - "$1" <<'PY'
import json
import re
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
bounds = data.get("attributes", {}).get("bounds", "")
match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
if not match:
    raise SystemExit(1)
x1, y1, x2, y2 = map(int, match.groups())
print("landscape" if x2 - x1 > y2 - y1 else "portrait")
PY
}

wait_for_playing_layout() {
  local layout="$1" label="$2" state position
  local retries="${VERIFY_PLAYING_STATE_RETRIES:-8}"
  local wait_seconds="${VERIFY_PLAYING_STATE_WAIT:-1}"
  for ((attempt=1; attempt<=retries; attempt++)); do
    if ! assert_target_app_layout "$layout"; then
      # Do not send wake taps into a different foreground application after
      # a device/app switch. The caller will retain the failed sample and
      # report the foreground-app mismatch as the authoritative cause.
      return 1
    fi
    # The control bar is transient. After a buffering sample it may have
    # timed out before the next dump, which would make a real player state
    # look like `unknown`. Re-wake from the latest authoritative layout before
    # each retry, while keeping the operation fully script-driven.
    if (( attempt > 1 )); then
      click_layout_point "$CONTROL_WAKE_MODE" "$layout"
      sleep "${VERIFY_CONTROL_WAIT:-0.1}"
      pull_layout "$(basename "$layout")"
    fi
    read -r state position < <(read_playback_state "$layout")
    if [[ "$state" == playing ]]; then
      mark_event "playing-state-ready $label attempt=$attempt position=${position:-unknown}"
      return 0
    fi
    mark_event "playing-state-wait $label attempt=$attempt state=$state position=${position:-unknown}"
    if (( attempt < retries )); then
      sleep "$wait_seconds"
    fi
  done
  mark_event "playing-state-failed $label"
  return 1
}

assert_playback_progress() {
  local prefix="$1" current_layout="$2" allow_restart_progress="${3:-0}"
  local wait_seconds="${VERIFY_PROGRESS_WAIT:-2}"
  local before_name="${prefix}-before.json" after_name="${prefix}-after.json"
  local before_layout="$ROOT/$before_name" after_layout="$ROOT/$after_name"
  local before_state before_position after_state after_position frame_delta

  # Wake the controls so a playback state is exposed when the platform
  # provides it. Fullscreen native-surface dumps may expose only a Slider;
  # that case is accepted later only with both Slider progress and a visible
  # video-frame change.
  click_layout_point "$WAKE_MODE" "$current_layout"
  sleep "${VERIFY_CONTROL_WAIT:-0.1}"
  pull_layout "$before_name"
  read -r before_state before_position < <(read_playback_state "$before_layout")
  if [[ "$before_state" == unknown ]]; then
    local state_retries="${VERIFY_PLAYING_STATE_RETRIES:-8}"
    local state_wait="${VERIFY_PLAYING_STATE_WAIT:-1}"
    local attempt=1
    while (( attempt <= state_retries )) && [[ "$before_state" == unknown ]]; do
      sleep "$state_wait"
      click_layout_point "$WAKE_MODE" "$current_layout"
      pull_layout "$before_name"
      read -r before_state before_position < <(read_playback_state "$before_layout")
      mark_event "playing-state-wait $prefix-before attempt=$attempt state=$before_state position=${before_position:-unknown}"
      ((attempt++))
    done
  fi
  if [[ "$before_state" == buffering ]]; then
    if ! wait_for_playing_layout "$before_layout" "${prefix}-before"; then
      read -r before_state before_position < <(read_playback_state "$before_layout")
      if [[ -z "$before_position" || "$before_position" == unknown ]]; then
        echo "playback state: did not reach playing before sample: $prefix" >&2
        return 1
      fi
      mark_event "playing-state-semantic-unavailable ${prefix}-before position=$before_position"
    fi
    read -r before_state before_position < <(read_playback_state "$before_layout")
  fi
  capture_display "${prefix}-before"
  sleep "$wait_seconds"
  if ! pull_layout "$after_name"; then
    mark_event "playback-progress-failed $prefix reason=after-layout-unavailable"
    echo "playback state: after-sample layout unavailable: $prefix" >&2
    return 1
  fi
  if [[ ! -s "$after_layout" ]]; then
    mark_event "playback-progress-failed $prefix reason=after-layout-empty"
    echo "playback state: after-sample layout is empty: $prefix" >&2
    return 1
  fi
  read -r after_state after_position < <(read_playback_state "$after_layout")
  if [[ "$after_state" == buffering || "$after_state" == unknown ]]; then
    if ! wait_for_playing_layout "$after_layout" "${prefix}-after"; then
      read -r after_state after_position < <(read_playback_state "$after_layout")
      if [[ -z "$after_position" || "$after_position" == unknown ]]; then
        echo "playback state: did not return to playing after sample: $prefix" >&2
        return 1
      fi
      mark_event "playing-state-semantic-unavailable ${prefix}-after position=$after_position"
    fi
    read -r after_state after_position < <(read_playback_state "$after_layout")
  fi
  if ! capture_display "${prefix}-after"; then
    mark_event "playback-progress-failed $prefix reason=after-frame-unavailable"
    echo "playback state: after-sample frame unavailable: $prefix" >&2
    return 1
  fi
  if [[ ! -s "$ROOT/${prefix}-before.jpeg" ||
        ! -s "$ROOT/${prefix}-after.jpeg" ]]; then
    mark_event "playback-progress-failed $prefix reason=frame-artifact-missing"
    echo "playback state: frame artifact missing: $prefix" >&2
    return 1
  fi

  frame_delta="$(python3 - "$ROOT/${prefix}-before.jpeg" "$ROOT/${prefix}-after.jpeg" <<'PY'
from PIL import Image, ImageChops, ImageStat
import sys

before = Image.open(sys.argv[1]).convert("RGB")
after = Image.open(sys.argv[2]).convert("RGB")
if before.size != after.size:
    after = after.resize(before.size)
w, h = before.size
# Compare the central video image only. Exclude the title/status strip and
# bottom controls so control-bar animation, clock changes, and button fades
# cannot be used as playback evidence.
if w >= h:
    box = (max(0, int(w * .04)), int(h * .13), int(w * .96), int(h * .78))
else:
    box = (int(w * .05), int(h * .14), int(w * .95), int(h * .70))
delta = ImageChops.difference(before.crop(box), after.crop(box))
mean = sum(ImageStat.Stat(delta).mean) / 3.0
changed = mean >= 1.5
print("changed" if changed else "unchanged")
PY
)"
  mark_event "playback-sample $prefix before=$before_state after=$after_state frame=$frame_delta"
  echo "$prefix: before=$before_state after=$after_state frame=$frame_delta"

  if [[ "$before_state" == paused || "$after_state" == paused ]]; then
    mark_event "playback-progress-failed $prefix reason=paused"
    echo "playback state: paused; refusing to use this sample as playback proof" >&2
    return 1
  fi
  if [[ "$before_state" != playing || "$after_state" != playing ]]; then
    if [[ "${VERIFY_ALLOW_WEAK_PLAYBACK_EVIDENCE:-0}" == "1" &&
          "$allow_restart_progress" == "1" &&
          "$frame_delta" == changed &&
          -n "$before_position" && -n "$after_position" &&
          "$before_position" != "$after_position" &&
          "$before_state" != paused && "$after_state" != paused &&
          "$before_state" != buffering && "$after_state" != buffering ]]; then
      mark_event "playback-progress-observed $prefix evidence=restart-position-plus-video-frame before_position=$before_position after_position=$after_position"
      echo "playback progression observed: $prefix (restart position and visible video crop changed)"
      return 0
    fi
    if [[ "${VERIFY_ALLOW_WEAK_PLAYBACK_EVIDENCE:-0}" == "1" &&
          "$before_state" != buffering && "$after_state" != buffering &&
          "$before_state" == playing &&
          "$frame_delta" == changed ]]; then
      mark_event "playback-progress-observed $prefix evidence=playing-before-plus-video-frame before_position=$before_position after_position=$after_position"
      echo "playback progression observed: $prefix (playing state and visible video crop changed)"
      return 0
    fi
    if [[ "${VERIFY_ALLOW_WEAK_PLAYBACK_EVIDENCE:-0}" == "1" &&
          "$frame_delta" == changed &&
          -n "$before_position" && -n "$after_position" &&
          "$before_position" != unknown && "$after_position" != unknown &&
          "$before_position" != "$after_position" &&
          "$before_state" != paused && "$after_state" != paused &&
          "$before_state" != buffering && "$after_state" != buffering ]]; then
      # Native-surface layouts on some OHOS builds expose only the Slider
      # percentage and omit the semantic play/pause node. A changing Slider
      # position plus a changing central video crop is accepted as playback
      # evidence only when neither sample is buffering; a position change
      # alone, or a frame change during buffering, is never sufficient.
      mark_event "playback-progress-observed $prefix evidence=slider-plus-video-frame before_position=$before_position after_position=$after_position"
      echo "playback progression observed: $prefix (slider position and visible video crop changed)"
      return 0
    fi
    if [[ "${VERIFY_ALLOW_VISUAL_PLAYBACK:-${VERIFY_ALLOW_VISUAL_PROGRESS_ONLY:-0}}" == "1" &&
          "$frame_delta" == changed &&
          "$before_state" != buffering && "$after_state" != buffering &&
          "$before_state" != paused && "$after_state" != paused ]]; then
      # Some OHOS native-surface dumps omit both the play/pause node and a
      # useful Slider position after a fullscreen transition. Keep this
      # explicitly opt-in: a changing central crop proves rendered-frame
      # progress only, not the semantic playing state.
      mark_event "playback-progress-observed $prefix evidence=video-crop-frame-only before_state=$before_state after_state=$after_state"
      echo "video frame progression observed: $prefix (semantic playing state unavailable; diagnostic-only)"
      return 0
    fi
    if [[ "$before_state" == buffering || "$after_state" == buffering ]]; then
      mark_event "playback-progress-failed $prefix reason=buffering-not-settled before=$before_state after=$after_state"
      echo "playback state: buffering; sample did not settle to playing: $prefix" >&2
    else
      mark_event "playback-progress-failed $prefix reason=semantic-unknown before=$before_state after=$after_state"
      echo "playback state: unknown; semantic playing state was not present" >&2
    fi
    return 1
  fi

  if [[ "$before_position" != "$after_position" && -n "$before_position" && -n "$after_position" ]]; then
    # Position is useful corroboration, but it is not visible-frame evidence:
    # audio/time can advance while the video surface is frozen or gray.
    mark_event "playback-position-observed $prefix before=$before_position after=$after_position"
  fi
  if [[ "$frame_delta" == changed ]]; then
    mark_event "playback-progress-observed $prefix evidence=playing-state-plus-frame before_position=$before_position after_position=$after_position"
    echo "playback progression observed: $prefix (visible video crop changed)"
    return 0
  fi

  mark_event "playback-progress-failed $prefix reason=unknown"
  echo "playback state: unknown; playing state had no position or frame progression" >&2
  return 1
}

refresh_hilog_snapshot() {
  local snapshot="$ROOT/hilog-snapshot.txt"
  if run_hdc shell hilog -x >"$snapshot" 2>&1; then
    cat "$snapshot" >>"$ROOT/hilog.txt"
    return 0
  fi
  return 1
}

has_update_dialog() {
  # Do not match the generic phrase "新版本": recommendation titles commonly
  # contain it (for example, "迎新版本推送") without showing a dialog. Keep
  # only release-notice wording or explicit update actions.
  grep -Eiq '发现新版本|版本更新|立即更新|更新内容|new[[:space:]]+version|update available' "$1"
}

dismiss_update_dialog() {
  local layout="$1"
  if ! has_update_dialog "$layout"; then
    return 0
  fi
  local action
  for action in 取消 不再提醒 稍后再说 以后再说 关闭 Cancel "Not now" Close; do
    if read_bounds "$layout" "$action" >/dev/null 2>&1; then
      echo "dismiss version dialog with action=$action"
      mark_event "version-dialog-dismiss action=$action"
      click_text "$layout" "$action"
      sleep "${VERIFY_DIALOG_WAIT:-0.3}"
      return 0
    fi
  done
  echo "version dialog detected but no known dismiss action was exposed: $layout" >&2
  mark_event "version-dialog-unknown-action"
  return 1
}

dismiss_usb_connection_dialog() {
  local layout="$1"
  if ! grep -Fq 'USB 连接方式' "$layout"; then
    return 0
  fi
  if read_bounds "$layout" 确定 >/dev/null 2>&1; then
    echo "dismiss USB connection dialog with action=确定"
    mark_event "usb-connection-dialog-dismiss action=确定"
    click_text "$layout" 确定
    sleep "${VERIFY_DIALOG_WAIT:-0.3}"
    return 0
  fi
  echo "USB connection dialog detected but no 确定 action was exposed: $layout" >&2
  mark_event "usb-connection-dialog-unknown-action"
  return 1
}

dismiss_system_quick_panel() {
  local layout="$1"
  # A quick-settings panel can remain above the app after a physical-device
  # reconnect.  It has no app search/player semantics; close it through the
  # scripted Back event before resolving any app control.
  if ! grep -Fq '编辑' "$layout" || ! grep -Fq '截屏' "$layout"; then
    return 0
  fi
  echo "dismiss system quick panel with scripted Back"
  mark_event "system-quick-panel-dismiss action=Back"
  run_hdc shell uitest uiInput keyEvent Back >/dev/null
  sleep "${VERIFY_DIALOG_WAIT:-0.3}"
}

transition_fullscreen() {
  local from_layout="$1" prefix="$2" expected="$3" target_label="$4"
  local source_label
  if [[ "$target_label" == "退出全屏" ]]; then
    source_label=全屏
  else
    source_label=退出全屏
  fi
  # The caller's layout is evidence for the preceding state only.  Never use
  # it for an action: an attachment or transient control bar can have changed
  # while the previous step was collecting screenshots/logs.
  assert_target_app_layout "$from_layout" || return 1
  # The control bar is animated and transient. Do not capture a screenshot
  # before the click: display capture can consume the short visibility window
  # and make the subsequently resolved semantic bounds stale. Resolve and
  # click from the newest layout first; immediate/stable screenshots below
  # remain the authoritative transition evidence. Give the automatic
  # hide/show animation the same bounded semantic retry used after a
  # transition; never fall back to a guessed fullscreen coordinate.
  local control_attempts="${VERIFY_CONTROL_RETRIES:-8}"
  # Controls time out quickly on the device. The layout dump is already the
  # expensive synchronization point; keep the post-wake retry window short so
  # a valid fresh target is not turned into an IgnorePointer layer before the
  # scripted click reaches Flutter.
  local control_wait="${VERIFY_CONTROL_RETRY_WAIT:-0.1}"
  local control_ready=0
  for ((control_attempt=1; control_attempt<=control_attempts; control_attempt++)); do
    pull_layout "${prefix}-controls-click-${control_attempt}.json"
    assert_target_app_layout \
      "$ROOT/${prefix}-controls-click-${control_attempt}.json" || return 1
    if python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
        "$ROOT/${prefix}-controls-click-${control_attempt}.json" >/dev/null 2>&1; then
      cp "$ROOT/${prefix}-controls-click-${control_attempt}.json" \
        "$ROOT/${prefix}-controls-click.json"
      control_ready=1
      mark_event "fullscreen-control-ready prefix=${prefix} attempt=${control_attempt}"
      break
    fi
    mark_event "fullscreen-control-wait prefix=${prefix} attempt=${control_attempt}"
    if (( control_attempt < control_attempts )); then
      sleep "$control_wait"
      # Wake only once per fresh layout, and make the following iteration
      # resolve a new semantic fullscreen target before it may click.
      click_layout_point "$CONTROL_WAKE_MODE" \
        "$ROOT/${prefix}-controls-click-${control_attempt}.json"
    fi
  done
  if (( control_ready == 0 )); then
    echo "fullscreen control was not exposed at click time: ${prefix}" >&2
    mark_event "fullscreen-control-failed prefix=${prefix}"
    return 1
  fi
  python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
    "$ROOT/${prefix}-controls-click.json" >/dev/null || {
    echo "fullscreen control was not exposed at click time: ${prefix}" >&2
    mark_event "fullscreen-control-failed prefix=${prefix}"
    return 1
  }
  assert_fullscreen_label "$ROOT/${prefix}-controls-click.json" "$source_label" || return 1
  local action_pid
  action_pid="$(require_target_pid)" || return 1
  local attachment
  attachment="$(resolve_active_input_identity "$action_pid")" || {
    mark_event "fullscreen-attachment-missing prefix=${prefix} pid=${action_pid}"
    return 1
  }
  mark_event "fullscreen-attachment-current prefix=${prefix} pid=${action_pid} channel=$RESOLVED_INPUT_CHANNEL ${attachment}"
  mark_event "fullscreen-action-process prefix=${prefix} pid=${action_pid}"
  local request_direction=enter
  if [[ "$target_label" == "全屏" ]]; then
    request_direction=exit
  fi
  # Use the same fresh-layout one-action gate used by the initial transition.
  # Reusing an accessibility coordinate from the pre-animation dump can land
  # on the video surface after a rotation; this helper fails instead of
  # retrying and records a per-transition causal input trace.
  run_single_fullscreen_input "$request_direction" \
    "$ROOT/${prefix}-controls-click.json" "$prefix" || return 1
  mark_event "${prefix}-fullscreen-clicked"
  local request_pid
  request_pid="$(require_target_pid)" || return 1
  if [[ "$request_pid" != "$action_pid" ]]; then
    mark_event "fullscreen-action-process-changed prefix=${prefix} before=${action_pid} after=${request_pid}"
    echo "target process changed during fullscreen input: ${action_pid} -> ${request_pid}" >&2
    return 1
  fi
  sleep "${VERIFY_TOGGLE_IMMEDIATE_WAIT:-0.1}"
  capture_toggle_state "${prefix}-fullscreen-immediate"
  sleep "${VERIFY_TOGGLE_WAIT:-2}"
  capture_toggle_state "${prefix}-fullscreen-stable"
  local orientation_verified=0
  if assert_orientation "$ROOT/${prefix}-fullscreen-stable.json" \
    "${prefix}-fullscreen-stable" "$expected"; then
    orientation_verified=1
  else
    # OHOS applies the orientation request asynchronously. A transient
    # portrait/landscape layout immediately after the semantic click is not
    # itself a transition failure; resample the layout for a bounded window.
    # Keep the final assertion fail-closed when the requested orientation does
    # not settle within that window.
    local orientation_retries="${VERIFY_ORIENTATION_RETRIES:-6}"
    local orientation_retry_wait="${VERIFY_ORIENTATION_RETRY_WAIT:-1}"
    local orientation_attempt orientation
    for ((orientation_attempt=1; orientation_attempt<=orientation_retries; orientation_attempt++)); do
      sleep "$orientation_retry_wait"
      pull_layout "${prefix}-fullscreen-stable-attempt-${orientation_attempt}.json"
      orientation="$(layout_orientation "$ROOT/${prefix}-fullscreen-stable-attempt-${orientation_attempt}.json")"
      mark_event "orientation-resample ${prefix}-fullscreen-stable attempt=${orientation_attempt} actual=${orientation} expected=${expected}"
      if [[ "$orientation" == "$expected" ]]; then
        cp "$ROOT/${prefix}-fullscreen-stable-attempt-${orientation_attempt}.json" \
          "$ROOT/${prefix}-fullscreen-stable.json"
        mark_event "orientation-resample-verified ${prefix}-fullscreen-stable attempt=${orientation_attempt}"
        orientation_verified=1
        break
      fi
    done
  fi
  if (( orientation_verified == 0 )); then
    echo "orientation did not settle for ${prefix}: expected=${expected}" >&2
    return 1
  fi
  ensure_fullscreen_controls_visible "$ROOT/${prefix}-fullscreen-stable.json"
  wait_for_fullscreen_label_after_wake \
    "$ROOT/${prefix}-fullscreen-stable.json" "$prefix" "$target_label" || return 1
  if [[ "$FREEZE_FRAME" != "1" ]]; then
    # The historical failure is a playing-state transition failure. Prove the
    # video crop continues changing after this specific transition, including
    # the final re-entry, instead of relying on the pre-click sample.
    if ! assert_playback_progress "${prefix}-post-transition" \
      "$ROOT/${prefix}-fullscreen-stable.json"; then
      # A long cycle run can legitimately reach the end during the preceding
      # transition. Recover only the explicit end-of-source state; all other
      # paused/buffering failures remain fail-closed. The seek and subsequent
      # progress assertion happen while still fullscreen, so the transition
      # itself is still exercised in a real playing state.
      local recovery_layout="$ROOT/${prefix}-post-transition-after.json"
      local recovery_state recovery_position
      if [[ ! -f "$recovery_layout" ]]; then
        # assert_playback_progress can fail before its after-layout capture
        # when the source remains buffering/unknown. Do not reinterpret that
        # failure as end-of-source and do not dereference a missing artifact.
        return 1
      fi
      read -r recovery_state recovery_position < <(
        read_playback_state "$recovery_layout"
      )
      if [[ "$recovery_state" == completed ]]; then
        mark_event "playback-ended-recovery prefix=${prefix} position=$recovery_position"
        # Use the layout from the failed post-transition sample. The stable
        # transition dump can be stale after an asynchronous orientation or
        # surface update; using it here can send the seek click to the wrong
        # axis/bounds and leave the source at 100%.
        reset_playback_to_start "$recovery_layout" \
          "${prefix}-playback-restart" || return 1
        recovery_layout="$ROOT/${prefix}-playback-restart-after-seek.json"
        if [[ -f "$ROOT/${prefix}-playback-restart-after-play.json" ]]; then
          recovery_layout="$ROOT/${prefix}-playback-restart-after-play.json"
        fi
        assert_playback_progress "${prefix}-post-transition-restart" \
          "$recovery_layout" 1 || return 1
      else
        return 1
      fi
    fi
  fi
  TRANSITION_LAYOUT="$ROOT/${prefix}-fullscreen-stable.json"
}

if [[ -n "$HAP" ]]; then
  verify_hap_native_diagnostics
  run_hdc install -r -d "$HAP" >/dev/null
fi
run_hdc shell echo connected >/dev/null

# Start before launching the app so HDR decision/configuration logs are not
# lost before the fullscreen transition begins.  Re-entry probes deliberately
# reuse a live player; clearing hilog there would erase the output-attachment
# evidence produced before this script was invoked.
if [[ "$REUSE_CURRENT_APP" != 1 ]]; then
  run_hdc shell hilog -r >/dev/null 2>&1 || true
fi
if [[ -n "${VERIFY_LOG_SECONDS:-}" ]]; then
  LOG_SECONDS="$VERIFY_LOG_SECONDS"
else
  # A four-marker action can legitimately take almost 300 seconds to arrive;
  # keep
  # the root stream alive through preparation, every action, and final drain.
  LOG_SECONDS=1800
fi
start_hilog_capture
FULLSCREEN_CONSUMED_OFFSET_FILE="$ROOT/fullscreen-consumed-marker-offset"
printf '0\n' >"$FULLSCREEN_CONSUMED_OFFSET_FILE"
mark_event "fullscreen-marker-ledger-init file=$(basename "$FULLSCREEN_CONSUMED_OFFSET_FILE")"

if [[ "$REUSE_CURRENT_APP" == 1 ]]; then
  run_hdc shell pidof "$PACKAGE" >"$ROOT/pid-reuse-before.txt" 2>&1 || true
  if [[ ! -s "$ROOT/pid-reuse-before.txt" ]]; then
    echo "VERIFY_REUSE_CURRENT_APP=1 requires a running app process" >&2
    exit 2
  fi
  mark_event "reuse-current-app pid=$(tr -d '\r\n' < "$ROOT/pid-reuse-before.txt")"
else
  run_hdc shell aa force-stop "$PACKAGE" >/dev/null 2>&1 || true
  run_hdc shell aa start -a EntryAbility -b "$PACKAGE" >/dev/null
  sleep "${VERIFY_START_WAIT:-12}"
fi
pull_layout 01-home.json

# A wakeup only turns the display on; it does not bypass the device's
# credential/fingerprint lock. Stop with an explicit prerequisite instead of
# reporting the lock-screen tree as an application-page failure.
if grep -Eiq 'ScreenLockRootComponent|ScreenLockFingerprintView|未识别成功|屏幕解锁' \
    "$ROOT/01-home.json"; then
  echo "device is locked; unlock the physical device and rerun the scripted verification" >&2
  mark_event "device-lock-screen-detected"
  exit 2
fi

# A quick-settings panel can survive a USB reconnect and cover the app.
# Resolve it from semantic system-panel markers; never send app input through
# an indeterminate overlay.
if grep -Fq '编辑' "$ROOT/01-home.json" && grep -Fq '截屏' "$ROOT/01-home.json"; then
  dismiss_system_quick_panel "$ROOT/01-home.json"
  pull_layout 01-home-after-system-panel.json
fi

# A physical USB connection can expose the system USB-mode dialog over the
# freshly started app. Dismiss it semantically before resolving app targets;
# never send search input or a coordinate click through this system overlay.
if grep -Fq 'USB 连接方式' "$ROOT/01-home.json"; then
  dismiss_usb_connection_dialog "$ROOT/01-home.json"
  pull_layout 01-home-after-usb-dialog.json
fi

# Select the newest layout before checking the version dialog so system
# overlays dismissed above cannot make the update check inspect stale state.
home_layout="$ROOT/01-home.json"
if [[ -f "$ROOT/01-home-after-system-panel.json" ]]; then
  home_layout="$ROOT/01-home-after-system-panel.json"
fi
if [[ -f "$ROOT/01-home-after-usb-dialog.json" ]]; then
  home_layout="$ROOT/01-home-after-usb-dialog.json"
fi

# A fresh app-data run may show the release-notice dialog before the search
# control is actionable. Dismiss it semantically from the current layout.
if has_update_dialog "$home_layout"; then
  dismiss_update_dialog "$home_layout"
  pull_layout 01-home-after-dialog.json
  has_update_dialog "$ROOT/01-home-after-dialog.json" && {
    echo "version dialog remained after scripted dismissal" >&2
    exit 1
  }
  home_layout="$ROOT/01-home-after-dialog.json"
fi

# Home exposes the search control. If the app is already on its search page,
# the current layout simply skips this click.

is_target_video_page() {
  grep -q "$SOURCE" "$1" &&
    ! grep -q '"type":"TextInput"' "$1" &&
    grep -q '"type":"Slider"' "$1" &&
    python3 "$SCRIPT_DIR/ohos_ui_layout.py" video-wake "$1" >/dev/null 2>&1
}

is_target_search_results_page() {
  grep -q "$SOURCE" "$1" &&
    ! grep -q '视频 0' "$1" &&
    ! grep -q '没有数据' "$1" &&
    grep -Eq '视频 [1-9][0-9]*' "$1" &&
    python3 "$SCRIPT_DIR/ohos_ui_layout.py" first-video "$1" >/dev/null 2>&1
}

is_any_search_results_page() {
  ! grep -q '视频 0' "$1" &&
    ! grep -q '没有数据' "$1" &&
    grep -Eq '视频 [1-9][0-9]*' "$1" &&
    python3 "$SCRIPT_DIR/ohos_ui_layout.py" first-video "$1" >/dev/null 2>&1
}

is_empty_search_results_page() {
  (grep -q '视频 0' "$1" || grep -q '没有数据' "$1") &&
    grep -q '"text":"返回"' "$1" &&
    ! grep -q '"type":"TextInput"' "$1"
}

is_search_input_page() {
  grep -q '"type":"TextInput"' "$1" &&
    python3 "$SCRIPT_DIR/ohos_ui_layout.py" search-input "$1" >/dev/null 2>&1
}

wait_for_opened_target_video() {
  local first_layout="$1"
  local attempt layout
  if is_target_video_page "$first_layout"; then
    cp "$first_layout" "$ROOT/04-after-open.json"
    return 0
  fi
  for attempt in $(seq 1 "${VERIFY_OPEN_VIDEO_RETRIES:-8}"); do
    layout="$ROOT/04-after-open-attempt-${attempt}.json"
    pull_layout "04-after-open-attempt-${attempt}.json"
    if is_target_video_page "$layout"; then
      cp "$layout" "$ROOT/04-after-open.json"
      mark_event "target-video-open-ready attempt=$attempt"
      return 0
    fi
    if grep -q '点击重试' "$layout"; then
      click_text "$layout" 点击重试
      mark_event "target-video-open-retry attempt=$attempt"
    fi
    if (( attempt < ${VERIFY_OPEN_VIDEO_RETRIES:-8} )); then
      sleep "${VERIFY_OPEN_VIDEO_WAIT:-2}"
    fi
  done
  echo "target video page did not become ready after opening result" >&2
  echo "artifacts: $ROOT" >&2
  return 1
}

# force-stop/start may restore the previous video detail page, and the first
# layout dump can still contain only the Flutter XComponent while that page is
# being rebuilt. Wait for a semantically identifiable state before choosing
# the search path; never click or type against an indeterminate layout.
ready_layout=0
for attempt in $(seq 1 8); do
  if is_target_video_page "$home_layout"; then
    ready_layout=1
    break
  fi
  if is_target_search_results_page "$home_layout"; then
    ready_layout=1
    break
  fi
  if is_search_input_page "$home_layout"; then
    ready_layout=1
    break
  fi
  if python3 "$SCRIPT_DIR/ohos_ui_layout.py" home-search "$home_layout" >/dev/null 2>&1; then
    ready_layout=1
    break
  fi
  # A force-stop/start can restore a different video's detail page. Leave it
  # through the semantic Back path before retrying the home/search resolver;
  # never click a recommended video's first play button as a substitute for
  # the requested BVID.
  if grep -q '"type":"Slider"' "$home_layout" &&
     ! is_target_video_page "$home_layout"; then
    run_hdc shell uitest uiInput keyEvent Back >/dev/null
    mark_event "leave-non-target-video-page attempt=$attempt"
  fi
  if is_any_search_results_page "$home_layout" &&
     ! is_target_search_results_page "$home_layout"; then
    run_hdc shell uitest uiInput keyEvent Back >/dev/null
    mark_event "leave-non-target-search-results-page attempt=$attempt"
  fi
  if is_empty_search_results_page "$home_layout"; then
    run_hdc shell uitest uiInput keyEvent Back >/dev/null
    mark_event "leave-empty-search-results-page attempt=$attempt"
  fi
  if (( attempt < 8 )); then
    sleep 2
    next_layout="$ROOT/01-home-ready-${attempt}.json"
    pull_layout "01-home-ready-${attempt}.json"
    home_layout="$next_layout"
    if has_update_dialog "$home_layout"; then
      dismiss_update_dialog "$home_layout"
      pull_layout "01-home-ready-${attempt}-after-dialog.json"
      home_layout="$ROOT/01-home-ready-${attempt}-after-dialog.json"
    fi
  fi
done
if (( ready_layout == 0 )); then
  echo "unable to identify target video page or search page after scripted wait" >&2
  exit 1
fi
if is_target_video_page "$home_layout"; then
  # force-stop/start may restore the last video detail page. Reuse it instead
  # of assuming the first layout is the home page and tapping a nonexistent
  # search field.
  echo "reuse current target video page: $SOURCE"
  cp "$home_layout" "$ROOT/04-after-open.json"
elif is_target_search_results_page "$home_layout"; then
  click_layout_point first-video "$home_layout"
  sleep 1
  wait_for_opened_target_video "$home_layout"
elif is_search_input_page "$home_layout"; then
  cp "$home_layout" "$ROOT/02-search.json"
  fill_search_input "$ROOT/02-search.json" "$SOURCE"
  sleep 1
  pull_layout 02-filled.json
  assert_target_app_layout "$ROOT/02-filled.json" || exit 1
  click_layout_point search-submit "$ROOT/02-filled.json"
  result_ready=0
  result_retries="${VERIFY_SEARCH_RESULT_RETRIES:-12}"
  result_wait="${VERIFY_SEARCH_RESULT_WAIT:-2}"
  for result_attempt in $(seq 1 "$result_retries"); do
    result_layout="03-results-${result_attempt}.json"
    pull_layout "$result_layout"
    # A layout rooted at SceneBoard can be observed briefly while the target
    # process remains alive and the search result page is settling.  Never
    # act on that layout: take only a bounded passive wait, then fail closed
    # if the target app does not become the current UI root again.
    if ! is_target_app_layout "$ROOT/$result_layout"; then
      mark_event "search-results-nontarget-layout attempt=$result_attempt layout=$(basename "$result_layout")"
      if (( result_attempt < result_retries )); then
        sleep "$result_wait"
        continue
      fi
      assert_target_app_layout "$ROOT/$result_layout" || exit 1
    fi
    if is_target_video_page "$ROOT/$result_layout"; then
      cp "$ROOT/$result_layout" "$ROOT/04-after-open.json"
      result_ready=2
      break
    elif is_target_search_results_page "$ROOT/$result_layout"; then
      cp "$ROOT/$result_layout" "$ROOT/03-results.json"
      result_ready=1
      break
    fi
    if grep -q '点击重试' "$ROOT/$result_layout"; then
      click_text "$ROOT/$result_layout" 点击重试
      mark_event "search-results-retry attempt=$result_attempt"
    fi
    if (( result_attempt < result_retries )); then
      sleep "$result_wait"
    fi
  done
  if (( result_ready == 0 )); then
    echo "target video result not found after scripted wait" >&2
    exit 1
  fi
  if (( result_ready == 1 )); then
    click_layout_point first-video "$ROOT/03-results.json"
    sleep 1
    wait_for_opened_target_video "$ROOT/03-results.json"
  fi
else
  if python3 "$SCRIPT_DIR/ohos_ui_layout.py" home-search "$home_layout" >/dev/null 2>&1; then
    click_layout_point home-search "$home_layout"
    sleep 1
  fi
  pull_layout 02-search.json
  fill_search_input "$ROOT/02-search.json" "$SOURCE"
  sleep 1
  pull_layout 02-filled.json
  assert_target_app_layout "$ROOT/02-filled.json" || exit 1
  click_layout_point search-submit "$ROOT/02-filled.json"
  # Search results may be delayed by network or account state.  Wait for the
  # semantic video-result hit target instead of assuming a fixed response
  # time; an empty/partial dump must never receive a coordinate click.
  result_ready=0
  result_retries="${VERIFY_SEARCH_RESULT_RETRIES:-12}"
  result_wait="${VERIFY_SEARCH_RESULT_WAIT:-2}"
  for result_attempt in $(seq 1 "$result_retries"); do
    result_layout="03-results-${result_attempt}.json"
    pull_layout "$result_layout"
    # Do not send a retry or result click to a transient system UI root.
    # Waiting here has no input side effect and remains bounded by the
    # existing search-result retry policy.
    if ! is_target_app_layout "$ROOT/$result_layout"; then
      mark_event "search-results-nontarget-layout attempt=$result_attempt layout=$(basename "$result_layout")"
      if (( result_attempt < result_retries )); then
        sleep "$result_wait"
        continue
      fi
      assert_target_app_layout "$ROOT/$result_layout" || exit 1
    fi
    if is_target_video_page "$ROOT/$result_layout"; then
      cp "$ROOT/$result_layout" "$ROOT/04-after-open.json"
      result_ready=2
      break
    elif is_target_search_results_page "$ROOT/$result_layout"; then
      cp "$ROOT/$result_layout" "$ROOT/03-results.json"
      result_ready=1
      break
    fi
    if grep -q '点击重试' "$ROOT/$result_layout"; then
      click_text "$ROOT/$result_layout" 点击重试
      mark_event "search-results-retry attempt=$result_attempt"
    fi
    mark_event "search-results-wait attempt=$result_attempt"
    if (( result_attempt < result_retries )); then
      sleep "$result_wait"
    fi
  done
  if (( result_ready == 0 )); then
    echo "target video result not found after scripted wait" >&2
    exit 1
  fi
  if (( result_ready == 1 )); then
    click_layout_point first-video "$ROOT/03-results.json"
    sleep 1
    wait_for_opened_target_video "$ROOT/03-results.json"
  fi
fi

# The same notice can be deferred until the first video page is created.
# Re-run the semantic dismissal against the fresh layout before touching the
# video controls.
if has_update_dialog "$ROOT/04-after-open.json"; then
  dismiss_update_dialog "$ROOT/04-after-open.json"
  pull_layout 04-after-open-after-dialog.json
  has_update_dialog "$ROOT/04-after-open-after-dialog.json" && {
    echo "version dialog remained after scripted dismissal" >&2
    exit 1
  }
fi

# This prompt is account/device dependent; accept it only when it exists.
after_open_layout="$ROOT/04-after-open.json"
if [[ -f "$ROOT/04-after-open-after-dialog.json" ]]; then
  after_open_layout="$ROOT/04-after-open-after-dialog.json"
fi
if grep -q '本次使用允许' "$after_open_layout"; then
  click_text "$after_open_layout" 本次使用允许
fi

sleep "${VERIFY_FIRST_FRAME_WAIT:-3}"
# Re-entry can create the detail page before the new player publishes its
# Slider/native surface. Refresh the semantic layout after the first-frame
# wait so seek/control operations never use the pre-attachment dump.
pull_layout 04-after-open-ready.json
if grep -q "$SOURCE" "$ROOT/04-after-open-ready.json" &&
   grep -q '"type":"Slider"' "$ROOT/04-after-open-ready.json"; then
  after_open_layout="$ROOT/04-after-open-ready.json"
fi
capture_display 05-windowed
pull_layout 05-windowed.json
base_orientation="$(layout_orientation "$ROOT/05-windowed.json")"
mark_event "windowed-baseline-orientation=$base_orientation"
echo "windowed baseline orientation: $base_orientation"
if [[ "$VERTICAL_VIDEO" == 1 && "$base_orientation" != portrait ]]; then
  echo "vertical source baseline is not portrait: $base_orientation" >&2
  exit 1
fi

if [[ "${VERIFY_REQUIRE_HDR:-1}" == "1" ]]; then
  sleep "${VERIFY_HDR_DECISION_WAIT:-0.5}"
  native_hdr_evidence=0
  # Native HDR may be published only after the decoder has emitted complete
  # video params and the native surface has attached. A slow first frame is a
  # valid precondition delay, not an HDR fallback; keep this wait configurable
  # but long enough for the observed ~18s attachment path.
  for ((hdr_attempt=1; hdr_attempt<=${VERIFY_HDR_LOG_RETRIES:-12}; hdr_attempt++)); do
    if grep -Eq 'HDR decision: .*output=nativeHdr.*surface=native-hdr|HDR native decision applied: output=nativeHdr' "$ROOT/hilog.txt"; then
      native_hdr_evidence=1
      break
    fi
    # A live-player re-entry starts capturing after the player was already
    # attached, so the Dart decision line may have preceded this verifier.
    # In that narrow mode, accept the same-PID native VO contract only when
    # both the HDR transfer contract and native target mapping are present.
    if [[ "$REUSE_CURRENT_APP" == 1 ]] &&
       grep -Eq 'OHOS color contract .*hdr=1 transfer=(10|12)' "$ROOT/hilog.txt" &&
       grep -Eq 'OHOS target mapping: .*target_trc=(10|12)' "$ROOT/hilog.txt"; then
      native_hdr_evidence=1
      mark_event "reuse-native-hdr-contract-evidence"
      break
    fi
    refresh_hilog_snapshot || true
    sleep "${VERIFY_HDR_LOG_WAIT:-2}"
  done
  if [[ "$native_hdr_evidence" != 1 ]]; then
    echo "HDR precondition failed: current playback did not enter nativeHdr; refusing fullscreen regression" >&2
    echo "artifacts: $ROOT" >&2
    exit 2
  fi
fi

if [[ "$REENTRY_PLAYBACK_ONLY" == 1 ]]; then
  # The enclosing page-exit/re-entry test has already proven the fullscreen
  # input sequence before disposal. Its re-entry phase owns only reopening
  # the source in that same process and proving visible playback progression;
  # it has no raw fullscreen input to bind to a source/output channel.
  assert_playback_progress "reentry-playback-progress" "$ROOT/05-windowed.json" 0 || exit 1
  reentry_pid="$(run_hdc shell pidof "$PACKAGE" | tr -d '\r\n')"
  [[ -n "$reentry_pid" ]] || {
    echo "reentry playback lost target process" >&2
    exit 1
  }
  printf 'application=PASS\nattachment=NOT_RUN\nplayback=PASS\npid=%s\noverall=PASS\n' \
    "$reentry_pid" >"$ROOT/verdict.env"
  mark_event "reentry-playback-only-pass pid=$reentry_pid"
  echo "reentry playback verdict: PASS pid=$reentry_pid"
  exit 0
fi

# A source that is explicitly SDR/Texture is a valid control/fullscreen
# regression target, but it cannot be judged through a native HCPP attachment.
# Conversely, native HDR must never silently downgrade to the Flutter-only
# proof path. Resolve once before any raw fullscreen input and fail closed on
# an absent or ambiguous decision.
resolve_input_channel || {
  mark_event "input-proof-channel-unresolved requested=$INPUT_CHANNEL"
  exit 2
}

# The control bar is transient. Resolve the video and fullscreen bounds from
# the immediately preceding/current UI dumps; never use fixed coordinates.
read -r video_x video_y video_bounds < <(
  python3 "$SCRIPT_DIR/ohos_ui_layout.py" "$WAKE_MODE" "$ROOT/05-windowed.json"
)
echo "click video mode=$WAKE_MODE center=($video_x,$video_y) bounds=$video_bounds"
run_hdc shell uitest uiInput click "$video_x" "$video_y" >/dev/null
sleep "${VERIFY_CONTROL_WAIT:-0.1}"
pull_layout 06-controls.json
capture_display 06-controls
if [[ "$FREEZE_FRAME" == "1" ]]; then
  click_text "$ROOT/06-controls.json" 暂停
  echo "pause video for repeated fullscreen color A/B"
  sleep "${VERIFY_CONTROL_WAIT:-0.1}"
fi
# Do not click using the layout captured before the screenshot: the transient
# control bar can move while capture_display is running. The second dump is
# the authoritative click-time target.
pull_layout 06-controls-click.json
if [[ "$PREPARE_ONLY" == 1 ]]; then
  # Preparation is its own phase: prove that the target player is actually
  # progressing, then wake controls once and capture their current-direction
  # bounds without performing the fullscreen action in this process.
  assert_playback_progress "prepare-playback-progress" "$ROOT/05-windowed.json" 0 || exit 1
  click_layout_point "$CONTROL_WAKE_MODE" "$ROOT/05-windowed.json"
  sleep "${VERIFY_CONTROL_IMMEDIATE_WAIT:-0.25}"
  pull_layout 06-prepared.json
  prepared_layout="$ROOT/06-prepared.json"
  prepared_layout_source=post-wake
  if ! python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
      "$prepared_layout" >/dev/null 2>&1; then
    for candidate in \
      "$ROOT/prepare-playback-progress-after.json" \
      "$ROOT/06-controls-click.json" \
      "$ROOT/06-controls.json"; do
      if [[ -s "$candidate" ]] &&
         python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
           "$candidate" >/dev/null 2>&1; then
        prepared_layout="$candidate"
        prepared_layout_source=last-visible-same-scene
        mark_event "prepare-only-layout-fallback source=$(basename "$candidate")"
        break
      fi
    done
  fi
  if ! python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
      "$prepared_layout" >/dev/null 2>&1; then
    echo "prepared control layout does not expose fullscreen button" >&2
    mark_event "prepare-only-failed reason=fullscreen-button-not-exposed"
    exit 1
  fi
  printf 'pid=%s\norientation=%s\nlayout=%s\nlayout_source=%s\n' \
    "$(run_hdc shell pidof "$PACKAGE" | tr -d '\r\n')" \
    "$(layout_orientation "$prepared_layout")" \
    "$prepared_layout" "$prepared_layout_source" >"$ROOT/prepared-player.txt"
  mark_event "prepare-only-ready pid=$(tr -d '\r\n' < "$ROOT/prepared-player.txt" | sed 's/.*pid=//;s/orientation.*//') layout=$(basename "$prepared_layout")"
  echo "prepare-only ready: $ROOT/prepared-player.txt"
  exit 0
fi
if [[ -n "$PAUSE_BEFORE_FULLSCREEN_FILE" ]]; then
  mark_event "waiting-before-fullscreen file=$PAUSE_BEFORE_FULLSCREEN_FILE"
  while [[ ! -e "$PAUSE_BEFORE_FULLSCREEN_FILE" ]]; do
    sleep 0.1
  done
  mark_event "released-before-fullscreen file=$PAUSE_BEFORE_FULLSCREEN_FILE"
fi
if [[ ("$CYCLES" != 0 || "$TOGGLE_COUNT" != 0) && "${VERIFY_RESET_PLAYBACK_START:-1}" == 1 ]]; then
  reset_playback_to_start "$ROOT/06-controls-click.json" 06-controls || exit 1
  # Seeking can animate the bar and alter its bounds; do not reuse the
  # pre-seek layout for the first fullscreen click.
  if [[ -f "$ROOT/06-controls-after-play.json" ]]; then
    cp "$ROOT/06-controls-after-play.json" "$ROOT/06-controls-click.json"
  else
    cp "$ROOT/06-controls-after-seek.json" "$ROOT/06-controls-click.json"
  fi
  pull_layout 06-controls-click.json
  if [[ "$FREEZE_FRAME" != "1" ]]; then
    # Seeking to 0% discards the previously warm demuxer cache. Establish a
    # real non-buffering frame-progress sample before the first fullscreen
    # transition; otherwise the transition itself is being tested while the
    # source is still refilling, which can masquerade as an output failure.
    assert_playback_progress \
      "06-playback-progress-after-seek" \
      "$ROOT/06-controls-click.json" 1 || exit 1
    pull_layout 06-controls-click.json
  fi
fi
control_attempts="${VERIFY_CONTROL_RETRIES:-8}"
# The control bar may disappear during the retry window. Keep every wake,
# dump, and click attempt in the same short timing budget; callers can still
# lengthen it explicitly for slow devices.
control_wait="${VERIFY_CONTROL_RETRY_WAIT:-0.1}"
control_ready=0
control_needs_wake=0
control_click_layout="$ROOT/06-controls-click.json"
if [[ "${VERIFY_DETERMINISTIC_FULLSCREEN_PREP:-1}" == 1 ]]; then
  # Establish a known hidden-control state before resolving the click target.
  # This avoids the ambiguous case where the accessibility node has opacity=0
  # both while painted and after the Flutter IgnorePointer layer has hidden.
  # The player remains playing during this bounded wait.
  sleep "${VERIFY_CONTROL_HIDDEN_WAIT:-3.5}"
  pull_layout 06-controls-click-hidden-prep.json
  cp "$ROOT/06-controls-click-hidden-prep.json" "$ROOT/06-controls-click.json"
  if python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
      "$ROOT/06-controls-click.json" >/dev/null 2>&1; then
    control_ready=1
    control_parser_mode=fullscreen-button-fresh
    control_needs_wake=1
    mark_event "fullscreen-control-ready deterministic-hidden-state"
  elif python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
      "$ROOT/06-controls.json" >/dev/null 2>&1; then
    # The hidden-state dump may legitimately remove the Flutter control node.
    # Reuse the last layout captured while the control was painted; orientation
    # and the player bounds have not changed, and the following wake/click is
    # deliberately issued as one adjacent input preparation sequence.
    control_ready=1
    control_parser_mode=fullscreen-button-fresh
    control_needs_wake=1
    control_click_layout="$ROOT/06-controls.json"
    mark_event "fullscreen-control-ready deterministic-hidden-state using=06-controls"
  fi
fi
for ((control_attempt=1; control_attempt<=control_attempts; control_attempt++)); do
  (( control_ready == 1 )) && break
  control_parser_mode=fullscreen-button
  if (( control_attempt > 1 )); then
    control_parser_mode=fullscreen-button-fresh
  fi
  if python3 "$SCRIPT_DIR/ohos_ui_layout.py" "$control_parser_mode" \
      "$ROOT/06-controls-click.json" >/dev/null 2>&1; then
    control_ready=1
    mark_event "fullscreen-control-ready prefix=initial attempt=$control_attempt"
    break
  fi
  # When the painted parser cannot see the node but the fresh parser can,
  # opacity metadata is the only positive evidence. Do not click that possibly
  # stale coordinate first: it can create a down-only native sequence. Use
  # the same current-layout target for a wake-and-click retry instead.
  if (( control_attempt == 1 )) &&
     python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
       "$ROOT/06-controls-click.json" >/dev/null 2>&1; then
    control_ready=1
    control_parser_mode=fullscreen-button-fresh
    control_needs_wake=1
    mark_event "fullscreen-control-ready prefix=initial attempt=1 opacity-fallback"
    break
  fi
  mark_event "fullscreen-control-wait prefix=initial attempt=$control_attempt"
  if (( control_attempt < control_attempts )); then
    ensure_fullscreen_controls_visible "$ROOT/06-controls-click.json" "$WAKE_MODE"
    sleep "$control_wait"
    pull_layout "06-controls-click-${control_attempt}.json"
    cp "$ROOT/06-controls-click-${control_attempt}.json" \
      "$ROOT/06-controls-click.json"
  fi
done
if (( control_ready == 0 )); then
  echo "fullscreen control was not exposed at click time; refusing fullscreen tap" >&2
  mark_event "fullscreen-control-failed"
  exit 1
fi
# A force-stop/re-entry can leave the app's logical fullscreen flag set while
# the window has already returned to portrait. Normalize that state through
# the current semantic button before the first transition; never assume a
# process restart cleared page-owned fullscreen state.
windowed_label="$(python3 "$SCRIPT_DIR/ohos_ui_layout.py" \
  fullscreen-label-painted "$control_click_layout" || true)"
if [[ "$windowed_label" == "退出全屏" ]]; then
  mark_event "normalize-windowed-fullscreen-state from=exit-label"
  run_single_fullscreen_input exit "$ROOT/06-controls-click.json" \
    normalize-windowed-exit || exit 1
  sleep "${VERIFY_STABLE_WAIT:-5}"
  pull_layout 06-controls-windowed-normalized.json
  if [[ "$(layout_orientation "$ROOT/06-controls-windowed-normalized.json")" != "$base_orientation" ]]; then
    echo "fullscreen normalization changed windowed orientation unexpectedly" >&2
    exit 1
  fi
  # The semantic button normally times out immediately after the transition.
  # Wake the controls from the freshly captured video bounds before checking
  # the normalized label; do not reuse the pre-transition button bounds.
  if ! read_fullscreen_label "$ROOT/06-controls-windowed-normalized.json" >/dev/null 2>&1; then
    click_layout_point "$WAKE_MODE" "$ROOT/06-controls-windowed-normalized.json"
    sleep "${VERIFY_CONTROL_WAIT:-0.1}"
    pull_layout 06-controls-windowed-normalized-controls.json
    cp "$ROOT/06-controls-windowed-normalized-controls.json" "$ROOT/06-controls-click.json"
  else
    cp "$ROOT/06-controls-windowed-normalized.json" "$ROOT/06-controls-click.json"
  fi
fi
assert_fullscreen_label "$control_click_layout" 全屏 || exit 1
if ! run_single_fullscreen_input enter "$control_click_layout" initial-enter; then
  echo "fullscreen request trial was not observed; stopping without same-process retry" >&2
  exit 1
fi
pull_layout 07-fullscreen-immediate.json
capture_display 07-fullscreen-immediate
sleep "${VERIFY_STABLE_WAIT:-5}"
pull_layout 08-fullscreen-stable.json
assert_orientation "$ROOT/08-fullscreen-stable.json" \
  08-fullscreen-stable "$FULLSCREEN_ORIENTATION"
capture_display 08-fullscreen-stable
if [[ -n "$PAUSE_AFTER_STABLE_FILE" ]]; then
  mark_event "waiting-after-fullscreen-stable file=$PAUSE_AFTER_STABLE_FILE"
  while [[ ! -e "$PAUSE_AFTER_STABLE_FILE" ]]; do
    sleep 0.1
  done
  mark_event "released-after-fullscreen-stable file=$PAUSE_AFTER_STABLE_FILE"
fi
ensure_fullscreen_controls_visible "$ROOT/08-fullscreen-stable.json"
wait_for_fullscreen_label_after_wake \
  "$ROOT/08-fullscreen-stable.json" 08-fullscreen 退出全屏 || exit 1
if [[ "$FREEZE_FRAME" == "1" ]]; then
  mark_event "playback-state context=freeze-frame state=paused position=unknown"
  echo "playback state: paused (freeze-frame; progression gate skipped)"
else
  if ! assert_playback_progress 08-playback-progress "$ROOT/08-fullscreen-stable.json"; then
    # Short sources may reach 100% during the initial fullscreen baseline
    # before the cycle loop starts. Re-arm only that explicit natural-end
    # state; a generic paused/buffering failure must still stop the run.
    recovery_layout="$ROOT/08-playback-progress-after.json"
    recovery_state=""
    recovery_position=""
    if [[ -f "$recovery_layout" ]]; then
      read -r recovery_state recovery_position < <(
        read_playback_state "$recovery_layout"
      )
    fi
    if [[ "$recovery_state" == completed ]]; then
      mark_event "playback-ended-recovery prefix=08-playback-progress position=$recovery_position"
      reset_playback_to_start "$ROOT/08-fullscreen-stable.json" \
        08-playback-progress-restart || exit 1
      recovery_layout="$ROOT/08-playback-progress-restart-after-seek.json"
      if [[ -f "$ROOT/08-playback-progress-restart-after-play.json" ]]; then
        recovery_layout="$ROOT/08-playback-progress-restart-after-play.json"
      fi
      assert_playback_progress 08-playback-progress-restart \
        "$recovery_layout" 1 || exit 1
      # Seeking an ended fullscreen source can recreate the player in the
      # windowed orientation. The restart layout, not the stale pre-end
      # fullscreen dump, is the authoritative state for the cycle loop.
      current_layout="$recovery_layout"
    else
      exit 1
    fi
  fi
fi

# Some orchestrators need a stable readiness barrier, not merely the first
# fullscreen layout dump. Keep this separate from PAUSE_AFTER_STABLE_FILE so
# existing gesture probes can still inspect the immediate stable layout while
# lifecycle probes wait until direction, controls, and playback are all
# authoritative.
if [[ -n "$PAUSE_AFTER_READY_FILE" ]]; then
  mark_event "ready-after-fullscreen file=$PAUSE_AFTER_READY_FILE"
  : >"$PAUSE_AFTER_READY_FILE.ready"
  while [[ ! -e "$PAUSE_AFTER_READY_FILE" ]]; do
    sleep 0.1
  done
  mark_event "released-after-fullscreen-ready file=$PAUSE_AFTER_READY_FILE"
fi

# Legacy transition mode: preserve --toggle-count as one transition per count.
if [[ "$TOGGLE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  current_layout="$ROOT/08-fullscreen-stable.json"
  target_label=全屏
  for ((toggle=1; toggle<=TOGGLE_COUNT; toggle++)); do
    mark_event "toggle-${toggle}-begin"
    if [[ "$FREEZE_FRAME" != "1" ]]; then
      assert_playback_progress "09-toggle-${toggle}-before" "$current_layout"
    fi
    if [[ "$target_label" == 全屏 ]]; then
      expected_orientation="$base_orientation"
    else
      expected_orientation="$FULLSCREEN_ORIENTATION"
    fi
    transition_fullscreen "$current_layout" "09-toggle-${toggle}" \
      "$expected_orientation" "$target_label"
    current_layout="$TRANSITION_LAYOUT"
    if [[ "$target_label" == 全屏 ]]; then
      target_label=退出全屏
    else
      target_label=全屏
    fi
    mark_event "toggle-${toggle}-stable-complete"
  done
fi

# New mode: one cycle is a complete logical fullscreen exit and re-entry. The
# non-fullscreen orientation follows the captured baseline because horizontal
# adaptation legitimately permits a normal landscape player.
if [[ "$CYCLES" =~ ^[1-9][0-9]*$ ]]; then
  current_layout="$ROOT/08-fullscreen-stable.json"
  for ((cycle=1; cycle<=CYCLES; cycle++)); do
    mark_event "cycle-${cycle}-begin"
    if [[ "$FREEZE_FRAME" != "1" ]]; then
      # A short source can naturally reach its end during a long cycle run.
      # Re-arm only an explicit end-of-source sample. An arbitrary paused
      # position is a playback failure and must not be repaired by the test.
      preflight_layout="$ROOT/09-cycle-${cycle}-preflight.json"
      pull_layout "$(basename "$preflight_layout")"
      # The transition stable dump may become stale after a later orientation
      # or surface update. Make the fresh preflight dump authoritative before
      # any state read or wake click in this cycle.
      current_layout="$preflight_layout"
      click_layout_point "$WAKE_MODE" "$current_layout"
      sleep "${VERIFY_CONTROL_WAIT:-0.1}"
      pull_layout "$(basename "$preflight_layout")"
      read -r preflight_state preflight_position < <(read_playback_state "$preflight_layout")
      mark_event "cycle-${cycle}-preflight state=$preflight_state position=${preflight_position:-unknown}"
      restarted_cycle=0
      if [[ "$preflight_state" == completed ]]; then
        mark_event "cycle-${cycle}-restart-ended-source"
        reset_playback_to_start "$preflight_layout" "09-cycle-${cycle}-restart" || exit 1
        restarted_cycle=1
        current_layout="$ROOT/09-cycle-${cycle}-restart-after-seek.json"
        if [[ -f "$ROOT/09-cycle-${cycle}-restart-after-play.json" ]]; then
          current_layout="$ROOT/09-cycle-${cycle}-restart-after-play.json"
        fi
      fi
      if ! assert_playback_progress "09-cycle-${cycle}-before" \
        "$current_layout" "$restarted_cycle"; then
        # The source may reach EOF during the progress sample itself, after
        # the preflight check but before the next fullscreen transition. Only
        # recover an explicit natural end; a paused sample at any other
        # position remains a hard failure.
        recovery_layout="$ROOT/09-cycle-${cycle}-before-after.json"
        recovery_state=""
        recovery_position=""
        if [[ -f "$recovery_layout" ]]; then
          read -r recovery_state recovery_position < <(
            read_playback_state "$recovery_layout"
          )
        fi
        if [[ "$recovery_state" == completed ]]; then
          mark_event "cycle-${cycle}-restart-ended-source-after-sample position=$recovery_position"
          reset_playback_to_start "$recovery_layout" \
            "09-cycle-${cycle}-restart-after-sample" || exit 1
          restarted_cycle=1
          current_layout="$ROOT/09-cycle-${cycle}-restart-after-sample-after-seek.json"
          if [[ -f "$ROOT/09-cycle-${cycle}-restart-after-sample-after-play.json" ]]; then
            current_layout="$ROOT/09-cycle-${cycle}-restart-after-sample-after-play.json"
          fi
          assert_playback_progress "09-cycle-${cycle}-before-restart" \
            "$current_layout" 1 || exit 1
        else
          exit 1
        fi
      fi
    fi
    cycle_orientation="$(layout_orientation "$current_layout")"
    if [[ "$VERTICAL_VIDEO" == 1 ]]; then
      # Portrait windowed and portrait fullscreen have the same display
      # orientation. The initial baseline is known to be fullscreen, so use
      # the logical sequence explicitly: exit, then enter again.
      transition_fullscreen "$current_layout" "09-cycle-${cycle}-exit" \
        "$base_orientation" 全屏
      exit_layout="$TRANSITION_LAYOUT"
      transition_fullscreen "$exit_layout" "09-cycle-${cycle}-enter" \
        "$FULLSCREEN_ORIENTATION" 退出全屏
    elif [[ "$cycle_orientation" == landscape ]]; then
      transition_fullscreen "$current_layout" "09-cycle-${cycle}-exit" \
        "$base_orientation" 全屏
      exit_layout="$TRANSITION_LAYOUT"
      transition_fullscreen "$exit_layout" "09-cycle-${cycle}-enter" \
        "$FULLSCREEN_ORIENTATION" 退出全屏
    else
      transition_fullscreen "$current_layout" "09-cycle-${cycle}-enter" \
        "$FULLSCREEN_ORIENTATION" 退出全屏
      exit_layout="$TRANSITION_LAYOUT"
      transition_fullscreen "$exit_layout" "09-cycle-${cycle}-exit" \
        "$base_orientation" 全屏
    fi
    current_layout="$TRANSITION_LAYOUT"
    mark_event "cycle-${cycle}-complete"
  done
fi
# Keep the same root stream alive after the final raw fullscreen action. This
# is deliberately a drain, not a new action or a separate per-trial capture:
# P7 showed Flutter markers can arrive over two minutes after native input.
FINAL_LOG_DRAIN_WAIT="${VERIFY_FINAL_LOG_DRAIN_WAIT:-150}"
[[ "$FINAL_LOG_DRAIN_WAIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "invalid VERIFY_FINAL_LOG_DRAIN_WAIT: $FINAL_LOG_DRAIN_WAIT" >&2
  exit 2
}
mark_event "hilog-final-drain-start seconds=$FINAL_LOG_DRAIN_WAIT"
sleep "$FINAL_LOG_DRAIN_WAIT"
mark_event "hilog-final-drain-complete"
stop_hilog_capture
# Supplemental only: append the same device ring buffer after streaming has
# ended. Verdicts were already bound to continuous-stream offsets above.
refresh_hilog_snapshot || true

echo "artifacts: $ROOT"
if grep -Eq 'output=nativeHdr.*surface=native-hdr|HDR dataspace applied: (pq|hlg)|reapplied HDR after (native surface attach|surface resize|video params resize): result=0' "$ROOT/hilog.txt"; then
  echo "HDR decision evidence: PASS"
elif grep -Eq 'output=sdr.*surface=texture|output=toneMappedSdr.*surface=texture' "$ROOT/hilog.txt"; then
  echo "Texture/SDR evidence: PASS"
else
  echo "output decision evidence: INCONCLUSIVE" >&2
  exit 1
fi
if [[ "$FREEZE_FRAME" == "1" ]]; then
  echo "playback state: paused (freeze-frame; progression not claimed)"
elif grep -q 'playback-progress-observed' "$ROOT/events.tsv"; then
  visual_samples="$(grep -Ec 'evidence=(video-crop-frame-only|playing-before-plus-video-frame|slider-plus-video-frame)' "$ROOT/events.tsv" || true)"
  semantic_samples="$(grep -Ec 'evidence=(semantic-position|playing-state-plus-frame|playing-before-plus-video-frame)' "$ROOT/events.tsv" || true)"
  if (( visual_samples > 0 )); then
    echo "frame progression: OBSERVED (video crop evidence; semantic state unavailable in ${visual_samples} sample(s), semantic samples=${semantic_samples})"
  else
    echo "frame progression: OBSERVED (semantic samples=${semantic_samples})"
  fi
else
  echo "playback state: unknown (no accepted progression sample)" >&2
  exit 1
fi
echo "color verdict: INCONCLUSIVE (requires same-source/same-frame display comparison)" >&2
