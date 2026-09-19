#!/usr/bin/env bash
set -euo pipefail

# Run the existing script-driven fullscreen/HDR regression independently for
# each source. Each source gets a separate artifact directory so a format
# change cannot be hidden by a later source's RenderService baseline.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify_hdr_real_device.sh"
HAP="${VERIFY_MATRIX_HAP:-}"
OUT_ROOT="${VERIFY_MATRIX_OUT:-/tmp/piliplusx-ohos-hdr-matrix-$(date +%Y%m%d-%H%M%S)}"
CYCLES="${VERIFY_MATRIX_CYCLES:-30}"
SOURCES=(
  "${VERIFY_SOURCE_TRUE_COLOR_HDR:-BV15z4y1Z734}"
  "${VERIFY_SOURCE_HDR_VIVID:-BV121421y7PM}"
  "${VERIFY_SOURCE_HLG:-BV1ZB4y1F7jf}"
  "${VERIFY_SOURCE_PQ_HLG_SDR:-BV1tM4y1L7EF}"
)
SOURCE_PQ_HLG_SDR_VERTICAL="${VERIFY_SOURCE_PQ_HLG_SDR_VERTICAL:-0}"
EXPECTED_HDR_VIVID_REGEX="${VERIFY_EXPECTED_HDR_VIVID_REGEX:-source=hdrVivid}"
EXPECTED_HLG_REGEX="${VERIFY_EXPECTED_HLG_REGEX:-transfer=hlg}"
SKIP_HDR_VIVID="${VERIFY_MATRIX_SKIP_HDR_VIVID:-0}"
SKIP_HLG="${VERIFY_MATRIX_SKIP_HLG:-0}"
SKIPPED_SOURCES=()

usage() {
  cat <<'USAGE'
usage: verify_hdr_source_matrix_real_device.sh --hap FILE [options]

options:
  --hap FILE       signed HAP to install for every source
  --out DIR        root directory for per-source evidence
  --cycles N       fullscreen cycles per source (default: 30)
  --skip-hdr-vivid skip the currently unavailable HDR Vivid source (exit 3)
  --skip-hlg       skip the currently unavailable HLG source (exit 3)

The source defaults are, in order: true-color HDR, HDR Vivid, HLG test,
and a PQ/HLG/SDR comparison source. Override them with VERIFY_SOURCE_*
environment variables when a source is unavailable.
USAGE
}

while (($#)); do
  case "$1" in
    --hap) HAP="${2:?missing HAP}"; shift 2 ;;
    --out) OUT_ROOT="${2:?missing output directory}"; shift 2 ;;
    --cycles) CYCLES="${2:?missing cycles}"; shift 2 ;;
    --skip-hdr-vivid) SKIP_HDR_VIVID=1; shift ;;
    --skip-hlg) SKIP_HLG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$HAP" && -f "$HAP" ]] || {
  echo "--hap is required and must name an existing signed HAP" >&2
  exit 2
}
[[ "$CYCLES" =~ ^[0-9]+$ && "$CYCLES" -gt 0 ]] || {
  echo "invalid cycles: $CYCLES" >&2
  exit 2
}
[[ "$SKIP_HDR_VIVID" == 0 || "$SKIP_HDR_VIVID" == 1 ]] || {
  echo "invalid VERIFY_MATRIX_SKIP_HDR_VIVID: $SKIP_HDR_VIVID" >&2
  exit 2
}
[[ "$SKIP_HLG" == 0 || "$SKIP_HLG" == 1 ]] || {
  echo "invalid VERIFY_MATRIX_SKIP_HLG: $SKIP_HLG" >&2
  exit 2
}
[[ "$SOURCE_PQ_HLG_SDR_VERTICAL" == 0 || "$SOURCE_PQ_HLG_SDR_VERTICAL" == 1 ]] || {
  echo "invalid VERIFY_SOURCE_PQ_HLG_SDR_VERTICAL: $SOURCE_PQ_HLG_SDR_VERTICAL" >&2
  exit 2
}
[[ -x "$VERIFY_SCRIPT" ]] || {
  echo "verification script is not executable: $VERIFY_SCRIPT" >&2
  exit 1
}

mkdir -p "$OUT_ROOT"
for source in "${SOURCES[@]}"; do
  label="${source//[^A-Za-z0-9_.-]/_}"
  output="$OUT_ROOT/$label"
  if [[ "$source" == "${SOURCES[1]}" && "$SKIP_HDR_VIVID" == 1 ]]; then
    echo "=== HDR source matrix: $source skipped (HDR Vivid sample unavailable) ===" >&2
    SKIPPED_SOURCES+=("$source")
    continue
  fi
  if [[ "$source" == "${SOURCES[2]}" && "$SKIP_HLG" == 1 ]]; then
    echo "=== HDR source matrix: $source skipped (HLG sample unavailable) ===" >&2
    SKIPPED_SOURCES+=("$source")
    continue
  fi
  echo "=== HDR source matrix: $source -> $output ===" >&2
  source_vertical=0
  if [[ "$source" == "${SOURCES[3]}" && "$SOURCE_PQ_HLG_SDR_VERTICAL" == 1 ]]; then
    source_vertical=1
  fi
  VERIFY_KEEP_SCREEN_ON="${VERIFY_KEEP_SCREEN_ON:-1}" \
  VERIFY_EXPECTED_RENDER_COLOR_SPACE="${VERIFY_EXPECTED_RENDER_COLOR_SPACE:-7}" \
  VERIFY_REQUIRE_COLOR_CONTRACT="${VERIFY_REQUIRE_COLOR_CONTRACT:-1}" \
  VERIFY_REQUIRE_NATIVE_DIAGNOSTICS="${VERIFY_REQUIRE_NATIVE_DIAGNOSTICS:-1}" \
  VERIFY_EXPECTED_LIBMPV_SHA256="${VERIFY_EXPECTED_LIBMPV_SHA256:-}" \
  VERIFY_VERTICAL_VIDEO="$source_vertical" \
    "$VERIFY_SCRIPT" --hap "$HAP" --source "$source" --cycles "$CYCLES" --out "$output"

  # A stable native color contract is not enough to identify the input
  # format. Require an explicit decoder/output marker for the two formats
  # whose network titles have repeatedly been misleading. The patterns are
  # overridable because vendor log spelling can differ between media-kit
  # revisions, but an empty pattern is rejected rather than weakening the
  # gate.
  case "$source" in
    "${SOURCES[1]}")
      expected_regex="$EXPECTED_HDR_VIVID_REGEX"
      format_name="HDR Vivid"
      ;;
    "${SOURCES[2]}")
      expected_regex="$EXPECTED_HLG_REGEX"
      format_name="HLG"
      ;;
    *)
      expected_regex=""
      format_name="unconstrained comparison"
      ;;
  esac
  if [[ -n "$expected_regex" ]]; then
    if ! rg -q --pcre2 "$expected_regex" "$output/hilog.txt"; then
      echo "format gate failed: $source was not identified as $format_name" >&2
      echo "expected regex: $expected_regex" >&2
      echo "artifacts: $output" >&2
      exit 1
    fi
    echo "format gate passed: $source identified as $format_name" >&2
  else
    echo "format gate: $source ($format_name; inspect Hilog classification)" >&2
  fi
done

if ((${#SKIPPED_SOURCES[@]} > 0)); then
  echo "HDR source matrix incomplete: skipped ${SKIPPED_SOURCES[*]}" >&2
  exit 3
fi
echo "HDR source matrix passed: ${#SOURCES[@]} sources, $CYCLES cycles each" >&2
