#!/bin/bash
# Builds Tristan.app and wraps it in a drag-to-Applications disk image: dist/Tristan-<version>.dmg (+ .sha256).
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"

scripts/bundle.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R Tristan.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Tristan-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Tristan $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
( cd dist && shasum -a 256 "Tristan-$VERSION.dmg" > "Tristan-$VERSION.dmg.sha256" )
echo "Created $DMG"
cat "dist/Tristan-$VERSION.dmg.sha256"
