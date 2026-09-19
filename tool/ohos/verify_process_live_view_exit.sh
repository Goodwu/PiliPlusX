#!/usr/bin/env bash
set -euo pipefail

# Process-live lifecycle probe. This deliberately uses a real Back input to
# leave the current player/page without aa force-stop. It is for HCPP Cancel
# and attachment-generation evidence, not for the playing fullscreen gray
# regression (that regression requires continuous playback fullscreen cycles).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${HDC_TARGET:-2PM0223A18006914}"
HDC="${HDC_BIN:-$HOME/.local/harmony-tools/bin/hdc}"
PACKAGE="com.example.piliplusx"
OUT="${VERIFY_OUT_DIR:-/tmp/piliplusx-process-live-exit-$(date +%Y%m%d-%H%M%S)}"
TIMEOUT_BIN="${VERIFY_HDC_TIMEOUT_BIN:-$(command -v gtimeout || command -v timeout || true)}"
COMMAND_TIMEOUT="${VERIFY_HDC_COMMAND_TIMEOUT:-60}"
SETTLE="${VERIFY_PROCESS_LIVE_SETTLE:-3}"
LOG_FLUSH_WAIT="${VERIFY_PROCESS_LIVE_LOG_FLUSH_WAIT:-40}"
EVIDENCE_RETRIES="${VERIFY_PROCESS_LIVE_EVIDENCE_RETRIES:-6}"
EVIDENCE_RETRY_WAIT="${VERIFY_PROCESS_LIVE_EVIDENCE_RETRY_WAIT:-5}"
BACK_COUNT="${VERIFY_PROCESS_LIVE_BACK_COUNT:-2}"
HOLD_SWIPE="${VERIFY_PROCESS_LIVE_HOLD_SWIPE:-1}"
HOLD_GESTURE="${VERIFY_PROCESS_LIVE_HOLD_GESTURE:-longClick}"
LIFECYCLE="${VERIFY_PROCESS_LIVE_LIFECYCLE:-page-exit}"
EXTERNAL_HOOK="${VERIFY_PROCESS_LIVE_EXTERNAL_HOOK:-0}"

while (($#)); do
  case "$1" in
    --out) OUT="${2:?missing output directory}"; shift 2 ;;
    --back-count) BACK_COUNT="${2:?missing back count}"; shift 2 ;;
    -h|--help)
      echo "usage: verify_process_live_view_exit.sh [--out DIR]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -x "$HDC" ]] || { echo "HDC not executable: $HDC" >&2; exit 1; }
if ! "$HDC" list targets -v 2>/dev/null | awk -v target="$TARGET" '
  $1 == target && ($2 == "Online" || $3 == "Online" || $4 == "Online" ||
                   $2 == "Connected" || $3 == "Connected" || $4 == "Connected") { found=1 }
  END { exit found ? 0 : 1 }
'; then
  echo "HDC target is not connected: $TARGET (set HDC_TARGET explicitly for another device)" >&2
  exit 1
