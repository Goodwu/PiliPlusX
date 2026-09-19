#!/usr/bin/env bash
set -euo pipefail

# Verify that a portrait swipe below the player moves the nested recommendation
# list. All UI input and layout capture are scripted.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HDC_BIN=${HDC_BIN:-/Users/wuweiwei1/bin/hdc}
HDC_TARGET=${HDC_TARGET:-2PM0223A18006914}
SOURCE=${VERIFY_GESTURE_SOURCE:-BV1Wp4y1P7KU}
OUT=${VERIFY_RECOMMENDATION_OUT:-/tmp/piliplusx-ohos-recommendation-scroll-$(date +%Y%m%d-%H%M%S)}
PAUSE_FILE="$OUT/continue-before-fullscreen"
HAP=

while (($#)); do
  case "$1" in
    --source) SOURCE=${2:?missing value for --source}; shift 2 ;;
    --out) OUT=${2:?missing value for --out}; PAUSE_FILE="$OUT/continue-before-fullscreen"; shift 2 ;;
    --hap) HAP=${2:?missing value for --hap}; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: verify_player_recommendation_scroll_real_device.sh [--source BVID] [--hap FILE] [--out DIR]
USAGE
      exit 0 ;;
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

gate_out="$OUT/gate"
mkdir -p "$gate_out"
rm -f "$PAUSE_FILE"
gate_args=(--source "$SOURCE" --vertical --cycles 1 --out "$gate_out")
if [[ -n "$HAP" ]]; then gate_args+=(--hap "$HAP"); fi
VERIFY_REQUIRE_HDR=0 VERIFY_KEEP_SCREEN_ON=${VERIFY_KEEP_SCREEN_ON:-1} \
VERIFY_SCREEN_TIMEOUT_MS=${VERIFY_SCREEN_TIMEOUT_MS:-3600000} \
VERIFY_PAUSE_BEFORE_FULLSCREEN_FILE="$PAUSE_FILE" \
  "$SCRIPT_DIR/verify_hdr_real_device.sh" "${gate_args[@]}" &
gate_pid=$!
cleanup() {
  : >"$PAUSE_FILE"
  if kill -0 "$gate_pid" 2>/dev/null; then kill "$gate_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

stable="$gate_out/06-controls-click.json"
for _ in $(seq 1 480); do
  [[ -s "$stable" ]] && break
  kill -0 "$gate_pid" 2>/dev/null || break
  sleep 0.25
done
[[ -s "$stable" ]] || { echo "windowed stable layout was not produced" >&2; wait "$gate_pid" || true; exit 1; }

read -r swipe_x swipe_start swipe_end < <(
  python3 - "$stable" <<'PY'
import json, re, sys
root=json.load(open(sys.argv[1], encoding="utf-8"))
rects=[]; sliders=[]
def walk(node):
    a=node.get("attributes", {})
    m=re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", a.get("bounds",""))
    if m and a.get("type") == "Slider": sliders.append(tuple(map(int,m.groups())))
    if m and a.get("type") in {"View","Stack","NodeContainer"}:
        x1,y1,x2,y2=map(int,m.groups())
        if x2-x1 >= 800 and y2-y1 >= 400: rects.append((x1,y1,x2,y2))
    for child in node.get("children",[]): walk(child)
walk(root)
if not rects: raise SystemExit("no player bounds in stable layout")
screen_h=max(r[3] for r in rects)
if sliders:
    x1,y1,x2,y2=0,0,screen_h,min(screen_h,min(s[1] for s in sliders)+220)
else:
    player_rects=[r for r in rects if r[3] < screen_h-200]
    if not player_rects: raise SystemExit(f'no bounded player rectangle: screen_h={screen_h}')
    x1,y1,x2,y2=max(player_rects,key=lambda r:(r[2]-r[0])*(r[3]-r[1]))
start=min(screen_h-100,y2+500)
end=start-400
if not (y2+20 < end < start < screen_h):
    raise SystemExit(f"no safe recommendation area below player: {(x1,y1,x2,y2)}")
print((x1+x2)//2,start,end)
PY
)

cp "$stable" "$OUT/layout-before.json"
"$HDC_BIN" -t "$HDC_TARGET" shell hilog -r >"$OUT/hilog-clear.txt"
timeout 15 "$HDC_BIN" -t "$HDC_TARGET" shell uitest uiInput swipe "$swipe_x" "$swipe_start" "$swipe_x" "$swipe_end" 700 >"$OUT/swipe-command.txt" 2>&1
sleep 1
"$HDC_BIN" -t "$HDC_TARGET" shell uitest dumpLayout -p /data/local/tmp/piliplusx-recommendation-after.json >/dev/null
"$HDC_BIN" -t "$HDC_TARGET" file recv /data/local/tmp/piliplusx-recommendation-after.json "$OUT/layout-after.json" >/dev/null

python3 - "$OUT/layout-before.json" "$OUT/layout-after.json" <<'PY'
import json, re, sys
def player(path):
    root=json.load(open(path, encoding="utf-8")); out=[]
    def walk(node):
        a=node.get("attributes", {})
        m=re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", a.get("bounds",""))
        if m and a.get("type") in {"View","Stack","NodeContainer"}:
            x1,y1,x2,y2=map(int,m.groups())
            if x2-x1 >= 800 and y2-y1 >= 400: out.append((x1,y1,x2,y2))
        for child in node.get("children",[]): walk(child)
    walk(root)
    if not out: raise SystemExit("no player bounds after swipe")
    screen_h=max(r[3] for r in out)
    bounded=[r for r in out if r[3] < screen_h-200]
    return max(bounded,key=lambda r:(r[2]-r[0])*(r[3]-r[1])) if bounded else None
before,after=player(sys.argv[1]),player(sys.argv[2])
def first_text(path, threshold):
    root=json.load(open(path, encoding="utf-8")); ys=[]
    def walk(node):
        a=node.get("attributes",{}); m=re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]",a.get("bounds",""))
        if m and a.get("type")=="Text" and int(m.group(2)) > threshold: ys.append(int(m.group(2)))
        for c in node.get("children",[]): walk(c)
    walk(root); return min(ys) if ys else None
before_text=first_text(sys.argv[1],1900); after_text=first_text(sys.argv[2],1200)
print(f"player-before={before} after={after} listTextBefore={before_text} listTextAfter={after_text}")
if before_text is None or after_text is None or after_text >= before_text-20:
    raise SystemExit("recommendation scroll not observed in list bounds")
PY

# The gate is only a precondition for producing a stable windowed player and
# the recommendation-list coordinate. Do not release it into its unrelated
# fullscreen cycle after the list evidence is collected: a later fullscreen
# timing failure must not overwrite a successful boundary verdict.
if kill -0 "$gate_pid" 2>/dev/null; then
  kill "$gate_pid" 2>/dev/null || true
fi
wait "$gate_pid" 2>/dev/null || true
trap - EXIT
echo "recommendation scroll verdict: PASS (recommendation list text anchor moved upward)"
echo "recommendation artifacts: $OUT"
