#!/bin/bash
# Builds Tristan from source and installs it into /Applications (replacing any previous copy), then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/ui.sh
DEST="/Applications/Tristan.app"

ui_header "Install"
ui_step 1 "Building application"
scripts/bundle.sh

# Quit a running copy so the files can be replaced.
ui_step 2 "Stopping existing application"
osascript -e 'tell application id "com.tristan.app" to quit' >/dev/null 2>&1 || true
pkill -x Tristan >/dev/null 2>&1 || true
sleep 1

ui_step 3 "Installing to /Applications"
rm -rf "$DEST"
cp -R Tristan.app "$DEST"
# Clear the quarantine flag so Gatekeeper does not block a locally built app.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
ui_success "Installed $DEST"

ui_step 4 "Launching application"
open "$DEST"
ui_footer
