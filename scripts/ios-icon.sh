#!/bin/bash
# Renders the iOS app icon (opaque, full-bleed 1024x1024) into the asset catalog.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/ui.sh
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi

ui_header "Render iOS Icon"
ui_step 1 "Building Swift package"
swift build >/dev/null
ui_step 2 "Rendering icon"
SET=ios/App/Assets.xcassets/AppIcon.appiconset
mkdir -p "$SET"
TMP=$(mktemp -d)
.build/debug/Tristan --make-icon "$TMP/raw.png" --full-bleed >/dev/null
sips -z 1024 1024 "$TMP/raw.png" --out "$TMP/sized.png" >/dev/null
# iOS rejects icons with an alpha channel; a JPEG round trip removes it.
sips -s format jpeg "$TMP/sized.png" --out "$TMP/flat.jpg" >/dev/null
sips -s format png "$TMP/flat.jpg" --out "$SET/icon-1024.png" >/dev/null
cat > "$SET/Contents.json" <<JSON
{ "images": [ { "filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
  "info": { "author": "xcode", "version": 1 } }
JSON
cat > ios/App/Assets.xcassets/Contents.json <<JSON
{ "info": { "author": "xcode", "version": 1 } }
JSON
rm -rf "$TMP"
ui_success "Wrote $SET/icon-1024.png"
ui_footer
