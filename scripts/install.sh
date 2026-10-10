#!/bin/bash
# Builds Screensaverr from source and installs it for the current user.
# Needs Xcode (not just the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building Screensaverr…"
xcodebuild \
  -project Screensaverr.xcodeproj \
  -target Screensaverr \
  -configuration Release \
  CODE_SIGN_IDENTITY=- \
  SYMROOT="$PWD/build" \
  build > build.log 2>&1 || { tail -n 40 build.log; echo "Build failed — full log in build.log"; exit 1; }

DEST="$HOME/Library/Screen Savers"
mkdir -p "$DEST"
rm -rf "$DEST/Screensaverr.saver"
cp -R build/Release/Screensaverr.saver "$DEST/"

# macOS keeps the previous version loaded until its screen saver host restarts.
killall legacyScreenSaver legacyScreenSaver-x86_64 2>/dev/null || true

echo "Installed to $DEST/Screensaverr.saver"
echo "Open System Settings › Screen Saver, pick Screensaverr and click Options… to add your servers."
echo "(If System Settings was already open, quit and reopen it to pick up the new version.)"
