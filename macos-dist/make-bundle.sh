#!/bin/bash
# make-bundle.sh — assemble, sign, and (optionally) install Skylight.app from a
# source checkout, on a machine that has never seen Skylight before.
#
#   ./make-bundle.sh                  build + install to ~/Applications + launchd
#   ./make-bundle.sh --prefix DIR     build + assemble into DIR (no launchd, no
#                                     ~/Applications) — for testing/packaging
#
# Everything identity-related (bundle ids, launchd label, XPC service, signing
# cert) comes from skylight-identity.conf (+ optional .local.conf override);
# the signing certificate is created on first run and the XPC peer
# requirements are generated from it (generate-identity.sh), so the daemon and
# menu app always trust exactly this machine's build.
#
# Prereqs: Xcode CLT, Homebrew deps for the daemon build (see README), Swift
# toolchain for the menu app.
set -euo pipefail

usage() {
    echo "Usage: $0 [--prefix DIRECTORY]"
    echo "With --prefix, assemble the developer app without installing or registering it."
}

PREFIX=""
INSTALL=1
if [ "$#" -gt 0 ]; then
  case "$1" in
    --help|-h) [ "$#" -eq 1 ] || { usage >&2; exit 64; }; usage; exit 0 ;;
    --prefix)
      [ "$#" -eq 2 ] && [ -n "$2" ] || { usage >&2; exit 64; }
      PREFIX="$2"
      INSTALL=0
      ;;
    *) usage >&2; exit 64 ;;
  esac
fi

# Old developer deployment starts the daemon before its menu can migrate settings.
# Use the current packaged app for this one-time namespace transition.
if [ -f "$HOME/.config/sunshine/sunshine.conf" ] && [ ! -s "$HOME/.config/skylight/sunshine.conf" ]; then
    echo "ERROR: open the current packaged Skylight app once to migrate its settings before using legacy developer deployment." >&2
    exit 1
fi
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

source "$DIR/skylight-identity.conf"
[ -f "$DIR/skylight-identity.local.conf" ] && source "$DIR/skylight-identity.local.conf"

echo "════ Skylight make-bundle ════"
echo "identity: $SKYLIGHT_BUNDLE_ID (cert: $SKYLIGHT_SIGNING_IDENTITY)"

# 1) Identity constants (creates the signing cert if missing)
"$DIR/generate-identity.sh"

# 2) Build the daemon
echo "==> building daemon…"
cmake -B "$REPO/build" -S "$REPO" -DCMAKE_BUILD_TYPE=Release -DSKYLIGHT_VERSION="$SKYLIGHT_VERSION" >/dev/null
cmake --build "$REPO/build" --target sunshine vd_helper web-ui -j "$(sysctl -n hw.ncpu)"

# 3) Build the menu app (build.sh app-only mode assembles SkylightMenu.app in its build dir)
echo "==> building menu app…"
bash "$DIR/SkylightMenu/build.sh"

# 4) Assemble the bundle
APPDIR="${PREFIX:-$HOME/Applications}/Skylight.app"
echo "==> assembling ${APPDIR}…"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources" "$APPDIR/Contents/Helpers"
cp -f "$REPO/sunshine.icns" "$APPDIR/Contents/Resources/sunshine.icns"
bash "$DIR/compile-app-icon.sh" "$APPDIR"
cp -f "$REPO/build/sunshine" "$APPDIR/Contents/MacOS/sunshine"
cp -f "$REPO/build/vd_helper" "$APPDIR/Contents/MacOS/vd_helper"
[ -f "$REPO/build/get_display_origin" ] && cp -f "$REPO/build/get_display_origin" "$APPDIR/Contents/MacOS/get_display_origin" || true
# Daemon runtime assets (web ui / shaders etc. if the build produced them)
if [ -d "$REPO/build/assets" ]; then cp -R "$REPO/build/assets" "$APPDIR/Contents/Resources/"; fi
# Source-owned assets are installed last so a stale/partial build-assets directory can never
# replace the schema consumed by the native Settings XPC surface.
bash "$DIR/install-runtime-assets.sh" "$REPO" "$APPDIR"
rsync -a --delete "$DIR/SkylightMenu/.build/SkylightMenu.app/" "$APPDIR/Contents/Helpers/SkylightMenu.app/"

# CFBundleExecutable stub: a double-click in Finder/Spotlight/Dock should not
# respawn the daemon (launchd already owns it by absolute path, see the plist
# below) — it should just bring the menu helper back if the user quit it. The
# helper's own flock single-instance guard makes `open` on an already-running
# instance a no-op re-activate.
cat > "$APPDIR/Contents/MacOS/SkylightLauncher" <<'STUB'
#!/bin/sh
exec /usr/bin/open "$(cd "$(dirname "$0")/../Helpers" && pwd)/SkylightMenu.app"
STUB
chmod +x "$APPDIR/Contents/MacOS/SkylightLauncher"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Skylight</string>
    <key>CFBundleDisplayName</key><string>Skylight</string>
    <key>CFBundleIdentifier</key><string>$SKYLIGHT_BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>$SKYLIGHT_VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>SkylightLauncher</string>
    <key>CFBundleIconFile</key><string>sunshine</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 5) Sign inner-out
