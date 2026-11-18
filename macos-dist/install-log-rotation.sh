#!/bin/bash
# Install Skylight's user-level hourly log rotator and run it once immediately.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/skylight-identity.conf"
[ -f "$DIR/skylight-identity.local.conf" ] && source "$DIR/skylight-identity.local.conf"

LABEL="${SKYLIGHT_DAEMON_LABEL}.logrotate"
SHARE_DIR="$HOME/.local/share/skylight"
SCRIPT="$SHARE_DIR/rotate-logs.sh"
LOG_DIR="$HOME/.config/skylight"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$SHARE_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
cp -f "$DIR/rotate-logs.sh" "$SCRIPT"
chmod 755 "$SCRIPT"

sed -e "s|__LABEL__|$LABEL|g" \
    -e "s|__SCRIPT__|$SCRIPT|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$DIR/com.skylight.logrotate.plist.template" > "$DEST"
plutil -lint "$DEST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "==> $LABEL installed (hourly, 8 MiB threshold, 3 generations)"
