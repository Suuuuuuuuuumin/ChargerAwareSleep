#!/bin/bash
# Xcode 가 없으므로 swiftc 로 직접 빌드하고 .app 번들을 손으로 만든다.
# -parse-as-library 가 없으면 @main 이 "top-level code" 오류로 실패한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/ChargerAwareSleep.app"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "오류: Resources/AppIcon.icns 가 없습니다. ./make-icon.sh 를 먼저 실행하세요." >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/ChargerAwareSleep" \
  "$ROOT/Sources"/*.swift

# ad-hoc 서명. 로컬 실행에는 Developer ID 가 필요 없다.
codesign -s - --force "$APP"

echo "빌드 완료: $APP"
