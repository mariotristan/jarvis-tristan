#!/bin/bash
# Records a video of the live app on the DEMO provider (no accounts or agent needed), cropped to the Tristan window
# so nothing else on your screen ends up in the file. Output: docs/demo/tristan-demo.mp4
#   scripts/record-demo.sh                 records until the autopilot finishes (about 65 seconds, 75 at most)
#   SECONDS_TO_RECORD=120 scripts/record-demo.sh
#   DEMO_MODE=ask scripts/record-demo.sh   open in ask or auto instead of yolo (the default)
#   scripts/record-demo.sh kids            the kids video: Paw Patrol theme, kids safe mode, school questions
#                                          (docs/demo/tristan-demo-kids.mp4)
#   MANUAL=1 scripts/record-demo.sh        no autopilot: you drive the app yourself while it records
#   TRIM_START=4 TRIM_END=3 scripts/record-demo.sh   cut seconds off the start and the end
# Needs Screen Recording permission for your terminal (System Settings > Privacy & Security > Screen & System Audio
# Recording), Xcode (for the build) and ffmpeg (brew install ffmpeg).
# Do not move or resize the window while recording: the crop is fixed from where it opens. The screen is still filmed
# in full before the crop, and the uncropped .mov is deleted afterwards (KEEP_RAW=1 keeps it).
# `Tristan --demo` opens in the chosen approval mode (yolo by default) with kids mode off, and keeps the demo parent PIN
# in its own Keychain slot. Your real approval mode, kids mode and wake word settings are put back when the demo exits.
# Note: turning kids mode on during the demo locks the mode back to ASK, as it does in the real app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
SECS="${SECONDS_TO_RECORD:-75}"
TRIM_START="${TRIM_START:-0}"
TRIM_END="${TRIM_END:-0}"
KIDS=""; NAME=tristan-demo; MODE="${DEMO_MODE:-yolo}"
[ "${1:-}" = kids ] && { KIDS=--kids; NAME=tristan-demo-kids; MODE=ask; }
OUT=docs/demo
RAW="$OUT/$NAME-raw.mov"
LOG=$(mktemp)
mkdir -p "$OUT"
# screencapture cannot overwrite a file, and a leftover would be converted as if it were new.
rm -f "$RAW" "$OUT/$NAME.mp4"

swift build >/dev/null
.build/debug/Tristan --demo "$MODE" ${KIDS} ${MANUAL:+--manual} > "$LOG" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null || true; rm -f "$LOG"' EXIT

for _ in $(seq 1 50); do grep -q '^DEMO_WINDOW' "$LOG" && break; sleep 0.2; done
read -r _ WX WY WW WH SW SH < <(grep -m1 '^DEMO_WINDOW' "$LOG") || { echo "Tristan did not report its window. Log:"; cat "$LOG"; exit 1; }

if [ -n "${MANUAL:-}" ]; then
cat <<'TXT'

Recording starts in 5 seconds. Suggested run (about 75 seconds):
  1. Click the Tristan window, type "write a README for this folder" and press Return. Watch the big orb.
  2. While it answers, press ⌥⇧ Space: nothing starts (the mic is shut while Tristan responds).
  3. Gear > ORB WHILE WAITING: switch "ORB FILLS THE WHOLE SCREEN" on and send another task.
  4. Gear > KIDS SAFE MODE: set a PIN, switch it on, close Settings, click the gear: the parent unlock appears.
Keep the window where it is.
TXT
else
echo "Recording starts in 5 seconds and the demo plays by itself (about 65 seconds). Keep the window where it is."
fi
for i in 5 4 3 2 1; do printf "%s " "$i"; sleep 1; done; echo "recording"

# A background job in a script ignores SIGINT, so reset it first or the early stop below would do nothing.
python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
  screencapture -v -V "$SECS" "$RAW" &
REC=$!
if [ -z "${MANUAL:-}" ]; then
  # Stop as soon as the autopilot is done (a few seconds of tail), or at the time limit.
  for _ in $(seq 1 $((SECS * 5))); do grep -q '^DEMO_DONE' "$LOG" && break; sleep 0.2; done
  sleep 2
  kill -INT "$REC" 2>/dev/null || true
fi
wait "$REC" || true
[ -s "$RAW" ] || { echo "Nothing was recorded (is Screen Recording allowed for this terminal?). Nothing to convert."; exit 1; }

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
  -c:v libx264 -crf 22 -preset slow -pix_fmt yuv420p -movflags +faststart "$OUT/$NAME.mp4"
[ "${KEEP_RAW:-0}" = 1 ] || rm -f "$RAW"
echo "Done: $OUT/$NAME.mp4  ($(du -h "$OUT/$NAME.mp4" | cut -f1), cropped $CROP)"
