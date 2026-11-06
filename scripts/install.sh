#!/bin/bash
# Builds Tristan from source and installs it into /Applications (replacing any previous copy), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="/Applications/Tristan.app"

scripts/bundle.sh

# Quit a running copy so the files can be replaced.
osascript -e 'tell application id "com.tristan.app" to quit' >/dev/null 2>&1 || true
pkill -x Tristan >/dev/null 2>&1 || true
sleep 1

rm -rf "$DEST"
cp -R Tristan.app "$DEST"
# Clear the quarantine flag so Gatekeeper does not block a locally built app.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "Installed $DEST"
open "$DEST"
