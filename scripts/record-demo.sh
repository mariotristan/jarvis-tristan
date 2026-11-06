#!/bin/bash
# Records a video of the live app on the DEMO provider (no accounts or agent needed), cropped to the Tristan window
# so nothing else on your screen ends up in the file. Output: docs/demo/tristan-demo.mp4
#   scripts/record-demo.sh                 records 75 seconds
#   SECONDS_TO_RECORD=120 scripts/record-demo.sh
#   TRIM_START=4 TRIM_END=3 scripts/record-demo.sh   cut seconds off the start and the end
# Needs Screen Recording permission for your terminal (System Settings > Privacy & Security > Screen & System Audio
# Recording), Xcode (for the build) and ffmpeg (brew install ffmpeg).
# Do not move or resize the window while recording: the crop is fixed from where it opens. The screen is still filmed
# in full before the crop, and the uncropped .mov is deleted afterwards (KEEP_RAW=1 keeps it).
# `Tristan --demo` resets the approval mode to ASK and kids mode to off, and keeps the demo parent PIN in its own
# Keychain slot, so a real PIN is never replaced.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
SECS="${SECONDS_TO_RECORD:-75}"
TRIM_START="${TRIM_START:-0}"
TRIM_END="${TRIM_END:-0}"
OUT=docs/demo
RAW="$OUT/tristan-demo-raw.mov"
LOG=$(mktemp)
mkdir -p "$OUT"

swift build >/dev/null
.build/debug/Tristan --demo > "$LOG" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null || true; rm -f "$LOG"' EXIT

for _ in $(seq 1 50); do grep -q '^DEMO_WINDOW' "$LOG" && break; sleep 0.2; done
read -r _ WX WY WW WH SW SH < <(grep -m1 '^DEMO_WINDOW' "$LOG") || { echo "Tristan did not report its window. Log:"; cat "$LOG"; exit 1; }

cat <<'TXT'

Recording starts in 5 seconds. Tristan is on the DEMO provider. Suggested run (about 75 seconds):
  1. Click the Tristan window, type "write a README for this folder" and press Return.
     Watch the big orb, rings and sparks while it works. Approve the prompt.
  2. While it answers, press ⌥⇧ Space: nothing starts, the mic shows slashed (mic is shut while Tristan responds).
  3. Open the gear > ORB WHILE WAITING: change size and effects, switch "ORB FILLS THE WHOLE SCREEN" on and send another task.
  4. Gear > KIDS SAFE MODE: pick PIN, set one, switch it on. Close Settings, click the gear again: the parent unlock appears.
     Enter the PIN to get in; switch kids mode off again.
Keep the window where it is.
TXT
for i in 5 4 3 2 1; do printf "%s " "$i"; sleep 1; done; echo "recording"

screencapture -v -V "$SECS" "$RAW"

# Crop to the window plus a small margin, converting screen points to video pixels.
VW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$RAW")
VH=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$RAW")
CROP=$(python3 - "$WX" "$WY" "$WW" "$WH" "$SW" "$SH" "$VW" "$VH" <<'PY'
import sys
wx, wy, ww, wh, sw, sh, vw, vh = map(float, sys.argv[1:])
sx, sy, m = vw / sw, vh / sh, 4
x, y = max(0, wx - m), max(0, wy - m)
w, h = min(vw / sx, ww + 2 * m), min(vh / sy, wh + 2 * m)
even = lambda v: int(v // 2) * 2
print(f"{even(w * sx)}:{even(h * sy)}:{even(x * sx)}:{even(y * sy)}")
PY
)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW")
LEN=$(python3 -c "print(max(1, float('$DUR') - $TRIM_START - $TRIM_END))")
ffmpeg -y -loglevel error -ss "$TRIM_START" -t "$LEN" -i "$RAW" -vf "crop=$CROP" \
  -c:v libx264 -crf 22 -preset slow -pix_fmt yuv420p -movflags +faststart "$OUT/tristan-demo.mp4"
[ "${KEEP_RAW:-0}" = 1 ] || rm -f "$RAW"
echo "Done: $OUT/tristan-demo.mp4  ($(du -h "$OUT/tristan-demo.mp4" | cut -f1), cropped $CROP)"
