#!/bin/bash
# Pull the iPhone's recent unified log after an in-car Bluetooth/Tesla cover-art
# test and split out the lines that matter (HANDOFF §5, "Bluetooth/car cover art").
#
#   scripts/car_capture.sh [minutes]     # default 40; phone on USB, unlocked
#
# Needs root (`log collect` from an attached device) — you'll get a sudo prompt.
# Output: ~/Desktop/encore-car-<time>/
#   nowplaying.txt  mediaremoted "nowPlayingItem" lines: client, item id,
#                   artworkAvailable, artworkIdentifier (what the system holds)
#   encore.txt      Encore's own log (player category): "nowplaying:", "meta:",
#                   toggles in effect (car=...), hijack/stall/error lines
#   bluetooth.txt   bluetoothd / MediaRemoteUI lines mentioning AVRCP / cover art
#                   (device-discovery noise filtered out; empty without a car)
#   device.logarchive   the full archive, for anything missed
set -euo pipefail

MINUTES="${1:-40}"
UDID="${ENCORE_DEVICE_ID:-00008160-000179D436A0000A}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/Desktop/encore-car-$STAMP"
ARCHIVE="$OUT/device.logarchive"
LOG=/usr/bin/log   # zsh/other shells can shadow `log`

mkdir -p "$OUT"
echo "Collecting last ${MINUTES}m from $UDID (sudo)…"
sudo "$LOG" collect --device-udid "$UDID" --last "${MINUTES}m" --output "$ARCHIVE"
sudo chown -R "$(id -u):$(id -g)" "$OUT"

show() { # predicate, outfile
  "$LOG" show --archive "$ARCHIVE" --style compact --info --debug --predicate "$1" > "$2" 2>/dev/null || true
}

show 'process == "mediaremoted" AND composedMessage CONTAINS "nowPlayingItem"' "$OUT/nowplaying.txt"
show 'subsystem == "dev.charlie.encore"' "$OUT/encore.txt"
show '(process == "bluetoothd" OR process == "MediaRemoteUI") AND (composedMessage CONTAINS[c] "avrcp" OR composedMessage CONTAINS[c] "cover art" OR composedMessage CONTAINS[c] "coverart" OR composedMessage CONTAINS[c] "artwork" OR composedMessage CONTAINS[c] "GetElementAttr" OR composedMessage CONTAINS[c] "element attr") AND NOT composedMessage CONTAINS "CBDevice" AND NOT composedMessage CONTAINS "CBDiscovery" AND NOT composedMessage CONTAINS "GetControllerInfo" AND NOT composedMessage CONTAINS "AuLQ"' "$OUT/bluetooth.txt"

echo
echo "Saved to $OUT"
wc -l "$OUT"/*.txt | sed 's|'"$OUT"'/||'
echo
echo "── Encore: native Now Playing writes (id / art / toggles) ──"
grep -h "nowplaying:" "$OUT/encore.txt" | tail -40 || true
echo
echo "── Encore: page meta (art=loaded|failed|timeout) ──"
grep -h "meta:" "$OUT/encore.txt" | tail -20 || true
