#!/bin/bash
# Builds Tristan.app and wraps it in a drag-to-Applications disk image: dist/Tristan-<version>.dmg (+ .sha256).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/ui.sh
export VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"

ui_header "Create Distribution DMG"
ui_step 1 "Building application"
scripts/bundle.sh

ui_step 2 "Staging disk image contents"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R Tristan.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

ui_step 3 "Creating disk image"
mkdir -p dist
DMG="dist/Tristan-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Tristan $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

ui_step 4 "Computing SHA256 checksum"
( cd dist && shasum -a 256 "Tristan-$VERSION.dmg" > "Tristan-$VERSION.dmg.sha256" )
ui_success "Created $DMG"
cat "dist/Tristan-$VERSION.dmg.sha256"
ui_footer
