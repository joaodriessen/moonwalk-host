#!/bin/bash
# skylight-rescue — recover the Mac's display pipeline when it wedges (black streams,
# black physical monitor, "no signal"). Runs entirely over SSH: WindowServer wedges kill
# every display surface (Moonlight, Jump Desktop, the physical monitor) but never SSH.
#
# Install on the CLIENT:  scp this to ~/bin/skylight-rescue ; chmod +x
#   then from the laptop:  skylight-rescue            (runs the cure ladder over ssh)
#                          skylight-rescue --reboot   (last resort: reboot the Mac)
# Or run locally on the Mac: ~/.local/share/lumen/skylight-rescue.sh
#
# Escalation ladder (each step is safe; later steps are stronger):
#   1. stop Skylight + kill every virtual-display holder (releases CGVirtualDisplays)
#   2. display sleep/wake cycle (forces WindowServer re-enumeration — clears ghosts)
#   3. verify: no vendor-0xF0F0 signature displays remain, physical display enumerated
#   4. restart Skylight
#   --reboot: full macOS restart (the guaranteed reset; ~2 min)
#
# SKYLIGHT_RESCUE_HOST / SKYLIGHT_RESCUE_USER override the SSH relay target when running
# this on the client (a client can't auto-detect the Mac's hostname/user; there is no
# generic default that works for every machine pair, so set these once in your shell rc,
# e.g. `export SKYLIGHT_RESCUE_HOST=your-mac.local`).
set -u

MAC_HOST="${SKYLIGHT_RESCUE_HOST:-skylight-host.local}"
SSH_USER="${SKYLIGHT_RESCUE_USER:-$USER}"
SELF_ON_MAC="$HOME/.local/share/lumen/skylight-rescue.sh"

# If we're NOT on the Mac, relay ourselves over SSH.
if [ "$(uname)" != "Darwin" ]; then
  echo "[rescue] relaying to ${MAC_HOST} over SSH..."
  exec ssh -o ConnectTimeout=10 "${SSH_USER}@${MAC_HOST}" "bash ${SELF_ON_MAC} ${1:-}"
fi

# Resolve the TRUE script location even when invoked through a symlink. The documented deploy
# step symlinks this file into ~/.local/share/lumen/ (README's "Live <-> repo mapping"), so a
# naive dirname/BASH_SOURCE read lands in the deploy dir, which never gets its own copy of
# skylight-identity.conf -- that silently mis-resolved DAEMON_LABEL to the legacy hardcoded
# default on any non-legacy install. Walking the symlink chain lands us back in the repo's
# macos-dist/ (where the conf actually lives) for both the deployed-symlink case and the
# run-straight-from-repo case.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  LINK_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$LINK_DIR/$SOURCE"
done
DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

if [ -f "$DIR/skylight-identity.conf" ]; then
  source "$DIR/skylight-identity.conf"
  [ -f "$DIR/skylight-identity.local.conf" ] && source "$DIR/skylight-identity.local.conf"
else
  echo "[rescue] WARNING: skylight-identity.conf not found (looked in $DIR) — falling back to the legacy label com.lumen.sunshine. Run this script via its repo symlink (see macos-dist/README.md \"Live <-> repo mapping\") for a correct label on non-legacy installs." >&2
fi
DAEMON_LABEL="${SKYLIGHT_DAEMON_LABEL:-com.lumen.sunshine}"

if [ "${1:-}" = "--reboot" ]; then
  echo "[rescue] REBOOT requested — restarting the Mac in 5s (SSH will drop)"
  (sleep 5; osascript -e 'tell application "System Events" to restart') >/dev/null 2>&1 &
  exit 0
fi

echo "[rescue] 1/4 stopping Skylight and killing virtual-display holders"
launchctl bootout "gui/$(id -u)/${DAEMON_LABEL}" 2>/dev/null
pkill -f "Skylight.app.*sunshine" 2>/dev/null
pkill -f vd_helper 2>/dev/null
sleep 2

echo "[rescue] 2/4 display sleep/wake cycle (WindowServer re-enumeration)"
pmset displaysleepnow
sleep 5
caffeinate -u -t 3
sleep 4

echo "[rescue] 3/4 verifying"
GHOSTS=$(python3 -c "
import ctypes
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
arr = (ctypes.c_uint32 * 16)(); cnt = ctypes.c_uint32(0)
cg.CGGetOnlineDisplayList(16, arr, ctypes.byref(cnt))
print(sum(1 for i in range(cnt.value) if cg.CGDisplayVendorNumber(arr[i]) == 0xF0F0))" 2>/dev/null || echo "?")
DP="$(command -v displayplacer || true)"
[ -n "$DP" ] || DP=/opt/homebrew/bin/displayplacer
if [ -x "$DP" ]; then
  DISPLAYS=$("$DP" list 2>/dev/null | grep -c "Contextual screen id")
else
  echo "[rescue] WARNING: displayplacer not found (checked PATH and $DP) — install via 'brew tap jakehilborn/jakehilborn && brew install displayplacer'; skipping display-enumeration check" >&2
  DISPLAYS="?"
fi
echo "[rescue]    signature ghosts: ${GHOSTS}   displays enumerated: ${DISPLAYS}"

echo "[rescue] 4/4 restarting Skylight"
launchctl enable "gui/$(id -u)/${DAEMON_LABEL}"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/${DAEMON_LABEL}.plist" 2>/dev/null
launchctl kickstart "gui/$(id -u)/${DAEMON_LABEL}" 2>/dev/null
sleep 3
if pgrep -f "Skylight.app.*sunshine" >/dev/null; then
  echo "[rescue] done — Skylight running, displays re-enumerated."
  echo "[rescue] if the PHYSICAL monitor still shows no signal: power-cycle the monitor;"
  echo "[rescue] if that fails: skylight-rescue --reboot"
else
  echo "[rescue] WARNING: Skylight did not restart — check ~/.config/skylight/launchd.err.log"
fi
