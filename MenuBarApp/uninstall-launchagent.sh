#!/bin/sh
set -eu

PLIST_DST="$HOME/Library/LaunchAgents/local.skydimo.menubar.plist"
APP_DST="/Applications/SkyDimoBar.app"

launchctl bootout "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1 || true
killall SkyDimoBar >/dev/null 2>&1 || true
rm -f "$PLIST_DST"

if ! rm -rf "$APP_DST" 2>/dev/null; then
  echo "Need administrator permission to remove $APP_DST"
  sudo rm -rf "$APP_DST"
fi

echo "Removed launch agent and app"
