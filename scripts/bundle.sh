#!/bin/bash
# Builds the Swift package and wraps the binary into Tristan.app (menu-bar/notch app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftUI macros need the full Xcode toolchain, even if xcode-select points at Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
swift build -c release
APP=Tristan.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Tristan "$APP/Contents/MacOS/Tristan"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tristan</string>
  <key>CFBundleIdentifier</key><string>com.tristan.app</string>
  <key>CFBundleExecutable</key><string>Tristan</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Tristan listens for voice commands.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Tristan turns your voice into tasks.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
