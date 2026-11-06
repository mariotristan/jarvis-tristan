#!/bin/bash
# Records a video of the live app on the DEMO provider (no accounts or agent needed): just the Tristan window and the
# app's own sound (effects and voice), so nothing else on your screen or from other apps ends up in the file.
# Output: docs/demo/tristan-demo.mp4
#   scripts/record-demo.sh                 records for 75 seconds, then trims the video to just after the demo finishes
#   SECONDS_TO_RECORD=120 scripts/record-demo.sh
#   DEMO_MODE=ask scripts/record-demo.sh   open in ask or auto instead of yolo (the default)
#   scripts/record-demo.sh kids            the kids video: Paw Patrol theme, kids safe mode, school questions
#                                          (docs/demo/tristan-demo-kids.mp4)
#   MANUAL=1 scripts/record-demo.sh        no autopilot: you drive the app yourself while it records
#   TRIM_START=4 TRIM_END=3 scripts/record-demo.sh   cut seconds off the start and the end
# Needs Screen & System Audio Recording permission for your terminal (System Settings > Privacy & Security), Xcode (for
# the build) and ffmpeg (brew install ffmpeg).
# The window is followed wherever it is (it can even be covered), but do not resize it while recording. The raw capture
# is deleted afterwards (KEEP_RAW=1 keeps it). The demo switches SOUND FX and VOICE FEEDBACK on so the video has sound,
# and puts your settings back when it ends.
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
RAW="$OUT/$NAME-raw.mp4"
LOG=$(mktemp)
mkdir -p "$OUT"
# A leftover would be converted as if it were new.
rm -f "$RAW" "$OUT/$NAME.mp4"

swift build >/dev/null
# The recorder films the window and captures the app's audio in one file (see scripts/record-window.swift).
if [ ! -x .build/record-window ] || [ scripts/record-window.swift -nt .build/record-window ]; then
  swiftc -O scripts/record-window.swift -o .build/record-window
fi
.build/debug/Tristan --demo "$MODE" ${KIDS} ${MANUAL:+--manual} ${MANUAL:---wait-start} > "$LOG" 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null || true; rm -f "$LOG"' EXIT

for _ in $(seq 1 50); do grep -q '^DEMO_WINDOW' "$LOG" && break; sleep 0.2; done
grep -q '^DEMO_WINDOW' "$LOG" || { echo "Tristan did not report its window. Log:"; cat "$LOG"; exit 1; }

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

# The recorder stops at its time limit, or earlier when the autopilot is done (below).
RECLOG=$(mktemp)
.build/record-window "$RAW" "$SECS" "$APP" > "$RECLOG" 2>&1 &
REC=$!
for _ in $(seq 1 100); do grep -q '^RECORDING' "$RECLOG" && break; kill -0 "$REC" 2>/dev/null || break; sleep 0.2; done
grep -q '^RECORDING' "$RECLOG" || { echo "Could not start recording. Is Screen Recording allowed for this terminal?"; cat "$RECLOG"; rm -f "$RECLOG"; exit 1; }
# The demo waits for this signal, so the video starts at its very beginning.
[ -z "${MANUAL:-}" ] && kill -USR1 "$APP"
if [ -z "${MANUAL:-}" ]; then
  for _ in $(seq 1 $((SECS * 5))); do grep -q '^DEMO_DONE' "$LOG" && break; sleep 0.2; done
  # Let the last sound ring out, then stop the recorder cleanly so the file is finalised.
  grep -q '^DEMO_DONE' "$LOG" && { sleep 3; kill -INT "$REC" 2>/dev/null || true; }
fi
wait "$REC" || true
[ -s "$RAW" ] || { echo "Nothing was recorded. Recorder said:"; cat "$RECLOG"; rm -f "$RECLOG"; exit 1; }
grep -E "AUDIO_TIMING|RECORDED" "$RECLOG" || true; rm -f "$RECLOG"

DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW")
LEN=$(python3 -c "print(max(1, float('$DUR') - $TRIM_START - $TRIM_END))")
ffmpeg -y -loglevel error -ss "$TRIM_START" -t "$LEN" -i "$RAW" \
  -c:v libx264 -crf 22 -preset slow -pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart "$OUT/$NAME.mp4"
[ "${KEEP_RAW:-0}" = 1 ] || rm -f "$RAW"
AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$OUT/$NAME.mp4" | head -1)
echo "Done: $OUT/$NAME.mp4  ($(du -h "$OUT/$NAME.mp4" | cut -f1), audio: ${AUDIO:-NONE})"