echo "==> signing…"
# -i "${SKYLIGHT_BUNDLE_ID}.<name>" is load-bearing for vd_helper specifically: with no explicit
# -i, codesign's derived identifier for a bare (non-.app) Mach-O living at Contents/MacOS/ of a
# bundle whose CFBundleExecutable is a DIFFERENT binary (the launcher stub) still gets attributed
# by LaunchServices to the enclosing bundle's identifier ($SKYLIGHT_BUNDLE_ID) whenever it's
# running -- confirmed live via `lsappinfo info -only bundleID <vd_helper pid>` reporting
# com.example.lumen. Since vd_helper only runs WHILE STREAMING (spawned by the daemon to hold the
# virtual display), this makes `open Skylight.app` -- which LaunchServices treats as "activate the
# existing com.example.lumen instance" the instant it believes ANY process holds that identifier --
# silently skip re-running SkylightLauncher and never reopen the menu, but only during a stream.
# Giving vd_helper (and get_display_origin, same class of bare helper) their own distinct
# identifiers stops LaunchServices from conflating either with the bundle itself. Neither
# participates in any XPC peer-pinning (they're plain stdin/stdout subprocesses of the daemon, not
# XPC peers), so this is safe -- unlike sunshine's OWN `-i "$SKYLIGHT_BUNDLE_ID"` pin below, which
# is genuinely load-bearing and must NOT change.
for bin in vd_helper get_display_origin; do
  [ -f "$APPDIR/Contents/MacOS/$bin" ] && codesign -s "$SKYLIGHT_SIGNING_IDENTITY" -i "${SKYLIGHT_BUNDLE_ID}.$bin" --force --timestamp=none "$APPDIR/Contents/MacOS/$bin"
done
codesign -s "$SKYLIGHT_SIGNING_IDENTITY" --force --timestamp=none "$APPDIR/Contents/MacOS/SkylightLauncher"
# -i "$SKYLIGHT_BUNDLE_ID" is load-bearing: the menu pins the daemon's XPC peer to
# `identifier "$SKYLIGHT_BUNDLE_ID"`. The bundle's CFBundleExecutable is the launcher stub, not
# sunshine, so without an explicit -i codesign derives sunshine's identifier from its embedded
# __info_plist (dev.lizardbyte.sunshine) and the menu rejects every connection ("not running").
codesign -s "$SKYLIGHT_SIGNING_IDENTITY" -i "$SKYLIGHT_BUNDLE_ID" --force --timestamp=none "$APPDIR/Contents/MacOS/sunshine"
codesign -s "$SKYLIGHT_SIGNING_IDENTITY" --force --deep --timestamp=none "$APPDIR/Contents/Helpers/SkylightMenu.app"
codesign -s "$SKYLIGHT_SIGNING_IDENTITY" --force --timestamp=none "$APPDIR"
if codesign --verify --deep --strict "$APPDIR"; then
  echo "    bundle seal valid"
else
  echo "ERROR: codesign verify failed for $APPDIR" >&2
  exit 1
fi

if [ "$INSTALL" = "0" ]; then
  echo "════ assembled (no install) at $APPDIR ════"
  exit 0
fi

# 6) launchd agent (templated)
echo "==> installing launchd agent ${SKYLIGHT_DAEMON_LABEL}…"
mkdir -p "$HOME/.config/skylight" "$HOME/Library/LaunchAgents"
PLIST_PATH="$HOME/Library/LaunchAgents/$SKYLIGHT_DAEMON_LABEL.plist"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$SKYLIGHT_DAEMON_LABEL</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>ProgramArguments</key>
    <array><string>$APPDIR/Contents/MacOS/sunshine</string></array>
    <!-- ON-DEMAND only (Phase C, docs/design/2026-07-19-daemon-lifecycle-coupling.md): no
         RunAtLoad, no KeepAlive. launchd demand-launches via the MachServices registration when
         the menu connects; the daemon self-terminates when no validated menu is attached, so
         menu visible <=> daemon running. Rollback: KeepAlive={Crashed:true} (see design §7). -->
    <key>ThrottleInterval</key><integer>5</integer>
    <key>EnvironmentVariables</key>
    <dict><key>HOME</key><string>$HOME</string></dict>
    <key>StandardOutPath</key><string>$HOME/.config/skylight/launchd.out.log</string>
    <key>StandardErrorPath</key><string>$HOME/.config/skylight/launchd.err.log</string>
    <key>MachServices</key>
    <dict><key>$SKYLIGHT_XPC_SERVICE</key><true/></dict>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$SKYLIGHT_DAEMON_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/$SKYLIGHT_DAEMON_LABEL"
bash "$DIR/install-log-rotation.sh"

echo "════ make-bundle done ════"
echo "First run: grant Screen Recording + Accessibility when prompted"
echo "(the menu bar app's Permissions window walks you through it)."
