#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/SkyDimoBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

swiftc "$ROOT/Sources/SkyDimoBar.swift" \
  -framework AppKit \
  -o "$MACOS/SkyDimoBar"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
chmod +x "$MACOS/SkyDimoBar"

echo "$APP"
