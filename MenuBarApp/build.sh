#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/SkyDimoBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="$ROOT/build/SkyDimoBar.iconset"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

swiftc "$ROOT/Sources/SkyDimoBar.swift" \
  -framework AppKit \
  -o "$MACOS/SkyDimoBar"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
swift "$ROOT/Tools/GenerateIcon.swift" "$ICONSET" "$RESOURCES/SkyDimoBar.icns"
chmod +x "$MACOS/SkyDimoBar"

echo "$APP"
