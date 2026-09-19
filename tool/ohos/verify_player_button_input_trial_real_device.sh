#!/usr/bin/env bash
set -euo pipefail

# Execute exactly one fullscreen-button input trial on an already-playing
# player page. It does not navigate, take screenshots, or retry.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HDC=${HDC_BIN:-/Users/wuweiwei1/bin/hdc}
TARGET=${HDC_TARGET:-2PM0223A18006914}
OUT=${VERIFY_BUTTON_TRIAL_OUT:-/tmp/piliplusx-ohos-button-trial-$(date +%Y%m%d-%H%M%S)}
BUTTON_LAYOUT=
WAKE_LAYOUT=
MODE=${VERIFY_BUTTON_TRIAL_MODE:-continuous}
EXPECTED=${VERIFY_BUTTON_TRIAL_EXPECTED:-enter}
WAKE=1
# Flutter trace delivery can lag the native HCPP/media channel path by more
# than one log-flush interval. Retain a full causal window before judging the
# trial; callers can still override this for focused diagnostics.
SETTLE=${VERIFY_BUTTON_TRIAL_SETTLE_WAIT:-360}
WAKE_WAIT=${VERIFY_BUTTON_TRIAL_WAKE_WAIT:-0.25}
CAPTURE_RETRIES=${VERIFY_BUTTON_TRIAL_CAPTURE_RETRIES:-5}
CAPTURE_WAIT=${VERIFY_BUTTON_TRIAL_CAPTURE_WAIT:-0.2}
LOG_PID=
SHARED_HILOG=
CONSUMED_OFFSET_FILE=
ACTION_PID=
ACTION_VIEW_ID=
ACTION_EPOCH=
TRIAL_ID=
INPUT_CHANNEL=${VERIFY_BUTTON_TRIAL_INPUT_CHANNEL:-hcpp}

usage() {
  cat <<'USAGE'
usage: verify_player_button_input_trial_real_device.sh --button-layout FILE [options]

Required:
  --button-layout FILE   preparation/reference layout; action uses a fresh dump

Options:
  --wake-layout FILE     layout used to derive the video-center wake point
                         (defaults to --button-layout)
  --out DIR              evidence directory
  --mode post|continuous `post` is accepted for compatibility; every trial
                         uses a continuous Hilog stream from before raw input
  --expected enter|exit  expected fullscreen direction (default: enter)
  --no-wake              fail if the fresh layout has no visible button; do not wake
  --settle SECONDS       max wait for the four ordered Flutter markers
                         (default: 360; delayed markers are not inferred)
  --wake-wait SECONDS    delay between wake and button click (default: 0.25)
  --shared-hilog FILE    append-only root Hilog owned by a parent verifier;
                         this script neither clears nor stops it
  --consumed-offset FILE monotonic byte-offset ledger for shared Hilog marker
                         consumption; prevents one marker set proving two taps
  --action-pid PID       required with --shared-hilog; process bound to action
  --view-id ID           required with --shared-hilog; Flutter platform view
  --epoch N              required with --shared-hilog; HCPP attachment epoch
  --input-channel MODE   hcpp (native surface) or flutter (Texture surface)
  --trial-id ID          stable action identifier for the evidence record
  -h, --help             show this help

Prerequisite: the signed diagnostic HAP is installed, the app is foreground,
and the requested video is playing. The supplied layout is retained as a
preparation reference only; the button action always resolves a fresh current
layout. Direct (non-shared) use must also provide --view-id and --epoch; the
script fails before raw input when it cannot bind Flutter markers to a view.
The script performs one action trial only and never retries the action.
USAGE
}

