#!/bin/bash
# Runs the iOS app in a simulator against a demo Tristan on this Mac (no real agent, no accounts needed).
#   scripts/ios-demo.sh            iPhone simulator; the app pairs and starts a demo mission
#   SIM="iPad Pro 11-inch (M4)" scripts/ios-demo.sh
#   MODE=standalone scripts/ios-demo.sh   the on-device mode with a scripted "model" (no Mac side, no accounts)
# Needs Xcode. The Mac side is `Tristan --remote-demo`, which prints a pairing link for 127.0.0.1.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
SIM_NAME="${SIM:-iPhone 16 Pro}"

swift build >/dev/null
(cd ios && xcodebuild build -project TristanIOS.xcodeproj -scheme TristanIOS -destination 'generic/platform=iOS Simulator' \
   -derivedDataPath build -quiet)

SIM_ID=$(xcrun simctl list devices available | grep -m1 "$SIM_NAME (" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
[ -n "$SIM_ID" ] || { echo "No simulator named '$SIM_NAME'. See: xcrun simctl list devices available"; exit 1; }

if [ "${MODE:-remote}" = "standalone" ]; then
  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  open -a Simulator
  xcrun simctl bootstatus "$SIM_ID" -b >/dev/null
  xcrun simctl install "$SIM_ID" ios/build/Build/Products/Debug-iphonesimulator/Tristan.app
  xcrun simctl launch "$SIM_ID" com.tristan.ios -tristanStandaloneDemo YES -tristanAutoSubmit "add a login function to the API" >/dev/null
  echo "Running the standalone demo. Approve the write on the simulator."
  exit 0
fi

LOG=$(mktemp)
.build/debug/Tristan --remote-demo > "$LOG" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -f "$LOG"' EXIT
for _ in $(seq 1 50); do grep -q '^PAIR ' "$LOG" && break; sleep 0.2; done
LINK=$(grep '^PAIR ' "$LOG" | sed 's/^PAIR //')

xcrun simctl boot "$SIM_ID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$SIM_ID" -b >/dev/null
xcrun simctl install "$SIM_ID" ios/build/Build/Products/Debug-iphonesimulator/Tristan.app
xcrun simctl launch "$SIM_ID" com.tristan.ios -tristanPairURL "$LINK" -tristanAutoSubmit "write a login function for the API" >/dev/null
echo "Running. Approve the action on the simulator. Press Ctrl+C to stop the demo Mac."
wait $SERVER