fi
[[ "$BACK_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "invalid back count: $BACK_COUNT" >&2; exit 2; }
[[ "$HOLD_SWIPE" == 0 || "$HOLD_SWIPE" == 1 ]] || { echo "invalid hold swipe: $HOLD_SWIPE" >&2; exit 2; }
[[ "$HOLD_GESTURE" == longClick || "$HOLD_GESTURE" == drag ]] || {
  echo "invalid hold gesture: $HOLD_GESTURE" >&2; exit 2;
}
[[ "$LIFECYCLE" == page-exit || "$LIFECYCLE" == background ]] || {
  echo "invalid lifecycle: $LIFECYCLE" >&2; exit 2;
}
[[ "$EXTERNAL_HOOK" == 0 || "$EXTERNAL_HOOK" == 1 ]] || {
  echo "invalid external hook: $EXTERNAL_HOOK" >&2; exit 2;
}
mkdir -p "$OUT"

write_verdict() {
  local application="$1" attachment="$2" playback="$3" overall="$4"
  {
    printf 'application=%s\n' "$application"
    printf 'attachment=%s\n' "$attachment"
    printf 'playback=%s\n' "$playback"
    printf 'overall=%s\n' "$overall"
  } >"$OUT/verdict.env"
}

run_hdc() {
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" --signal=TERM --kill-after=2 "$COMMAND_TIMEOUT" \
      "$HDC" -t "$TARGET" "$@"
  else
    "$HDC" -t "$TARGET" "$@"
  fi
}

run_hdc shell pidof "$PACKAGE" >"$OUT/pid-before.txt"
run_hdc shell aa dump -a >"$OUT/ability-before.txt" || true
run_hdc shell uitest dumpLayout -p /data/local/tmp/piliplusx-process-live-before.json \
  >"$OUT/layout-before-command.txt" 2>&1 || true
run_hdc file recv /data/local/tmp/piliplusx-process-live-before.json \
  "$OUT/layout-before.json" >/dev/null 2>&1 || true
if [[ ! -s "$OUT/layout-before.json" ]]; then
  echo "player layout was not captured; refusing to treat this as a view-exit probe" >&2
  exit 1
fi
run_hdc shell hilog -r >/dev/null 2>&1 || true
run_hdc shell hilog >"$OUT/hilog.txt" 2>&1 &
HILOG_PID=$!
cleanup() {
  kill "$HILOG_PID" 2>/dev/null || true
  wait "$HILOG_PID" 2>/dev/null || true
}
trap cleanup EXIT

SWIPE_PID=""
if [[ "$HOLD_SWIPE" == 1 ]]; then
  read -r sx sy _ < <(python3 "$SCRIPT_DIR/ohos_ui_layout.py" video-wake "$OUT/layout-before.json")
  ex=$((sx + 360))
  ey=$((sy + 80))
  printf 'held-gesture=%s start=(%s,%s) end=(%s,%s) velocity=%s\n' \
    "$HOLD_GESTURE" "$sx" "$sy" "$ex" "$ey" "${VERIFY_PROCESS_LIVE_SWIPE_VELOCITY:-200}" \
    >"$OUT/held-swipe.txt"
  if [[ "$HOLD_GESTURE" == longClick ]]; then
    gesture_cmd="uitest uiInput longClick $sx $sy & gesture_pid=\$!; sleep ${VERIFY_PROCESS_LIVE_PRE_BACK_DELAY:-0.6};"
  else
    gesture_cmd="uitest uiInput drag $sx $sy $ex $ey ${VERIFY_PROCESS_LIVE_SWIPE_VELOCITY:-200} & gesture_pid=\$!; sleep ${VERIFY_PROCESS_LIVE_PRE_BACK_DELAY:-0.6};"
  fi
  if [[ "$EXTERNAL_HOOK" == 1 ]]; then
    # The app's explicit one-shot test hook owns the lifecycle transition.
    # Keep the pointer-producing gesture alive and do not inject a competing
    # Back or Ability transition from this script.
    gesture_cmd+="wait \$gesture_pid"
  elif [[ "$LIFECYCLE" == background ]]; then
    # aa starts another ability through the system lifecycle path, avoiding
    # the uiInput service queue. Bring the app back after the hide interval.
    gesture_cmd+="aa start -a com.huawei.hmos.settings.MainAbility -b com.huawei.hmos.settings; sleep ${VERIFY_PROCESS_LIVE_BACKGROUND_GAP:-1}; aa start -a EntryAbility -b $PACKAGE; wait \$gesture_pid"
  else
    gesture_cmd+="uitest uiInput keyEvent Back; sleep ${VERIFY_PROCESS_LIVE_BACK_GAP:-0.2}; uitest uiInput keyEvent Back; wait \$gesture_pid"
  fi
  run_hdc shell sh -c "$gesture_cmd" >"$OUT/held-swipe-command.txt" 2>&1 &
  SWIPE_PID=$!
fi

# Back is injected through the scripted HDC UI path, never by hand-picked
# screen coordinates. Video players commonly consume the first Back to leave
# fullscreen and the second to pop the video page, so both are recorded.
if [[ -z "$SWIPE_PID" ]]; then
  for ((back=1; back<=BACK_COUNT; back++)); do
    run_hdc shell uitest uiInput keyEvent Back >>"$OUT/back-input.txt"
    sleep "${VERIFY_PROCESS_LIVE_BACK_GAP:-0.5}"
  done
fi
if [[ -n "$SWIPE_PID" ]]; then
  wait "$SWIPE_PID" 2>/dev/null || true
fi
sleep "$SETTLE"
# Flutter's OHOS log forwarding can lag behind the native HCPP events by
# several seconds. Let the live capture flush before evaluating the gate.
sleep "$LOG_FLUSH_WAIT"
# Take the authoritative post-flush snapshot before evaluating the gate. The
# background `hilog` pipe can still lag at the file level even after its
# timestamps have reached the device buffer.
run_hdc shell hilog -x >"$OUT/hilog-final.txt" 2>&1 || true
run_hdc shell pidof "$PACKAGE" >"$OUT/pid-after.txt" || true
run_hdc shell aa dump -a >"$OUT/ability-after.txt" || true
run_hdc shell uitest dumpLayout -p /data/local/tmp/piliplusx-process-live-after.json \
  >"$OUT/layout-after-command.txt" 2>&1 || true
run_hdc file recv /data/local/tmp/piliplusx-process-live-after.json \
  "$OUT/layout-after.json" >/dev/null 2>&1 || true

if [[ -s "$OUT/pid-before.txt" && -s "$OUT/pid-after.txt" ]] &&
   cmp -s "$OUT/pid-before.txt" "$OUT/pid-after.txt"; then
  echo "process remained alive: pid=$(tr -d '\r\n' < "$OUT/pid-after.txt")"
else
  echo "process identity changed or could not be observed" >&2
fi

grep -E 'hcpp_input|HCPP_POINTER|PlayerTouchTrace|Cancel|cancel|attachment' \
  "$OUT/hilog.txt" "$OUT/hilog-final.txt" >"$OUT/input-lifecycle.log" || true

if [[ "$EXTERNAL_HOOK" == 1 ]]; then
  # Prefer the live capture: it starts before the trial and preserves one
  # ordered stream. A later hilog -x snapshot can have already rolled the
  # short page-pop/Cancel sequence out under high-frequency VO diagnostics.
  # Only fall back to bounded post-flush snapshots when the live capture does
  # not contain the app-owned trigger at all. Dart's pointer number and
  # ArkUI's pointerId are different namespaces, so correlate the embedding
  # activeOwner rather than comparing unrelated event sequence numbers.
  evidence_log="$OUT/hilog.txt"
  if ! grep -Fq 'process-live-test page-pop' "$evidence_log" &&
     ! grep -Fq 'process-live-test direct-page-pop' "$evidence_log"; then
    evidence_log="$OUT/hilog-final.txt"
    for ((evidence_attempt=1; evidence_attempt<=EVIDENCE_RETRIES; evidence_attempt++)); do
      run_hdc shell hilog -x >"$evidence_log" 2>&1 || true
      if grep -Fq 'process-live-test page-pop' "$evidence_log" ||
         grep -Fq 'process-live-test direct-page-pop' "$evidence_log"; then
        break
      fi
      if (( evidence_attempt < EVIDENCE_RETRIES )); then
        sleep "$EVIDENCE_RETRY_WAIT"
      fi
    done
  fi
  page_pop_count=$(grep -Ec 'process-live-test (page-pop|direct-page-pop)' "$evidence_log" || true)
  page_pop_line=$(grep -E 'process-live-test (page-pop|direct-page-pop)' "$evidence_log" | head -1 || true)
  page_pointer=$(printf '%s\n' "$page_pop_line" | sed -n 's/.*pointer=\([0-9][0-9]*\).*/\1/p')

  # The current production embedding emits the app-owned lifecycle trace
  # rather than the older hcpp_input owner/napi/attachment trace. Keep this
  # as a separate gate: it proves page-pop, active-touch cancellation, player
  # disposal, native-surface destruction, and process continuity, but it does
  # not claim HCPP attachment protocol evidence.
  app_page_pop_line_number=$(grep -En 'process-live-test (page-pop|direct-page-pop)' "$evidence_log" |
    head -1 | cut -d: -f1 || true)
  app_pointer_down_line_number=""
  app_pointer_cancel_line_number=""
  app_pointer_up_before_cancel=0
  app_pointer_cancel_count=0
  app_route_cancel_count=0
  app_route_removed_line_number=$(grep -n 'global route removed' "$evidence_log" |
    head -1 | cut -d: -f1 || true)
  app_dispose_line_number=$(grep -n 'FullscreenPlatformTrace.*dispose owner=' "$evidence_log" |
    head -1 | cut -d: -f1 || true)
  app_surface_destroyed_line_number=$(grep -n 'native surface event nativeSurfaceDestroyed' "$evidence_log" |
    head -1 | cut -d: -f1 || true)
  if [[ "$page_pointer" =~ ^[0-9]+$ ]]; then
    app_pointer_down_line_number=$(grep -n 'PlayerTouchTrace.*PointerDown' "$evidence_log" |
      grep -E "pointer=${page_pointer}([^0-9]|$)" | head -1 | cut -d: -f1 || true)
    app_pointer_cancel_line_number=$(grep -n 'PlayerTouchTrace.*PointerCancel' "$evidence_log" |
      grep -E "pointer=${page_pointer}([^0-9]|$)" | head -1 | cut -d: -f1 || true)
    app_pointer_cancel_count=$(grep -E 'PlayerTouchTrace.*MouseInteractiveViewer Listener PointerCancel' "$evidence_log" |
      grep -E "pointer=${page_pointer}([^0-9]|$)" | wc -l | tr -d ' ')
    app_route_cancel_count=$(grep -E 'PlayerTouchTrace.*global route cancel' "$evidence_log" |
      grep -E "pointer=${page_pointer}([^0-9]|$)" | wc -l | tr -d ' ')
    if [[ "$app_pointer_cancel_line_number" =~ ^[0-9]+$ ]]; then
      app_pointer_up_before_cancel=$(awk -v limit="$app_pointer_cancel_line_number" -v pointer="$page_pointer" '
        NR < limit && /PlayerTouchTrace/ && /(PointerUp|global route up)/ &&
        $0 ~ "pointer=" pointer "([^0-9]|$)" { count++ }
        END { print count + 0 }
      ' "$evidence_log")
    fi
  fi
  app_lifecycle_gate=0
  if [[ "$page_pop_count" == 1 && "$app_page_pop_line_number" =~ ^[0-9]+$ &&
    "$app_pointer_down_line_number" =~ ^[0-9]+$ &&
    "$app_pointer_cancel_line_number" =~ ^[0-9]+$ && "$app_pointer_cancel_count" == 1 &&
    "$app_route_cancel_count" == 1 &&
    "$app_pointer_up_before_cancel" == 0 &&
    "$app_pointer_down_line_number" -lt "$app_page_pop_line_number" &&
    "$app_page_pop_line_number" -lt "$app_pointer_cancel_line_number" &&
    "$app_route_removed_line_number" =~ ^[0-9]+$ &&
    "$app_dispose_line_number" =~ ^[0-9]+$ &&
    "$app_surface_destroyed_line_number" =~ ^[0-9]+$ &&
    "$app_pointer_cancel_line_number" -lt "$app_route_removed_line_number" &&
    "$app_route_removed_line_number" -lt "$app_dispose_line_number" &&
    "$app_dispose_line_number" -lt "$app_surface_destroyed_line_number" ]]; then
    app_lifecycle_gate=1
  fi
  cancel_count=$(grep -c 'hcpp_input stage=owner.*TouchType=Cancel' "$evidence_log" || true)
  hcpp_record_count=$(grep -c 'hcpp_input ' "$evidence_log" || true)
  owner_line=""
  cancel_line=""
  dispose_line=""
  cancel_line_number=""
  dispose_line_number=""
  cancel_napi_line_number=""
  cancel_view_epoch=""
  cancel_owner_seq=""
  arkui_pointer=""
  owner_line_number=""
  dart_cancel_count=0
  if [[ "$page_pointer" =~ ^[0-9]+$ ]]; then
    dart_cancel_count=$(grep -E 'PointerCancel|global route cancel' "$evidence_log" |
      grep -E "pointer=${page_pointer}([^0-9]|$)" | wc -l | tr -d ' ')
  fi
  cancel_line_number=$(grep -n 'hcpp_input stage=owner.*TouchType=Cancel' "$evidence_log" |
    head -1 | cut -d: -f1 || true)
  if [[ "$cancel_line_number" =~ ^[0-9]+$ ]]; then
    cancel_line=$(sed -n "${cancel_line_number}p" "$evidence_log")
  fi
  cancel_view=$(printf '%s\n' "$cancel_line" |
    sed -n 's/.*platformViewId=\([0-9][0-9]*\).*/\1/p')
  cancel_epoch=$(printf '%s\n' "$cancel_line" |
    sed -n 's/.*epoch=\([0-9][0-9]*\).*/\1/p')
  cancel_view_epoch=""
  if [[ "$cancel_view" =~ ^[0-9]+$ && "$cancel_epoch" =~ ^[0-9]+$ ]]; then
    cancel_view_epoch="$cancel_view $cancel_epoch"
  fi
  cancel_owner_seq=$(printf '%s\n' "$cancel_line" |
    sed -n 's/.*ownerSeq=\([0-9][0-9]*\).*/\1/p')
  cancel_active_owner=$(printf '%s\n' "$cancel_line" |
    sed -n 's/.*activeOwner=\([0-9][0-9]*\).*/\1/p')
  arkui_pointer=$(printf '%s\n' "$cancel_line" |
    sed -n 's/.*pointerId=\([0-9][0-9]*\).*/\1/p')
  if [[ -n "$cancel_view_epoch" ]]; then
    read -r cancel_view cancel_epoch <<<"$cancel_view_epoch"
    # ownerSeq identifies the embedding transaction that emitted the Cancel;
    # it is intentionally different from the earlier Down event's seq.  The
    # stable association is the native activeOwner pointer within the same
    # view/epoch, and must be found before the Cancel line.
    if [[ "$cancel_active_owner" =~ ^[0-9]+$ ]]; then
    owner_line_number=$(grep -n 'hcpp_input stage=owner' "$evidence_log" |
        grep -E "epoch=${cancel_epoch} platformViewId=${cancel_view} TouchType=Down pointerId=${cancel_active_owner}.*accepted" |
        awk -F: -v limit="$cancel_line_number" '$1 < limit { line=$1 } END { print line }' || true)
      if [[ "$owner_line_number" =~ ^[0-9]+$ ]]; then
        owner_line=$(sed -n "${owner_line_number}p" "$evidence_log")
      fi
    fi
    dispose_line=$(grep 'hcpp_input attachment' "$evidence_log" |
      grep -E "platformViewId=${cancel_view} epoch=${cancel_epoch} action=dispose" |
      head -1 || true)
    dispose_line_number=$(grep -n 'hcpp_input attachment' "$evidence_log" |
      grep -E "platformViewId=${cancel_view} epoch=${cancel_epoch} action=dispose" |
      head -1 | cut -d: -f1 || true)
    cancel_napi_line_number=$(grep -n 'hcpp_input stage=napi-request' "$evidence_log" |
      grep -E "epoch=${cancel_epoch}.*platformViewId=${cancel_view}.*TouchType=Cancel" |
      head -1 | cut -d: -f1 || true)
  fi
  up_before_cancel=0
  if [[ "$cancel_line_number" =~ ^[0-9]+$ && "$arkui_pointer" =~ ^[0-9]+$ ]]; then
    up_before_cancel=$(awk -v limit="$cancel_line_number" -v pointer="$arkui_pointer" '
      NR < limit && /hcpp_input stage=owner/ && /TouchType=Up/ &&
      $0 ~ "pointerId=" pointer "([^0-9]|$)" { count++ }
      END { print count + 0 }
    ' "$evidence_log")
  fi
  pid_stable=0
  if [[ -s "$OUT/pid-before.txt" && -s "$OUT/pid-after.txt" ]] &&
    cmp -s "$OUT/pid-before.txt" "$OUT/pid-after.txt"; then
    pid_stable=1
  fi
  if [[ "$page_pop_count" != 1 || ! "$page_pointer" =~ ^[0-9]+$ || "$cancel_count" != 1 ||
    -z "$owner_line" || -z "$cancel_line" || -z "$dispose_line" ||
    ! "$owner_line_number" =~ ^[0-9]+$ || ! "$dispose_line_number" =~ ^[0-9]+$ ||
    ! "$cancel_line_number" =~ ^[0-9]+$ || ! "$cancel_napi_line_number" =~ ^[0-9]+$ ||
    "$owner_line_number" -ge "$cancel_line_number" ||
    "$cancel_line_number" -ge "$cancel_napi_line_number" ||
    "$cancel_napi_line_number" -ge "$dispose_line_number" ||
    "$up_before_cancel" != 0 || "$dart_cancel_count" -lt 1 || "$pid_stable" != 1 ]]; then
    if [[ "$app_lifecycle_gate" == 1 && "$pid_stable" == 1 ]]; then
      write_verdict PASS NOT_OBSERVED NOT_RUN INCONCLUSIVE
      echo "application lifecycle gate: PASS page-pop=$page_pop_count dart-pointer=$page_pointer listener-cancel=$app_pointer_cancel_count route-cancel=$app_route_cancel_count route-removed=$app_route_removed_line_number dispose=$app_dispose_line_number surface-destroyed=$app_surface_destroyed_line_number pid-stable=$pid_stable"
      if [[ "$hcpp_record_count" == 0 ]]; then
        echo "HCPP attachment protocol gate: NOT OBSERVED (no hcpp_input owner/cancel/napi/attachment records in this build)"
        exit 0
      fi
      write_verdict PASS FAIL NOT_RUN FAIL
      echo "HCPP attachment protocol gate: FAIL (hcpp_input records present but correlated owner/cancel/napi/dispose chain did not pass)" >&2
      exit 2
    fi
    write_verdict FAIL FAIL NOT_RUN FAIL
    echo "process-live external-hook gate failed: page-pop=$page_pop_count dart-pointer=${page_pointer:-none} arkui-pointer=${arkui_pointer:-none} listener-cancel=$app_pointer_cancel_count route-cancel=$app_route_cancel_count owner=$([[ -n "$owner_line" ]] && echo 1 || echo 0) dispose=$([[ -n "$dispose_line" ]] && echo 1 || echo 0) cancel=$([[ -n "$cancel_line" ]] && echo 1 || echo 0) cancel-napi=$([[ "$cancel_napi_line_number" =~ ^[0-9]+$ ]] && echo 1 || echo 0) sequence=${owner_line_number:-none}<${cancel_line_number:-none}<${cancel_napi_line_number:-none}<${dispose_line_number:-none} up-before-cancel=$up_before_cancel pid-stable=$pid_stable" >&2
    echo "required evidence: correlated Down -> cancel-request -> Cancel napi-request -> dispose, Dart Cancel, and stable process" >&2
    exit 2
  fi
  write_verdict PASS PASS NOT_RUN PASS
  echo "process-live external-hook gate: embedding-ownerSeq=$cancel_owner_seq arkui-pointer=$arkui_pointer view=$cancel_view epoch=$cancel_epoch dart-pointer=$page_pointer listener-cancel=$app_pointer_cancel_count route-cancel=$app_route_cancel_count"
fi

if [[ ! -s "$OUT/verdict.env" ]]; then
  write_verdict NOT_RUN NOT_RUN NOT_RUN INCONCLUSIVE
fi
echo "process-live probe complete: $OUT"
echo "interpretation: inspect input-lifecycle.log for exactly-one Cancel and old/new attachment evidence; this is not a gray-screen verdict"
