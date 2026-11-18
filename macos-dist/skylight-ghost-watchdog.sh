#!/bin/bash
# skylight-ghost-watchdog — every 5 min (launchd StartInterval), detect orphaned virtual
# displays and cure them BEFORE they wedge WindowServer and lock the owner out.
#
# Invariant: a vendor-0xF0F0 display is legitimate ONLY while a vd_helper process is alive
# to hold it. Signature display present + no vd_helper = ghost from a torn-down session.
# The cure (display sleep/wake re-enumeration) is skipped while a stream is active — a live
# helper means a live session; never blank a session the owner is using.
#
# Log: /tmp/skylight-ghostwatch.log (volatile by design)
set -u
LOG=/tmp/skylight-ghostwatch.log

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/skylight-identity.conf"
[ -f "$DIR/skylight-identity.local.conf" ] && source "$DIR/skylight-identity.local.conf"

# --- Liveness watchdog (P1, docs/design/2026-07-12-black-screen-permanent-fix.md, Mode 3): a
# belt-and-braces backstop, NOT the primary fix (the primary fix is the RTSP bind-retry +
# non-zero-exit in src/rtsp.cpp). 48010 is the default RTSP setup port (base port 47989 +
# RTSP_SETUP_PORT offset 21, src/rtsp.h); if the port has been reconfigured this check should
# be updated to match.
#
# MENU-AWARE since Phase C (docs/design/2026-07-19-daemon-lifecycle-coupling.md): the daemon is
# on-demand only and "not running" is its NORMAL state whenever the SkylightMenu app is closed —
# menu visible <=> daemon running is the product's user-safety invariant. A dead daemon is
# anomalous ONLY while the menu is alive (the menu's own 3s reconnect should demand-relaunch it;
# this kickstart is the backstop for that path wedging). Kickstarting without a menu present
# would invert the invariant this whole design enforces (the capture gate would kill the daemon
# again in ~10s, but the churn is wrong and the "no menu => no daemon" direction must hold).
SUNSHINE_LABEL="$SKYLIGHT_DAEMON_LABEL"
RTSP_PORT=48010

menu_running() {
  pgrep -x SkylightMenu >/dev/null 2>&1
}

sunshine_running() {
  launchctl print "gui/$(id -u)/${SUNSHINE_LABEL}" 2>/dev/null | grep -q 'state = running'
}

rtsp_listening() {
  lsof -nP -iTCP:"${RTSP_PORT}" -sTCP:LISTEN >/dev/null 2>&1
}

if menu_running && { ! sunshine_running || ! rtsp_listening; }; then
  echo "=== $(date '+%F %H:%M:%S') menu is running but sunshine dead or RTSP ${RTSP_PORT} not listening — kickstarting" >> "$LOG"
  launchctl kickstart -k "gui/$(id -u)/${SUNSHINE_LABEL}"
fi

GHOSTS=$(python3 -c "
import ctypes
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
arr = (ctypes.c_uint32 * 16)(); cnt = ctypes.c_uint32(0)
cg.CGGetOnlineDisplayList(16, arr, ctypes.byref(cnt))
print(sum(1 for i in range(cnt.value) if cg.CGDisplayVendorNumber(arr[i]) == 0xF0F0 and (cg.CGDisplayIsMain(arr[i]) or cnt.value == 1)))" 2>/dev/null || echo 0)

# HARMFUL ghosts only: signature display that is MAIN or the sole display. A just-released
# VD legitimately lingers in enumeration ~10-30s while WindowServer drains it, but is never
# main — curing those would blank the owner's displays after every normal disconnect.
if [ "$GHOSTS" = "0" ]; then
  exit 0  # healthy — stay silent
fi

if pgrep -f vd_helper >/dev/null; then
  exit 0  # a live session legitimately owns a virtual display — never cure mid-stream
fi

echo "=== $(date '+%F %H:%M:%S') ghost detected (${GHOSTS} signature display(s), no vd_helper) — curing" >> "$LOG"
pmset displaysleepnow
sleep 4
caffeinate -u -t 2
sleep 3
AFTER=$(python3 -c "
import ctypes
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
arr = (ctypes.c_uint32 * 16)(); cnt = ctypes.c_uint32(0)
cg.CGGetOnlineDisplayList(16, arr, ctypes.byref(cnt))
print(sum(1 for i in range(cnt.value) if cg.CGDisplayVendorNumber(arr[i]) == 0xF0F0 and (cg.CGDisplayIsMain(arr[i]) or cnt.value == 1)))" 2>/dev/null || echo "?")
echo "cure done; ghosts now: ${AFTER}" >> "$LOG"
