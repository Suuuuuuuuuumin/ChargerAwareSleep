#!/bin/bash
# 정책 로직 self-check. assert 를 살려야 하므로 -Onone 으로 빌드한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
swiftc -Onone -parse-as-library -target arm64-apple-macos13.0 \
  -o "$ROOT/build/policytests" \
  "$ROOT/Sources/Policy.swift" "$ROOT/Tests/PolicyTests.swift"
"$ROOT/build/policytests"
