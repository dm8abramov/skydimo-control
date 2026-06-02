#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "SkyDimoBar installer"
echo "Project: $ROOT"
echo

echo "Building app..."
"$ROOT/MenuBarApp/build.sh"

echo
echo "Installing app and autostart..."
"$ROOT/MenuBarApp/install-launchagent.sh"

echo
echo "Done. SkyDimoBar is installed in the Applications folder and registered for autostart."
echo "You can close this window."
