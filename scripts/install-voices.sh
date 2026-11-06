#!/bin/bash
# Helps you get a better speech voice for T.R.I.S.T.A.N. The built-in voices are "compact" (22 kHz) and can sound
# crackly. macOS has no supported command to download voices, so this script opens the right Settings pane, waits
# until an Enhanced or Premium voice is installed, then plays a sample. T.R.I.S.T.A.N. picks the best voice by itself.
#
#   scripts/install-voices.sh            # British English (the default voice, Daniel)
#   scripts/install-voices.sh en_US      # another language, for example for Kids safe mode
#   scripts/install-voices.sh --check    # only report what is installed
set -euo pipefail

CHECK=0
LOCALE="en_GB"
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) LOCALE="$arg" ;;
  esac
done

# Voices that are not compact show "(Enhanced)" or "(Premium)" in the name.
good_voices() { say -v '?' | grep -E "\(Enhanced\)|\(Premium\)" | grep -E "[[:space:]]${LOCALE}[[:space:]]" || true; }

report() {
  echo "Installed voices for ${LOCALE}:"
  say -v '?' | grep -E "[[:space:]]${LOCALE}[[:space:]]" | sed 's/#.*//' | sed 's/^/  /'
}

found="$(good_voices)"
if [ -n "$found" ]; then
  echo "Good news: a higher quality voice is already installed for ${LOCALE}:"
  echo "$found" | sed 's/#.*//' | sed 's/^/  /'
  exit 0
fi

report
echo
echo "No Enhanced or Premium voice for ${LOCALE} yet (only the compact ones, which can crackle)."
[ "$CHECK" = 1 ] && exit 1

cat <<'TXT'

In the window that opens:
  1. Go to Spoken Content > System Voice > Manage Voices (the "i" button).
  2. Pick the language (English (United Kingdom) for the default voice).
  3. Download "Daniel (Enhanced)" or any Premium voice (the cloud icon).
This script keeps watching and tells you when it is ready. Press Ctrl+C to stop.
TXT

open "x-apple.systempreferences:com.apple.Accessibility-Settings.extension" 2>/dev/null || open "/System/Applications/System Settings.app"

for _ in $(seq 1 360); do   # up to 30 minutes
  found="$(good_voices)"
  if [ -n "$found" ]; then
    name="$(echo "$found" | head -1 | sed -E 's/[[:space:]]+[a-z]{2}_[A-Z]{2}[[:space:]].*//')"
    echo
    echo "Installed: ${name}. Playing a sample..."
    say -v "$name" "Good evening, sir. All systems are operational."
    echo "Restart T.R.I.S.T.A.N. and it will use this voice."
    exit 0
  fi
  sleep 5
done
echo "Timed out waiting for a voice. Run this script again after downloading one."
exit 1
