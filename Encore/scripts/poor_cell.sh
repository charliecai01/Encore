#!/bin/bash
# Shape this Mac's network down to "bad cellular" so the iOS SIMULATOR hits the
# weak-signal paths (StallPolicy, the stall watchdog, InnerTube retries).
#
#   sudo Encore/scripts/poor_cell.sh on     # ~256 Kbit/s, 400ms delay, 6% loss
#   sudo Encore/scripts/poor_cell.sh off    # restore
#
# WARNING: dummynet shapes ALL traffic on this Mac, not just the simulator —
# the simulator shares the host network stack, so there is no way to scope it
# to the app. Everything else on the machine gets slow while it is on. Turn it
# off when you're done.
#
# To condition a REAL iPhone instead (only affects the phone, and is closer to
# the real thing), use the on-device tool: Settings -> Developer -> Network
# Link Conditioner. No Mac-wide side effects.
set -euo pipefail

BW="${ENCORE_BW:-256Kbit/s}"
DELAY="${ENCORE_DELAY:-400}"     # ms, each direction
LOSS="${ENCORE_LOSS:-0.06}"      # packet loss rate, 0-1

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root: sudo $0 $*" >&2
    exit 1
fi

case "${1:-}" in
on)
    dnctl pipe 1 config bw "$BW" delay "$DELAY" plr "$LOSS"
    printf 'dummynet in all pipe 1\ndummynet out all pipe 1\n' | pfctl -f - -E 2>/dev/null
    echo "poor cell ON — bw=$BW delay=${DELAY}ms loss=$LOSS (ALL Mac traffic)"
    echo "turn it off with: sudo $0 off"
    ;;
off)
    pfctl -f /etc/pf.conf 2>/dev/null || true
    pfctl -d 2>/dev/null || true
    dnctl -q flush 2>/dev/null || true
    echo "poor cell OFF — network restored"
    ;;
*)
    echo "usage: sudo $0 on|off" >&2
    exit 1
    ;;
esac
