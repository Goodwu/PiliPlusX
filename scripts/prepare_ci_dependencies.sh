#!/usr/bin/env bash

# `pubspec_overrides.yaml` deliberately points at a developer's sibling
# media-kit checkout.  A hosted runner must use the checked-in git sources
# and lock file instead.  Move rather than delete the override so the checkout
# remains inspectable when a job fails.
set -euo pipefail

override_file="${1:-pubspec_overrides.yaml}"
if [[ -f "$override_file" ]]; then
  ci_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  mkdir -p "$ci_temp/piliplusx-local-overrides"
  mv "$override_file" "$ci_temp/piliplusx-local-overrides/"
  echo "ignored developer-local dependency override: $override_file"
fi
