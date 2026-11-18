#!/bin/bash
# Deploy the WHOLE Skylight.app in one pass: daemon (sunshine + helpers) AND the nested
# SkylightMenu, with a single final re-seal of the outer bundle. Replaces running
# rebuild-and-resign.sh and SkylightMenu/build.sh install back-to-back, each of which
# re-seals the outer bundle independently (workstream E4 of the Skylight One program).
#
# Order matters:
#   1. daemon build + binary install (rebuild-and-resign.sh does its own reseal + restart)
#   2. menu app build + nested install (build.sh install reseals again after nesting)
#   3. relaunch the nested menu app so the user is running the fresh build
set -euo pipefail

# Old developer deployment starts the daemon before its menu can migrate settings.
# Use the current packaged app for this one-time namespace transition.
if [ -f "$HOME/.config/sunshine/sunshine.conf" ] && [ ! -s "$HOME/.config/skylight/sunshine.conf" ]; then
    echo "ERROR: open the current packaged Skylight app once to migrate its settings before using legacy developer deployment." >&2
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "════ Skylight deploy-all ════"
echo "==> [1/3] daemon (rebuild-and-resign.sh)…"
bash "$DIR/rebuild-and-resign.sh"

echo "==> [2/5] menu app (SkylightMenu/build.sh install)…"
bash "$DIR/SkylightMenu/build.sh" install

# CRITICAL ORDERING (2026-07-16): build.sh install re-seals the OUTER Skylight.app bundle,
# which re-signs the daemon's own executable (Contents/MacOS/sunshine) on disk. The daemon
# that step 1 started is now running an image whose on-disk signature no longer matches what
# the XPC peer-requirement check (setCodeSigningRequirement, both sides) validates against, so
# the whole UI shows "Not connected" despite a healthy daemon. Restart the daemon LAST, after
# the final reseal, so its running image matches disk. (This ordering still matters even after
# the 2026-07-16 switch from manual validatePeer to OS-enforced setCodeSigningRequirement.)
echo "==> [3/5] restarting daemon so its running image matches the resealed bundle…"
source "$DIR/skylight-identity.conf"
[ -f "$DIR/skylight-identity.local.conf" ] && source "$DIR/skylight-identity.local.conf"
launchctl kickstart -k "gui/$(id -u)/$SKYLIGHT_DAEMON_LABEL"
sleep 2

echo "==> [4/5] installing bounded log rotation…"
bash "$DIR/install-log-rotation.sh"

echo "==> [5/5] relaunching nested SkylightMenu…"
pkill -x SkylightMenu 2>/dev/null || true
sleep 1
open "$HOME/Applications/Skylight.app/Contents/Helpers/SkylightMenu.app"

echo "════ deploy-all done ════"
if codesign --verify --deep --strict "$HOME/Applications/Skylight.app"; then
  echo "bundle seal: VALID (deep)"
else
  echo "ERROR: codesign verify failed for $HOME/Applications/Skylight.app" >&2
  exit 1
fi
