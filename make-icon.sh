#!/bin/bash
# Tools/make-icon.swift 로 PNG 를 그리고 iconutil 로 .icns 를 만든다.
# 디자인을 바꿀 때만 돌린다. 결과물 Resources/AppIcon.icns 는 커밋 대상이다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/make-icon"
swiftc -parse-as-library -target arm64-apple-macos13.0 \
  -o "$BIN" \
  "$ROOT/Tools/make-icon.swift"

PNGDIR="$WORK/png"
mkdir -p "$PNGDIR"
"$BIN" "$PNGDIR"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
# @2x 는 두 배 크기의 픽셀을 쓴다.
cp "$PNGDIR/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$PNGDIR/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$PNGDIR/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$PNGDIR/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$PNGDIR/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$PNGDIR/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$PNGDIR/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$PNGDIR/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$PNGDIR/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$PNGDIR/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

/usr/bin/iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "생성 완료: $ROOT/Resources/AppIcon.icns"
