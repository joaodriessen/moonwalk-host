#!/bin/bash
# Rebuild Skylight from source, install into the signed Skylight.app bundle, re-sign with the
# STABLE self-signed cert (so macOS TCC grants survive), and restart the LaunchAgent.
# Because the bundle id + cert are constant, Screen Recording / Accessibility do NOT need
# re-granting after a rebuild. Run this after editing anything under ~/Projects/Skylight/src.
set -euo pipefail

# Old developer deployment starts the daemon before its menu can migrate settings.
# Use the current packaged app for this one-time namespace transition.
if [ -f "$HOME/.config/sunshine/sunshine.conf" ] && [ ! -s "$HOME/.config/skylight/sunshine.conf" ]; then
    echo "ERROR: open the current packaged Skylight app once to migrate its settings before using legacy developer deployment." >&2
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/skylight-identity.conf"
[ -f "$DIR/skylight-identity.local.conf" ] && source "$DIR/skylight-identity.local.conf"
"$DIR/generate-identity.sh"

SRC="$(cd "$DIR/.." && pwd)"
BUILD="$SRC/build"
APP=~/Applications/Skylight.app
SHARE=~/.local/share/lumen
CERT="$SKYLIGHT_SIGNING_IDENTITY"
AGENT="$SKYLIGHT_DAEMON_LABEL"

echo "==> building sunshine…"
( cd "$BUILD" && make sunshine -j"$(sysctl -n hw.ncpu)" >/tmp/lumen_rebuild.log 2>&1 ) \
  && echo "    build OK" || { echo "    BUILD FAILED — see /tmp/lumen_rebuild.log"; tail -5 /tmp/lumen_rebuild.log; exit 1; }

echo "==> signing freshly-built binary in place ($CERT), before touching the bundle…"
# -i "$SKYLIGHT_BUNDLE_ID" is load-bearing: the menu pins the daemon's XPC peer to
# `identifier "$SKYLIGHT_BUNDLE_ID"` (GeneratedIdentity.hostPeerRequirement). Since the bundle's
# CFBundleExecutable is the launcher stub (not sunshine), codesign would otherwise derive this
# binary's identifier from its embedded __info_plist (dev.lizardbyte.sunshine) and the menu would
# reject every connection ("not running"). Pin it explicitly so it can't drift.
codesign -s "$CERT" -i "$SKYLIGHT_BUNDLE_ID" --force --timestamp=none "$BUILD/sunshine"
if codesign --verify --verbose=1 "$BUILD/sunshine"; then
  echo "    build/sunshine signature valid"
else
  echo "ERROR: codesign verify failed for $BUILD/sunshine" >&2
  exit 1
fi
# -i "${SKYLIGHT_BUNDLE_ID}.vd_helper" is load-bearing too, for a DIFFERENT reason than sunshine's
# pin above: with no explicit -i, LaunchServices attributes a running vd_helper (a bare Mach-O at
# Contents/MacOS/, no Info.plist of its own) to the ENCLOSING bundle's identifier
# ($SKYLIGHT_BUNDLE_ID) -- confirmed live via `lsappinfo info -only bundleID <vd_helper pid>`.
# Since vd_helper only runs WHILE STREAMING, this made `open Skylight.app` -- which LaunchServices
# treats as "activate the existing $SKYLIGHT_BUNDLE_ID instance" the instant anything holds that
# identifier -- silently skip re-running the launcher stub and never reopen the menu, but only
# mid-stream. vd_helper has no XPC peer-pinning of its own (plain stdin/stdout subprocess of the
# daemon), so giving it its own identifier is safe.
[ -f "$BUILD/vd_helper" ] && codesign -s "$CERT" -i "${SKYLIGHT_BUNDLE_ID}.vd_helper" --force --timestamp=none "$BUILD/vd_helper" || true
[ -f "$BUILD/vd_helper" ] && codesign --verify --verbose=1 "$BUILD/vd_helper" && echo "    build/vd_helper signature valid" || true

echo "==> installing signed binary into share + bundle…"
# Only reached if the signing/verification above succeeded (the verify step now explicitly
# `exit 1`s on failure), so a failed sign never leaves the live bundle's good binary overwritten
# with a broken one.
cp -fL "$BUILD/sunshine" "$SHARE/sunshine"                    # keep the plain copy in sync too
cp -fL "$BUILD/sunshine" "$APP/Contents/MacOS/sunshine"
# helpers rarely change, but keep them fresh if rebuilt
[ -f "$BUILD/vd_helper" ] && cp -fL "$BUILD/vd_helper" "$APP/Contents/MacOS/vd_helper" || true
bash "$DIR/install-runtime-assets.sh" "$SRC" "$APP"

echo "==> re-sealing bundle with stable identity ($CERT)…"
[ -f "$APP/Contents/MacOS/get_display_origin" ] && codesign -s "$CERT" -i "${SKYLIGHT_BUNDLE_ID}.get_display_origin" --force --timestamp=none "$APP/Contents/MacOS/get_display_origin" || true
codesign -s "$CERT" --force --timestamp=none "$APP"
if codesign --verify --verbose=1 "$APP"; then
  echo "    signature valid"
else
  echo "ERROR: codesign verify failed for $APP" >&2
  exit 1
fi
echo "    designated requirement:"; codesign -dr- "$APP" 2>&1 | grep -i designated | sed 's/^/    /'

echo "==> restarting LaunchAgent…"
# Kill any stray sunshine that launchd has lost track of BEFORE restarting, so we never end up
# with two instances competing over the virtual-display APIs (which orphans VDs / black-screens
# reconnects). kickstart -k only kills the *supervised* instance; a hung/SIGKILLed one can linger
# outside launchd's view. This guarantees a single instance after restart.
pkill -9 -f "Skylight.app/Contents/MacOS/sunshine" 2>/dev/null && echo "    cleared a stray instance" || true
sleep 1
launchctl kickstart -k "gui/$(id -u)/$AGENT"
sleep 2
# This app is intentionally on-demand: during deploy-all the old menu binary may be unable to
# reattach after this intermediate outer-bundle reseal, so the freshly kicked daemon can cleanly
# self-terminate before the two-second probe. That is not a deploy failure; the final menu install
# reseals both peers and demand-launches the daemon again. Still fail if launchd lost the job, and
# print a PID when one remains alive.
AGENT_STATE="$(launchctl print "gui/$(id -u)/$AGENT" 2>/dev/null)"
if printf '%s\n' "$AGENT_STATE" | grep -E "pid = " | sed 's/^/    /'; then
  :
else
  echo "    registered on-demand (daemon exited before probe; final menu relaunch will reconnect)"
fi
echo "==> done. No re-grant needed (identity unchanged)."
