#!/usr/bin/env bash

# Hosted release runners resolve several pinned Git dependencies.  Retry only
# transient fetch failures so a temporary upstream 5xx does not discard an
# otherwise reproducible tag build.
set -euo pipefail

readonly max_attempts=3
for attempt in $(seq 1 "$max_attempts"); do
  if flutter pub get "$@"; then
    exit 0
  fi

  if [[ "$attempt" -eq "$max_attempts" ]]; then
    echo "flutter pub get failed after ${max_attempts} attempts" >&2
    exit 1
  fi

  delay=$((attempt * 15))
  echo "flutter pub get failed; retrying in ${delay}s (attempt ${attempt}/${max_attempts})" >&2
  sleep "$delay"
done
