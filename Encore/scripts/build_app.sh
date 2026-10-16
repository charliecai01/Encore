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

# EncoreCore's SwiftPM resource bundle (curated CJK artist-name data,
# Sources/EncoreCore/Resources) — NativeNames.swift fatal-errors via
# NSBundle.module if this isn't next to the executable.
for bundle in .build/release/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

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
    <string>1.0.3</string>
    <key>CFBundleVersion</key>
    <string>1.0.3</string>
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

# Siri / Shortcuts ("Play my favorites in Encore"): the system registers App
# Shortcuts from Metadata.appintents inside the bundle. Xcode generates it
# for the iOS app (its ExtractAppIntentsMetadata step); SwiftPM doesn't, so
# this does the same by hand:
#  1. type-check macOS/EncoreIntents.swift — every AppIntents type lives
#     there — with const-value extraction on (SwiftPM's build rejects the
#     flag, hence a separate ~10s pass),
#  2. run appintentsmetadataprocessor on the result. It only extracts when
#     the linker's dependency-info file lists AppIntents.framework; SwiftPM
#     doesn't write one, so a minimal one is synthesized (the binary does
#     link AppIntents — `otool -L` shows it).
# Needs full Xcode (the processor isn't in the Command Line Tools). Best-
# effort: without the metadata the app still works, Siri just doesn't know
# the phrases.
emit_appintents_metadata() {
    local work=".build/appintents"
    local sdk swiftc processor xcode_build
    sdk=$(xcrun --sdk macosx --show-sdk-path) || return 1
    swiftc=$(xcrun -f swiftc) || return 1
    processor=$(xcrun -f appintentsmetadataprocessor 2>/dev/null) || return 1
    xcode_build=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')
    rm -rf "$work"; mkdir -p "$work"
    # The protocol list Xcode 27 passes for the same step.
    echo '["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]' > "$work/protocols.json"
    "$swiftc" -frontend -typecheck -module-name Encore -sdk "$sdk" \
        -target "$(uname -m)-apple-macos15.0" -swift-version 5 -I .build/release \
        -primary-file macOS/EncoreIntents.swift $(ls macOS/*.swift | grep -v '/EncoreIntents.swift$') \
        -emit-const-values-path "$work/EncoreIntents.swiftconstvalues" \
        -const-gather-protocols-file "$work/protocols.json" || return 1
    echo "$PWD/$work/EncoreIntents.swiftconstvalues" > "$work/constvals.list"
    ls "$PWD"/macOS/*.swift > "$work/sources.list"
    : > "$work/metadata.list"; : > "$work/static-metadata.list"
    printf '\0ld\n\0\020%s\0\100%s\0' \
        "$sdk/System/Library/Frameworks/AppIntents.framework/AppIntents.tbd" \
        "$PWD/$APP/Contents/MacOS/Encore" > "$work/dependency_info.dat"
    "$processor" --toolchain-dir "$(dirname "$(dirname "$(dirname "$swiftc")")")" \
        --module-name Encore --sdk-root "$sdk" --xcode-version "${xcode_build:-unknown}" \
        --platform-family macOS --deployment-target 15.0 \
        --bundle-identifier dev.charlie.encore --target-triple "$(uname -m)-apple-macos15.0" \
        --output "$APP/Contents/Resources" --binary-file "$APP/Contents/MacOS/Encore" \
        --dependency-file "$work/dependency_info.dat" \
        --stringsdata-file "$work/ExtractedAppShortcutsMetadata.stringsdata" \
        --source-file-list "$work/sources.list" --metadata-file-list "$work/metadata.list" \
        --static-metadata-file-list "$work/static-metadata.list" \
        --swift-const-vals-list "$work/constvals.list" \
        --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization \
        2>&1 | grep -E 'error|warning' || true
    [ -d "$APP/Contents/Resources/Metadata.appintents" ]
}
if emit_appintents_metadata; then
    echo "App Intents metadata: OK"
else
    echo "warning: App Intents metadata NOT generated — Siri phrases won't register"
fi

# Ad-hoc signing (--sign -) gives every rebuild a throwaway identity with no
# Team ID, which breaks TCC-gated APIs that key permission off a stable
# signing identity (e.g. per-app audio capture/routing tools using macOS
# 14.4's Core Audio process tap — they silently omit ad-hoc-signed apps).
# Prefer a real installed identity so Encore has a consistent identity across
# builds; fall back to ad-hoc if none is available (e.g. a fresh machine).
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -oE '"[^"]+"' | tr -d '"')
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP (signed: ${SIGN_ID:-ad-hoc})"

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