while (($#)); do
  case "$1" in
    --button-layout) BUTTON_LAYOUT=${2:?missing value}; shift 2 ;;
    --wake-layout) WAKE_LAYOUT=${2:?missing value}; shift 2 ;;
    --out) OUT=${2:?missing value}; shift 2 ;;
    --mode) MODE=${2:?missing value}; shift 2 ;;
    --expected) EXPECTED=${2:?missing value}; shift 2 ;;
    --no-wake) WAKE=0; shift ;;
    --settle) SETTLE=${2:?missing value}; shift 2 ;;
    --wake-wait) WAKE_WAIT=${2:?missing value}; shift 2 ;;
    --shared-hilog) SHARED_HILOG=${2:?missing value}; shift 2 ;;
    --consumed-offset) CONSUMED_OFFSET_FILE=${2:?missing value}; shift 2 ;;
    --action-pid) ACTION_PID=${2:?missing value}; shift 2 ;;
    --view-id) ACTION_VIEW_ID=${2:?missing value}; shift 2 ;;
    --epoch) ACTION_EPOCH=${2:?missing value}; shift 2 ;;
    --input-channel) INPUT_CHANNEL=${2:?missing value}; shift 2 ;;
    --trial-id) TRIAL_ID=${2:?missing value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -x "$HDC" ]] || { echo "HDC not executable: $HDC" >&2; exit 1; }
[[ -s "$BUTTON_LAYOUT" ]] || { echo "button layout is required: $BUTTON_LAYOUT" >&2; exit 2; }
if [[ -n "$WAKE_LAYOUT" ]]; then
  [[ -s "$WAKE_LAYOUT" ]] || { echo "wake layout not found: $WAKE_LAYOUT" >&2; exit 2; }
else
  WAKE_LAYOUT=$BUTTON_LAYOUT
