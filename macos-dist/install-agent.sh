#!/bin/bash
# install-agent.sh — render one of Skylight's optional launchd agent templates (ghostwatch)
# with THIS machine's identity/paths and bootstrap it into ~/Library/LaunchAgents.
# The agent is DEFAULT OFF: nothing else in this repo calls this script automatically.
#
#   ./install-agent.sh ghostwatch   # no other wiring yet -- run by hand if you want the watchdog
#
# Template placeholders: __HOME__ ($HOME), __REPO__ (this checkout's root), __LABEL__ (the
# launchd label, from skylight-identity.conf so it can never drift from what other consumers
# expect).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

source "$DIR/skylight-identity.conf"
[ -f "$DIR/skylight-identity.local.conf" ] && source "$DIR/skylight-identity.local.conf"

usage() {
  echo "Usage: $0 <ghostwatch>" >&2
  exit 1
}

AGENT="${1:-}"
case "$AGENT" in
  ghostwatch)
    TEMPLATE="$DIR/com.skylight.ghostwatch.plist.template"
    LABEL="$SKYLIGHT_GHOSTWATCH_LABEL"
    ;;
  *)
    usage
    ;;
esac

[ -f "$TEMPLATE" ] || { echo "ERROR: template not found: $TEMPLATE" >&2; exit 1; }

DEST_DIR="$HOME/Library/LaunchAgents"
DEST="$DEST_DIR/$LABEL.plist"
mkdir -p "$DEST_DIR"

sed -e "s|__HOME__|$HOME|g" -e "s|__REPO__|$REPO|g" -e "s|__LABEL__|$LABEL|g" "$TEMPLATE" > "$DEST"
echo "==> rendered $TEMPLATE -> $DEST (label: $LABEL)"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$DEST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "==> $LABEL loaded and kickstarted"
