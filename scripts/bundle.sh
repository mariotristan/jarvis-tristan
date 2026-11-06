#!/bin/bash
# Builds the Swift package and wraps the binary into Tristan.app (menu-bar/notch app, no Dock icon).
# VERSION comes from the VERSION env var, else the VERSION file. Output: ./Tristan.app
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftUI macros need the full Xcode toolchain, even if xcode-select points at Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi

VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 0.0.0)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release
APP=Tristan.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tristan "$APP/Contents/MacOS/Tristan"
# The app runs this to start Ollama when the internet is down.
cp scripts/setup-ollama.sh "$APP/Contents/Resources/setup-ollama.sh"

# App icon: render the reactor, then build an .icns from it. Never fails the build.
ICON_DIR=.build/icon
rm -rf "$ICON_DIR" && mkdir -p "$ICON_DIR/AppIcon.iconset"
if .build/release/Tristan --make-icon "$ICON_DIR/icon.png" >/dev/null 2>&1 && [ -f "$ICON_DIR/icon.png" ]; then
  for size in 16 32 64 128 256 512 1024; do
    sips -z $size $size "$ICON_DIR/icon.png" --out "$ICON_DIR/s$size.png" >/dev/null
  done
  cp "$ICON_DIR/s16.png"   "$ICON_DIR/AppIcon.iconset/icon_16x16.png"
  cp "$ICON_DIR/s32.png"   "$ICON_DIR/AppIcon.iconset/icon_16x16@2x.png"
  cp "$ICON_DIR/s32.png"   "$ICON_DIR/AppIcon.iconset/icon_32x32.png"
  cp "$ICON_DIR/s64.png"   "$ICON_DIR/AppIcon.iconset/icon_32x32@2x.png"
  cp "$ICON_DIR/s128.png"  "$ICON_DIR/AppIcon.iconset/icon_128x128.png"
  cp "$ICON_DIR/s256.png"  "$ICON_DIR/AppIcon.iconset/icon_128x128@2x.png"
  cp "$ICON_DIR/s256.png"  "$ICON_DIR/AppIcon.iconset/icon_256x256.png"
  cp "$ICON_DIR/s512.png"  "$ICON_DIR/AppIcon.iconset/icon_256x256@2x.png"
  cp "$ICON_DIR/s512.png"  "$ICON_DIR/AppIcon.iconset/icon_512x512.png"
  cp "$ICON_DIR/s1024.png" "$ICON_DIR/AppIcon.iconset/icon_512x512@2x.png"
  iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || echo "warning: could not build AppIcon.icns"
else
  echo "warning: could not render the app icon; continuing without one"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tristan</string>
  <key>CFBundleDisplayName</key><string>Tristan</string>
  <key>CFBundleIdentifier</key><string>com.tristan.app</string>
  <key>CFBundleExecutable</key><string>Tristan</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSAppleEventsUsageDescription</key><string>Tristan controls Spotify so you can play music while you work.</string>
  <key>NSMicrophoneUsageDescription</key><string>Tristan listens for voice commands.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Tristan turns your voice into tasks.</string>
</dict></plist>
PLIST

# Ad-hoc signature (no developer identity needed). The app is not notarized; see the README for first launch.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "Built $APP (version $VERSION, build $BUILD)"
