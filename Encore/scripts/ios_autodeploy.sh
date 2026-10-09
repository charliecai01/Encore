#!/bin/bash
# Keeps the free-account-signed EncoreiOS from expiring by re-running
# deploy_ios.sh every 3 days from a launchd agent.
#
#   ios_autodeploy.sh install    # install + load the LaunchAgent (checks hourly)
#   ios_autodeploy.sh uninstall  # unload + remove it
#   ios_autodeploy.sh status     # last success + agent state
#   ios_autodeploy.sh run        # what launchd calls; deploys only if ≥3 days since last success
#   ios_autodeploy.sh now        # deploy immediately regardless of the 3-day gate
#
# The agent wakes hourly (and on load / after sleep) but only deploys once the
# last *successful* deploy is ≥3 days old. Deploying needs the phone unlocked
# and on the same Wi-Fi, so a failed attempt just retries next hour until it
# lands — leaving 4 days of slack before the 7-day signing expiry. It runs
# silently (no macOS notifications either way); check `status` or the log.
#
# Free provisioning profiles last 7 days from *creation*, and Xcode reuses the
# cached one until it expires — reinstalling with it doesn't extend anything.
# So each deploy deletes the cached Encore profile first, forcing
# -allowProvisioningUpdates to mint a fresh 7-day one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="dev.charlie.encore.ios-autodeploy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/encore-ios-autodeploy.log"
STATE_DIR="$HOME/Library/Application Support/dev.charlie.encore"
STAMP="$STATE_DIR/ios-autodeploy-last-success"
LOCK="$STATE_DIR/ios-autodeploy.lock"
BUNDLE_ID="dev.charlie.encore.ios"
MIN_AGE_SECS=$((3 * 24 * 3600))
INTERVAL_SECS=3600

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Remove cached provisioning profiles for the Encore bundle id so the next
# build fetches a fresh one (Xcode 16+ stores them under UserData; older
# Xcodes under MobileDevice).
drop_cached_profiles() {
    local dir p
    for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
               "$HOME/Library/MobileDevice/Provisioning Profiles"; do
        [ -d "$dir" ] || continue
        for p in "$dir"/*.mobileprovision; do
            [ -f "$p" ] || continue
            if /usr/bin/security cms -D -i "$p" 2>/dev/null | grep -q "\.$BUNDLE_ID<"; then
                echo "Removing cached profile $(basename "$p")"
                rm -f "$p"
            fi
        done
    done
}

last_success() { [ -f "$STAMP" ] && cat "$STAMP" || echo 0; }

deploy() {
    mkdir -p "$STATE_DIR"
    # One deploy at a time (a slow build can outlast a launchd tick).
    if ! mkdir "$LOCK" 2>/dev/null; then
        echo "Another deploy is in progress — skipping."
        return 0
    fi
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT

    echo "=== $(date) — deploying EncoreiOS"
    drop_cached_profiles
    if "$SCRIPT_DIR/deploy_ios.sh"; then
        date +%s > "$STAMP"
        echo "=== $(date) — success"
    else
        echo "=== $(date) — FAILED (will retry in ~1h)"
        return 1
    fi
}

case "${1:-run}" in
    run)
        age=$(( $(date +%s) - $(last_success) ))
        if [ "$age" -lt "$MIN_AGE_SECS" ]; then
            echo "$(date) — last deploy $((age / 3600))h ago; next due at 72h. Nothing to do."
            exit 0
        fi
        deploy
        ;;
    now)
        deploy
        ;;
    install)
        mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
        cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/ios_autodeploy.sh</string>
        <string>run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key>
    <integer>$INTERVAL_SECS</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$PLIST"
        echo "Installed $PLIST (checks hourly, deploys every 3 days). Log: $LOG"
        ;;
    uninstall)
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        echo "Removed $LABEL."
        ;;
    status)
        ts=$(last_success)
        if [ "$ts" -gt 0 ]; then
            echo "Last successful deploy: $(date -r "$ts") ($(( ($(date +%s) - ts) / 3600 ))h ago)"
        else
            echo "No successful auto-deploy recorded yet."
        fi
        launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|last exit code|runs" || echo "Agent not loaded."
        ;;
    *)
        echo "usage: $0 [run|now|install|uninstall|status]" >&2
        exit 2
        ;;
esac