fi
[[ "$MODE" == post || "$MODE" == continuous ]] || { echo "invalid --mode: $MODE" >&2; exit 2; }
# `post` is accepted only for old invocations. It no longer means a post-action
# snapshot: both values use the continuous capture below, because snapshot
# order cannot attribute delayed Flutter markers to a raw input action.
[[ "$EXPECTED" == enter || "$EXPECTED" == exit ]] || { echo "invalid --expected: $EXPECTED" >&2; exit 2; }
[[ "$INPUT_CHANNEL" == hcpp || "$INPUT_CHANNEL" == flutter ]] || { echo "invalid --input-channel: $INPUT_CHANNEL" >&2; exit 2; }
[[ "$SETTLE" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid --settle" >&2; exit 2; }
[[ "$WAKE_WAIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid --wake-wait" >&2; exit 2; }
if [[ -n "$SHARED_HILOG" ]]; then
  [[ -f "$SHARED_HILOG" ]] || { echo "shared Hilog does not exist: $SHARED_HILOG" >&2; exit 2; }
  [[ -n "$CONSUMED_OFFSET_FILE" && -n "$ACTION_PID" && -n "$ACTION_VIEW_ID" && -n "$ACTION_EPOCH" && -n "$TRIAL_ID" ]] || {
    echo "--shared-hilog requires --consumed-offset, --action-pid, --view-id, --epoch and --trial-id" >&2; exit 2;
  }
  [[ "$ACTION_PID" =~ ^[0-9]+$ && "$ACTION_VIEW_ID" =~ ^[0-9]+$ && "$ACTION_EPOCH" =~ ^[0-9]+$ ]] || {
    echo "invalid shared action identity" >&2; exit 2;
  }
fi

if ! "$HDC" list targets -v 2>/dev/null | awk -v target="$TARGET" '
  $1 == target && ($2 == "Online" || $3 == "Online" || $4 == "Online" ||
                   $2 == "Connected" || $3 == "Connected" || $4 == "Connected") { found=1 }
  END { exit found ? 0 : 1 }
'; then
  echo "HDC target is not online: $TARGET" >&2
  exit 1
fi

mkdir -p "$OUT"
: >"$OUT/events.tsv"
if [[ -z "$TRIAL_ID" ]]; then
  TRIAL_ID="$(basename "$OUT")"
fi

mark() {
  printf '%s mono=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(python3 -c 'import time; print(f"{time.monotonic():.6f}")')" \
    "$*" >>"$OUT/events.tsv"
}

cleanup() {
  if [[ -n "$LOG_PID" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
  fi
  if [[ -z "$SHARED_HILOG" ]]; then
    # Supplemental only: the verdict above came from the live ordered stream.
    # Preserve a same-ring snapshot after stopping for delayed diagnostics.
    if [[ -n "${ROOT_HILOG:-}" ]]; then
      "$HDC" -t "$TARGET" shell hilog -x >>"$ROOT_HILOG" 2>&1 || true
    fi
    "$HDC" -t "$TARGET" shell power-shell timeout -r >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_hdc() { "$HDC" -t "$TARGET" "$@"; }

capture_layout() {
  local name="$1" remote=/data/local/tmp/piliplusx-button-trial-layout.json
  local attempt
  for ((attempt=1; attempt<=CAPTURE_RETRIES; attempt++)); do
    if run_hdc shell uitest dumpLayout -p "$remote" >/dev/null &&
       run_hdc file recv "$remote" "$OUT/$name" >/dev/null &&
       [[ -s "$OUT/$name" ]]; then
      return 0
    fi
    mark "layout-retry name=$name attempt=$attempt"
    sleep "$CAPTURE_WAIT"
  done
  echo "failed to capture current layout: $name" >&2
  return 1
}

assert_target_layout() {
  local layout="$1"
  python3 - "$layout" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
expected = "com.example.piliplusx"
bundles = []
def walk(node):
    if not isinstance(node, dict):
        return
    attrs = node.get("attributes", {})
    bundle = attrs.get("bundleName", "")
    if bundle:
        bundles.append(bundle)
    for child in node.get("children", []):
        walk(child)
walk(data)
if expected not in bundles:
    raise SystemExit("current layout is not the target application: " +
                     (bundles[0] if bundles else "<unknown>"))
PY
}

resolve_button() {
  local layout="$1"
  # A fresh accessibility node with opacity=0 can belong to a hidden Flutter
  # control layer. It is useful only to decide that one wake is needed; it is
  # never a valid direct raw-input target.
  python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button "$layout"
}

resolve_button_after_wake() {
  local layout="$1"
  # The wake and this fresh dump form one bounded preparation sequence. OHOS
  # still reports opacity=0 for a control that has just been made visible, so
  # the final button-hit evidence remains the ordered Flutter marker chain.
  python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh "$layout"
}

resolve_wake() {
  local layout="$1"
  python3 "$SCRIPT_DIR/ohos_ui_layout.py" video-center "$layout"
}

file_offset() {
  [[ -f "$1" ]] && wc -c <"$1" | tr -d '[:space:]' || echo 0
}

write_action_record() {
  local status="$1" input_channel="$2" hcpp_seq="${3:-}" hcpp_epoch="${4:-}" marker_end="${5:-}"
  python3 - "$OUT/action-record.json" "$TRIAL_ID" "$EXPECTED" "$ACTION_PID" \
    "$ACTION_VIEW_ID" "$ACTION_EPOCH" "$button_x,$button_y" "$button_bounds" \
    "$ROOT_HILOG" "$ACTION_OFFSET" "$input_channel" "$hcpp_seq" "$hcpp_epoch" "$marker_end" "$status" <<'PY'
import json, sys
(path, trial_id, expected, pid, view_id, epoch, physical, logical, hilog,
 offset, input_channel, hcpp_seq, hcpp_epoch, marker_end, status) = sys.argv[1:]
payload = {
    "trial_id": trial_id, "expected": expected, "pid": pid,
    "view_id": view_id, "epoch": epoch,
    "physical_input": physical, "logical_button_bounds": logical,
    "root_hilog": hilog, "root_byte_offset_before_raw_input": int(offset),
    "input_channel": input_channel,
    "hcpp_sequence": None if hcpp_seq in ("", "none") else hcpp_seq,
    "hcpp_epoch": None if hcpp_epoch in ("", "none") else hcpp_epoch,
    "consumed_marker_end_offset": int(marker_end) if marker_end else None,
    "binding": {
        "pid": "Hilog line PID plus action-time pidof" if pid else "missing",
        "flutter_view": "PlayerTouchTrace viewId exact match",
        "hcpp_epoch": "paired HCPP down/up exact epoch match" if input_channel == "hcpp" else "not exposed by Texture",
    },
    "status": status,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
PY
}

# Acceptance is deliberately limited to the four Dart/Flutter markers. HCPP
# records bind the raw input sequence to the evidence record, not to success.
observe_four_markers() {
  python3 "$SCRIPT_DIR/verify_player_button_markers.py" \
    --hilog "$ROOT_HILOG" --offset "$ACTION_OFFSET" --expected "$EXPECTED" \
    --pid "$ACTION_PID" --view-id "$ACTION_VIEW_ID" --epoch "$ACTION_EPOCH" \
    --consumed-before "$CONSUMED_BEFORE" --input-channel "$INPUT_CHANNEL"
}

capture_layout current-before-action.json
assert_target_layout "$OUT/current-before-action.json"
cp "$OUT/current-before-action.json" "$OUT/current-before-action-reference.json"
if ! cmp -s "$OUT/current-before-action.json" "$BUTTON_LAYOUT"; then
  mark "reference-layout-not-byte-identical reference=$(basename "$BUTTON_LAYOUT") current=current-before-action.json"
fi

button_available=0
if read -r button_x button_y button_bounds < <(resolve_button "$OUT/current-before-action.json"); then
  button_available=1
fi

if (( button_available == 0 )); then
  if (( WAKE == 0 )); then
    echo "fresh current layout has no fullscreen button and --no-wake was requested" >&2
    mark "trial-precondition-failed reason=fullscreen-button-not-visible"
    exit 1
  fi
  if python3 "$SCRIPT_DIR/ohos_ui_layout.py" fullscreen-button-fresh \
      "$OUT/current-before-action.json" >/dev/null 2>&1; then
    mark "trial-button-opacity-unverified-requires-wake"
  else
    mark "trial-button-not-exposed-requires-wake"
  fi
  read -r wake_x wake_y wake_bounds < <(resolve_wake "$OUT/current-before-action.json")
  echo "fresh layout has no button; wake=($wake_x,$wake_y) bounds=$wake_bounds"
  mark "trial-wake-start wake=$wake_x,$wake_y bounds=$wake_bounds"
else
  echo "fresh button=($button_x,$button_y) bounds=$button_bounds"
  mark "trial-button-current button=$button_x,$button_y bounds=$button_bounds"
fi
echo "mode=$MODE expected=$EXPECTED wake=$WAKE"
mark "trial-prepared mode=$MODE expected=$EXPECTED wake=$WAKE current-layout=current-before-action.json"

run_hdc shell power-shell wakeup >/dev/null 2>&1 || true
run_hdc shell power-shell timeout -o 3600000 >/dev/null 2>&1 || true
if [[ -n "$SHARED_HILOG" ]]; then
  ROOT_HILOG="$SHARED_HILOG"
  # The parent starts this before its first raw action. Do not clear, rotate,
  # or stop it: late markers must remain in one ordered evidence stream.
  [[ -s "$CONSUMED_OFFSET_FILE" ]] && CONSUMED_BEFORE="$(tr -d '[:space:]' <"$CONSUMED_OFFSET_FILE")" || CONSUMED_BEFORE=0
else
  ROOT_HILOG="$OUT/hilog.txt"
  CONSUMED_OFFSET_FILE="$OUT/consumed-marker-offset"
  CONSUMED_BEFORE=0
  : >"$ROOT_HILOG"
  # Do not use a post-action hilog snapshot as the primary evidence source.
  # It loses timestamp/order attribution for delayed Dart records.
  capture_seconds="$(python3 - "$SETTLE" <<'PY'
import math, sys
print(max(180, int(math.ceil(float(sys.argv[1]) + 30))))
PY
)"
  timeout "$capture_seconds" "$HDC" -t "$TARGET" shell hilog >>"$ROOT_HILOG" 2>&1 &
  LOG_PID=$!
fi
mark "observation-start mode=continuous root-hilog=$ROOT_HILOG consumed-before=$CONSUMED_BEFORE"
mark "trial-input-start"
if (( button_available == 0 )); then
  run_hdc shell uitest uiInput click "$wake_x" "$wake_y" >"$OUT/wake-command.txt" 2>&1
  mark "trial-wake-done"
  sleep "$WAKE_WAIT"
  capture_layout current-after-wake.json
  assert_target_layout "$OUT/current-after-wake.json"
  read -r button_x button_y button_bounds < <(resolve_button_after_wake "$OUT/current-after-wake.json") || {
    echo "post-wake layout has no current fullscreen button" >&2
    mark "trial-precondition-failed reason=fullscreen-button-not-visible-after-wake"
    exit 1
  }
  mark "trial-button-after-wake button=$button_x,$button_y bounds=$button_bounds"
fi
  # `uitest uiInput click` may invoke Semantics directly. Inject one raw
  # pointer lifecycle, record the root byte offset immediately before Down,
  # and never retry this action.
  ACTION_OFFSET="$(file_offset "$ROOT_HILOG")"
  if [[ -z "$ACTION_PID" ]]; then
    ACTION_PID="$(run_hdc shell pidof com.example.piliplusx 2>/dev/null | tr -d '\r[:space:]')"
  fi
  [[ "$ACTION_PID" =~ ^[0-9]+$ ]] || {
    mark "trial-precondition-failed reason=target-pid-missing"
    echo "target process identity was unavailable before raw input" >&2
    exit 1
  }
  : "${ACTION_VIEW_ID:=unknown}" "${ACTION_EPOCH:=unknown}"
  [[ "$ACTION_VIEW_ID" =~ ^[0-9]+$ && "$ACTION_EPOCH" =~ ^[0-9]+$ ]] || {
    mark "trial-precondition-failed reason=flutter-identity-missing view-id=$ACTION_VIEW_ID epoch=$ACTION_EPOCH"
    echo "Flutter viewId/epoch are required to bind fullscreen markers before raw input" >&2
    exit 1
  }
  mark "trial-action-record trial-id=$TRIAL_ID expected=$EXPECTED pid=$ACTION_PID view-id=$ACTION_VIEW_ID epoch=$ACTION_EPOCH physical=$button_x,$button_y logical=$button_bounds root-byte-offset=$ACTION_OFFSET"
  # Persist the immutable pre-input identity before Down. A later timeout can
  # leave HCPP sequence null, but never erases which raw action was attempted.
  write_action_record PENDING "$INPUT_CHANNEL"
  run_hdc shell uinput -T -d "$button_x" "$button_y" >"$OUT/button-command.txt" 2>&1
  sleep "${VERIFY_BUTTON_TRIAL_TOUCH_DOWN_WAIT:-0.08}"
  run_hdc shell uinput -T -u "$button_x" "$button_y" >>"$OUT/button-command.txt" 2>&1
mark "trial-input-done"
deadline="$(python3 - "$SETTLE" <<'PY'
import time, sys
print(time.monotonic() + float(sys.argv[1]))
PY
)"
observed=""
while :; do
  if observed="$(observe_four_markers 2>/dev/null)"; then
    IFS=$'\t' read -r hcpp_seq hcpp_epoch marker_end <<<"$observed"
    printf '%s\n' "$marker_end" >"$CONSUMED_OFFSET_FILE"
    write_action_record PASS "$INPUT_CHANNEL" "$hcpp_seq" "$hcpp_epoch" "$marker_end"
    mark "trial-four-markers-observed trial-id=$TRIAL_ID input-channel=$INPUT_CHANNEL hcpp-seq=${hcpp_seq:-none} hcpp-epoch=${hcpp_epoch:-none} consumed-end=$marker_end"
    mark "trial-verdict PASS"
    echo "button trial: PASS (ordered Flutter pointer-down/up/callback/FullscreenTrace)"
    break
  fi
  if ! python3 - "$deadline" <<'PY'
import sys, time
raise SystemExit(0 if time.monotonic() < float(sys.argv[1]) else 1)
PY
  then
    write_action_record INCONCLUSIVE "$INPUT_CHANNEL"
    mark "trial-verdict INCONCLUSIVE reason=four-markers-timeout wait=$SETTLE"
    echo "button trial: INCONCLUSIVE (four ordered Flutter markers absent after ${SETTLE}s)" >&2
    # A snapshot may be appended only after the continuous observation ended;
    # it is supplemental and cannot make this timed-out trial pass.
    if [[ -z "$SHARED_HILOG" ]]; then run_hdc shell hilog -x >>"$ROOT_HILOG" 2>&1 || true; fi
    exit 1
  fi
  sleep 0.25
done
mark "observation-drained"
echo "evidence=$OUT"
