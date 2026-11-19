#!/bin/bash
# Build SkylightMenu.app: swift build the SwiftPM executable, assemble a minimal .app bundle
# around it (Info.plist + LSUIElement, no dock icon), and sign it with the SAME self-signed
# identity (from skylight-identity.conf) the sunshine host is signed with -- see
# docs/design/menubar-app.md ("Peer authentication") for why the two binaries must share one
# signing identity: each side's XPC peer check is pinned to a designated requirement built
# from the OTHER side's bundle id + this cert's SHA-1.
#
# S0 walking skeleton: no hardened runtime (matches the host -- see rebuild-and-resign.sh),
# no notarization. Local-trust native per docs/design/menubar-app.md AXIS 2.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MDIST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$MDIST/.." && pwd)"
source "$MDIST/skylight-identity.conf"
SOURCE_REVISION="${COMMIT:-$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf unknown)}"
[ -f "$MDIST/skylight-identity.local.conf" ] && source "$MDIST/skylight-identity.local.conf"
"$MDIST/generate-identity.sh"
CERT="$SKYLIGHT_SIGNING_IDENTITY"
BUNDLE_ID="$SKYLIGHT_MENU_BUNDLE_ID"
APP="$DIR/.build/SkylightMenu.app"
BIN_NAME="SkylightMenu"

echo "==> swift build -c release…"
( cd "$DIR" && swift build -c release )

BUILT_BIN="$DIR/.build/release/$BIN_NAME"
if [ ! -f "$BUILT_BIN" ]; then
    echo "    BUILD FAILED — $BUILT_BIN not found"
    exit 1
fi
echo "    build OK"

echo "==> assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/Defaults"
cp "$REPO/macos-dist/sunshine.conf.example" "$APP/Contents/Resources/Defaults/sunshine.conf"
cp "$REPO/src_assets/macos/assets/apps.json" "$APP/Contents/Resources/Defaults/apps.json"
cp -f "$BUILT_BIN" "$APP/Contents/MacOS/$BIN_NAME"
cp -R "$DIR/Lucide/pdf" "$APP/Contents/Resources/Lucide"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Skylight</string>
    <key>CFBundleDisplayName</key>
    <string>Skylight</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>SkylightSourceRevision</key>
    <string>$SOURCE_REVISION</string>
    <key>CFBundleShortVersionString</key>
    <string>$SKYLIGHT_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SkylightSourceRepoPath</key>
    <string>$REPO</string>
</dict>
</plist>
PLIST

echo "==> signing ($CERT), no hardened runtime (S0 matches host posture)…"
codesign -s "$CERT" --force --timestamp=none "$APP"
if codesign --verify --verbose=1 "$APP"; then
  echo "    signature valid"
else
  echo "ERROR: codesign verify failed for $APP" >&2
  exit 1
fi
echo "    designated requirement:"; codesign -dr- "$APP" 2>&1 | grep -i designated | sed 's/^/    /'

# Legacy developer install. Keep the nested menu's bundle identity and re-sign
# the outer app after replacing its contents. The daemon keeps running.
if [ "${1:-}" = "install" ]; then
    HOST_APP="$HOME/Applications/Skylight.app"
    INSTALLED="$HOST_APP/Contents/Helpers/SkylightMenu.app"
    if [ ! -d "$HOST_APP" ]; then
        echo "    INSTALL FAILED — $HOST_APP not found (deploy the daemon bundle first)"
        exit 1
    fi
    echo "==> installing to ${INSTALLED}…"
    mkdir -p "$HOST_APP/Contents/Helpers"
    rm -rf "$INSTALLED"
    cp -R "$APP" "$INSTALLED"
    codesign -s "$CERT" --force --timestamp=none "$INSTALLED"
    if codesign --verify --verbose=1 "$INSTALLED"; then
        echo "    installed signature valid"
    else
        echo "ERROR: codesign verify failed for $INSTALLED" >&2
        exit 1
    fi
    echo "==> re-sealing outer Skylight.app (nested content changed)…"
    codesign -s "$CERT" --force --timestamp=none "$HOST_APP"
    if codesign --verify --verbose=1 "$HOST_APP"; then
        echo "    outer bundle signature valid"
    else
        echo "ERROR: codesign verify failed for $HOST_APP" >&2
        exit 1
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED" 2>/dev/null || true
    echo "==> installed. Relaunch with: pkill -x $BIN_NAME; open \"$INSTALLED\""
else
    echo "==> done (build dir). $APP   (run 'build.sh install' to nest it in ~/Applications/Skylight.app)"
fi
