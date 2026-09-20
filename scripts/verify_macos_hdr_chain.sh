#!/usr/bin/env bash

set -euo pipefail

# Fail-closed verifier for the macOS HDR candidate. Static bundle checks are
# necessary but cannot prove a visible HDR frame, so a runtime evidence file is
# mandatory. The evidence file is expected to contain the diagnostic lines
# emitted by the app/native media-kit path for the same playback session.

if [[ $# -ne 2 ]]; then
  echo "usage: $0 APP_PATH RUNTIME_EVIDENCE_LOG" >&2
  exit 2
fi

app=$1
evidence=$2
framework="$app/Contents/Frameworks/Mpv.framework/Versions/A/Mpv"
frameworks="$app/Contents/Frameworks"

[[ -d "$app" ]] || { echo "FAIL: app does not exist: $app" >&2; exit 1; }
[[ -f "$framework" ]] || { echo "FAIL: Mpv.framework binary missing" >&2; exit 1; }
[[ -f "$evidence" ]] || { echo "FAIL: runtime evidence log missing: $evidence" >&2; exit 1; }

file_output=$(file "$framework")
[[ "$file_output" == *x86_64* && "$file_output" == *arm64* ]] || {
  echo "FAIL: Mpv.framework is not universal: $file_output" >&2
  exit 1
}

strings_output=$(strings "$framework")
for required in 'mpv 0.41.0' 'libplacebo' 'gpu-next' 'gl-cocoa' 'videotoolbox-gl'; do
  rg -Fq "$required" <<<"$strings_output" || {
    echo "FAIL: Mpv.framework missing feature/version marker: $required" >&2
    exit 1
  }
done

for required in \
  "$frameworks/libplacebo.dylib" \
  "$frameworks/libvulkan.1.dylib" \
  "$frameworks/libshaderc_shared.1.dylib"; do
  [[ -f "$required" ]] || { echo "FAIL: bundled runtime missing: $required" >&2; exit 1; }
done

if find "$frameworks" -type f \( -name '*.dylib' -o -path '*/Mpv.framework/*/Mpv' \) -print0 |
  xargs -0 -n 1 otool -L 2>/dev/null | rg -q '/opt/homebrew/'; then
  echo "FAIL: bundle contains an absolute Homebrew dependency" >&2
  exit 1
fi

codesign --verify --deep --strict "$app" >/dev/null || {
  echo "FAIL: codesign verification failed" >&2
  exit 1
}

# The same runtime session must prove source classification, producer mapping,
# float frame publication, EDR layer activation and a visible sampled frame.
for required in \
  'source=.*dolby[ -]?vision' \
  'transfer=.*(pq|hlg)' \
  'target-peak[^0-9]*400' \
  'tone-mapping[^[:alnum:]]*bt\.2390' \
  'pixelFormat=.*rgba16Float' \
  'active=true' \
  'drawn=true' \
  'HDR frame sample output.*linearRegions='; do
  rg -i -q "$required" "$evidence" || {
    echo "FAIL: runtime HDR evidence missing pattern: $required" >&2
    exit 1
  }
done

echo "PASS: static macOS HDR bundle and runtime evidence"
echo "app: $app"
echo "evidence: $evidence"
echo "Mpv.framework: universal mpv 0.41.0 with libplacebo/gpu-next/OpenGL"
echo "runtime: Dolby Vision/PQ-or-HLG -> target peak 400 -> RGBA16F -> EDR visible frame"
