#!/usr/bin/env bash
set -euo pipefail

# Orchestrate the only valid same-process page-exit/re-entry sequence:
# pause the playing fullscreen gate, trigger the app-owned process-live hook
# while that exact process is still active, then reuse the process to reopen
# the same source. The gate is allowed to fail after its page is popped; the
# lifecycle and re-entry gates are evaluated independently.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HDC_BIN=${HDC_BIN:-/Users/wuweiwei1/bin/hdc}
HDC_TARGET=${HDC_TARGET:-2PM0223A18006914}
SOURCE=${VERIFY_REENTRY_SOURCE:-BV15z4y1Z734}
OUT=${VERIFY_REENTRY_OUT:-/tmp/piliplusx-ohos-surface-page-exit-reentry-$(date +%Y%m%d-%H%M%S)}

while (($#)); do
  case "$1" in
    --source) SOURCE=${2:?missing value for --source}; shift 2 ;;
    --out) OUT=${2:?missing value for --out}; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: verify_surface_page_exit_reentry_real_device.sh [--source BVID] [--out DIR]

On an already installed diagnostic HAP, run a playing fullscreen gate paused
at its stable layout, trigger the process-live page-exit hook in the same
process, then reopen the source with VERIFY_REUSE_CURRENT_APP=1.
USAGE
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

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

GATE_OUT="$OUT/fullscreen-gate"
EXIT_OUT="$OUT/page-exit"
REENTRY_OUT="$OUT/reentry"
mkdir -p "$GATE_OUT" "$EXIT_OUT" "$REENTRY_OUT"
PAUSE_FILE="$OUT/continue-after-page-exit"

VERIFY_KEEP_SCREEN_ON=${VERIFY_KEEP_SCREEN_ON:-1} \
VERIFY_SCREEN_TIMEOUT_MS=${VERIFY_SCREEN_TIMEOUT_MS:-3600000} \
VERIFY_PAUSE_AFTER_READY_FILE="$PAUSE_FILE" \
  HDC_BIN="$HDC_BIN" HDC_TARGET="$HDC_TARGET" \
  "$SCRIPT_DIR/verify_hdr_real_device.sh" --source "$SOURCE" --cycles 1 \
  --out "$GATE_OUT" >"$OUT/fullscreen-gate.stdout" 2>&1 &
gate_pid=$!
cleanup() {
  if kill -0 "$gate_pid" 2>/dev/null; then
    kill "$gate_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

stable="$GATE_OUT/08-fullscreen-stable.json"
ready="$PAUSE_FILE.ready"
for _ in $(seq 1 480); do
  [[ -s "$stable" && -e "$ready" ]] && break
  kill -0 "$gate_pid" 2>/dev/null || break
  sleep 0.25
done
[[ -s "$stable" && -e "$ready" ]] || {
  echo "fullscreen readiness barrier was not produced: stable=$stable ready=$ready" >&2
  wait "$gate_pid" || true
  exit 1
}

VERIFY_KEEP_SCREEN_ON=${VERIFY_KEEP_SCREEN_ON:-1} \
VERIFY_SCREEN_TIMEOUT_MS=${VERIFY_SCREEN_TIMEOUT_MS:-3600000} \
VERIFY_PROCESS_LIVE_EXTERNAL_HOOK=1 \
VERIFY_PROCESS_LIVE_HOLD_SWIPE=1 \
VERIFY_PROCESS_LIVE_HOLD_GESTURE=longClick \
VERIFY_PROCESS_LIVE_LOG_FLUSH_WAIT=${VERIFY_PROCESS_LIVE_LOG_FLUSH_WAIT:-15} \
  HDC_BIN="$HDC_BIN" HDC_TARGET="$HDC_TARGET" \
  "$SCRIPT_DIR/verify_process_live_view_exit.sh" --out "$EXIT_OUT" \
  >"$OUT/page-exit.stdout" 2>&1 || exit_rc=$?
exit_rc=${exit_rc:-0}

# The process-live hook owns page disposal. Terminate the old gate after its
# evidence has been collected instead of releasing its next UI action: after
# page-pop, its stale fullscreen/control coordinates could otherwise pollute
# the re-entry experiment.
if kill -0 "$gate_pid" 2>/dev/null; then
  kill "$gate_pid" 2>/dev/null || true
fi
wait "$gate_pid" 2>/dev/null || true

VERIFY_REUSE_CURRENT_APP=1 VERIFY_REENTRY_PLAYBACK_ONLY=1 \
VERIFY_KEEP_SCREEN_ON=${VERIFY_KEEP_SCREEN_ON:-1} \
VERIFY_SCREEN_TIMEOUT_MS=${VERIFY_SCREEN_TIMEOUT_MS:-3600000} \
  HDC_BIN="$HDC_BIN" HDC_TARGET="$HDC_TARGET" \
  "$SCRIPT_DIR/verify_hdr_real_device.sh" --source "$SOURCE" --cycles 1 \
  --out "$REENTRY_OUT" >"$OUT/reentry.stdout" 2>&1 || reentry_rc=$?
reentry_rc=${reentry_rc:-0}

read_verdict_overall() {
  local verdict="$1"
  [[ -s "$verdict" ]] || return 1
  awk -F= '$1 == "overall" { print $2; found=1 } END { exit found ? 0 : 1 }' "$verdict"
}

exit_overall="$(read_verdict_overall "$EXIT_OUT/verdict.env" || echo INCONCLUSIVE)"
reentry_overall="$(read_verdict_overall "$REENTRY_OUT/verdict.env" || echo INCONCLUSIVE)"
reentry_pid_before="$(tr -d '\r\n' < "$REENTRY_OUT/pid-reuse-before.txt" 2>/dev/null || true)"
reentry_pid_after="$(awk -F= '$1 == "pid" { print $2; found=1 } END { exit found ? 0 : 1 }' "$REENTRY_OUT/verdict.env" 2>/dev/null || true)"
if [[ -z "$reentry_pid_before" || "$reentry_pid_before" != "$reentry_pid_after" ]]; then
  reentry_overall=INCONCLUSIVE
fi

echo "page_exit_rc=$exit_rc"
echo "reentry_rc=$reentry_rc"
echo "page_exit_verdict=$exit_overall"
echo "reentry_verdict=$reentry_overall"
echo "reentry_pid_before=$reentry_pid_before"
echo "reentry_pid_after=$reentry_pid_after"
echo "artifacts: $OUT"
tail -40 "$OUT/page-exit.stdout" || true
tail -40 "$OUT/reentry.stdout" || true
if [[ "$exit_rc" -ne 0 || "$reentry_rc" -ne 0 ||
  "$exit_overall" != PASS || "$reentry_overall" != PASS ]]; then
  echo "same-process page exit/re-entry verdict is not PASS: " \
    "page_exit=$exit_overall reentry=$reentry_overall" >&2
  exit 1
fi
