#!/bin/bash
# Records a screen video of the live app (demo provider, so no accounts or agent needed) and makes a shareable MP4.
#   scripts/record-demo.sh            records 75 seconds
#   SECONDS_TO_RECORD=120 scripts/record-demo.sh
# Needs Screen Recording permission for your terminal (System Settings > Privacy & Security > Screen & System Audio
# Recording), Xcode (for the build) and ffmpeg (brew install ffmpeg). It films the whole main display, so close
# anything private first. Output: docs/demo/tristan-demo.mp4
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
SECS="${SECONDS_TO_RECORD:-75}"
OUT=docs/demo
mkdir -p "$OUT"

swift build >/dev/null
.build/debug/Tristan &
APP=$!
trap 'kill $APP 2>/dev/null || true' EXIT
sleep 2

cat <<'TXT'

Recording starts in 5 seconds. Suggested run (about 75 seconds):
  1. Press ⌥ Space to open Tristan. Type "write a README for this folder" and press Return.
     Watch the big orb, rings and sparks while it works. Approve the prompt.
  2. While it answers, press ⌥⇧ Space: nothing starts, the mic shows slashed (mic is shut while Tristan responds).
  3. Open the gear > ORB WHILE WAITING: change size and effects, switch "ORB FILLS THE WHOLE SCREEN" on and send another task.
  4. Gear > KIDS SAFE MODE: pick PIN, set one, switch it on. Close Settings, click the gear again: the parent unlock appears.
     Enter the PIN to get in; switch kids mode off again.
TXT
for i in 5 4 3 2 1; do printf "%s " "$i"; sleep 1; done; echo "recording"

screencapture -v -V "$SECS" "$OUT/tristan-demo.mov"
ffmpeg -y -loglevel error -i "$OUT/tristan-demo.mov" -vf "scale='min(1920,iw)':-2" -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart "$OUT/tristan-demo.mp4"
echo "Done: $OUT/tristan-demo.mp4  ($(du -h "$OUT/tristan-demo.mp4" | cut -f1))"
