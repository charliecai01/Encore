#!/bin/bash
# Builds EncoreiOS for Charlie's iPhone and installs it — the iOS counterpart of
# build_app.sh. Requires a paired, unlocked device and an Apple ID signed into
# Xcode (Settings → Accounts). Free-account signing expires after ~7 days, so
# rerun about weekly; the first launch after install may need a trust prompt
# under Settings → General → VPN & Device Management.
set -euo pipefail
cd "$(dirname "$0")/../iOS"

# Device builds need the full Xcode toolchain, not just the Command Line Tools.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Defaults match Charlie's setup; override via env if the device or team changes.
# Find the device id with: xcrun devicectl list devices
DEVICE_ID="${ENCORE_DEVICE_ID:-5A20AF61-E66A-5BE7-AA6C-5C7AFAB438A7}"
TEAM_ID="${ENCORE_TEAM_ID:-9272YGK74X}"

build() {
    xcodebuild -project EncoreiOS.xcodeproj -scheme EncoreiOS \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -derivedDataPath .build_device -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" build
}

echo "Building EncoreiOS for device $DEVICE_ID…"
# The developer disk image sometimes fails to mount right after the phone
# connects — unlock it and retry once.
if ! build; then
    echo "Build failed (often a transient disk-image mount) — unlock the phone; retrying in 5s…"
    sleep 5
    build
fi

APP=".build_device/Build/Products/Debug-iphoneos/EncoreiOS.app"
echo "Installing $APP …"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "Installed EncoreiOS to your iPhone."
