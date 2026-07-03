#!/bin/bash
# Builds Encore.app from the SwiftPM package (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

# If the active toolchain is unusable (e.g. Xcode installed but its license
# not yet accepted), fall back to the Command Line Tools.
if ! swift -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

swift build -c release

APP="build/Encore.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Encore "$APP/Contents/MacOS/Encore"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Encore</string>
    <key>CFBundleIdentifier</key>
    <string>dev.charlie.encore</string>
    <key>CFBundleName</key>
    <string>Encore</string>
    <key>CFBundleDisplayName</key>
    <string>Encore</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

if [ -f assets/AppIcon.icns ]; then
    cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP"
echo "Built $APP"

# Keep the installed copy in /Applications up to date.
if [ -d "/Applications/Encore.app" ] || [ -w "/Applications" ]; then
    WAS_RUNNING=0
    pgrep -f "/Applications/Encore.app/Contents/MacOS/Encore" >/dev/null && WAS_RUNNING=1
    pkill -f "/Applications/Encore.app/Contents/MacOS/Encore" 2>/dev/null || true
    # Wait for the old instance to fully exit before replacing and relaunching —
    # `open` too early fails with Launch Services error -600 and the relaunch
    # silently doesn't happen, leaving the OLD binary running.
    for _ in $(seq 1 50); do
        pgrep -f "/Applications/Encore.app/Contents/MacOS/Encore" >/dev/null || break
        sleep 0.1
    done
    rm -rf /Applications/Encore.app
    ditto "$APP" /Applications/Encore.app
    echo "Installed /Applications/Encore.app"
    if [ "$WAS_RUNNING" = "1" ]; then
        open /Applications/Encore.app || { sleep 1; open /Applications/Encore.app; }
    fi
fi
