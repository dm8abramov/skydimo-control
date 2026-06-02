#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_SRC="$ROOT/MenuBarApp/build/SkyDimoBar.app"
APP_DST="/Applications/SkyDimoBar.app"
PLIST_DST="$HOME/Library/LaunchAgents/local.skydimo.menubar.plist"
LABEL="local.skydimo.menubar"

if [ ! -d "$APP_SRC" ]; then
  echo "Build the app first: $ROOT/MenuBarApp/build.sh" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1 || true
killall SkyDimoBar >/dev/null 2>&1 || true

if ! { rm -rf "$APP_DST" && cp -R "$APP_SRC" "$APP_DST"; } 2>/dev/null; then
  echo "Need administrator permission to replace $APP_DST"
  sudo rm -rf "$APP_DST"
  sudo cp -R "$APP_SRC" "$APP_DST"
  sudo chown -R "$(id -u):$(id -g)" "$APP_DST" >/dev/null 2>&1 || true
fi

cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DST/Contents/MacOS/SkyDimoBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl enable "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $APP_DST"
echo "Loaded $PLIST_DST"
