#!/usr/bin/env bash

# Build the installable Android arm64 release APK with the JDK required by the
# current Android Gradle Plugin. This does not modify the caller's shell or
# global Java selection.
set -euo pipefail

if (($# != 0)); then
  echo "usage: $0" >&2
  echo "This script always builds the Android arm64 release split APK." >&2
  exit 64
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
java_home="${PILIPLUS_ANDROID_JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
java_bin="$java_home/bin/java"

if [[ ! -x "$java_bin" ]]; then
  cat >&2 <<EOF
Android arm64 build requires JDK 17.
Expected: $java_bin

Install it with Homebrew:
  brew install openjdk@17

Or provide a JDK 17 home for this invocation:
  PILIPLUS_ANDROID_JAVA_HOME=/path/to/jdk-17 $0
EOF
  exit 1
fi

java_version="$($java_bin -version 2>&1 | head -n 1)"
if [[ ! "$java_version" =~ \"17\. ]]; then
  echo "JDK 17 is required; found: $java_version" >&2
  exit 1
fi

echo "Using $java_version"
echo "JAVA_HOME=$java_home"

cd "$project_dir"
export JAVA_HOME="$java_home"
exec flutter build apk --release --split-per-abi --target-platform android-arm64
