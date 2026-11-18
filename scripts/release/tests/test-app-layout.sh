#!/bin/bash
set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "Usage: $0 APP" >&2; exit 64; }
fail() { echo "FAIL: $*" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
AGENT="$APP/Contents/Library/LaunchAgents/io.github.joaodriessen.skylight.daemon.plist"
HELPERS="$APP/Contents/Resources/Helpers"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$REPO/macos-dist/skylight-identity.conf"

[ -f "$APP/Contents/MacOS/Skylight" ] || fail "outer Skylight executable is missing"
file -b "$APP/Contents/MacOS/Skylight" | grep -q 'Mach-O' || fail "outer executable is not Mach-O"
[ -f "$HELPERS/Skylight" ] || fail "Skylight host is missing"
[ ! -e "$HELPERS/sunshine" ] || fail "legacy sunshine host name remains"
[ -f "$HELPERS/vd_helper" ] || fail "virtual-display helper is missing"
[ -f "$AGENT" ] || fail "embedded LaunchAgent is missing"
[ -d "$APP/Contents/Frameworks" ] || fail "Frameworks directory is missing"
[ -f "$APP/Contents/Resources/config_schema.json" ] || fail "settings schema is missing"
for glyph in "$REPO"/macos-dist/SkylightMenu/Lucide/pdf/*.pdf; do
  [ -f "$APP/Contents/Resources/Lucide/$(basename "$glyph")" ] || fail "menu glyph $(basename "$glyph") is missing"
done
[ -f "$APP/Contents/Resources/sunshine.icns" ] || fail "app icon is missing"
[ -f "$APP/Contents/Resources/Assets.car" ] || fail "layered app icon is missing"
[ -f "$APP/Contents/Resources/LICENSE.txt" ] || fail "license is missing"
[ -f "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" ] || fail "third-party notices are missing"
for notice in native/openssl/LICENSE.txt native/ffmpeg/COPYING.GPLv2 native/boost/LICENSE_1_0.txt \
  native/x264/COPYING native/x265/COPYING native/svt-av1/LICENSE.md \
  web/@lizardbyte/shared-web/LICENSE web/@vue/devtools-api/LICENSE; do
  [ -s "$APP/Contents/Resources/ThirdPartyLicenses/$notice" ] || fail "missing dependency notice: $notice"
done
[ -f "$APP/Contents/Resources/Defaults/sunshine.conf" ] || fail "default host config is missing"
[ -f "$APP/Contents/Resources/Defaults/apps.json" ] || fail "default apps config is missing"
[ ! -e "$APP/Contents/Resources/assets/Info.plist" ] || fail "dead upstream CPack Info.plist was shipped inside assets"
[ -d "$APP/Contents/Resources/assets/web" ] || fail "web-ui assets directory is missing"
[ -f "$APP/Contents/Resources/assets/box.png" ] || fail "app-list icon assets are missing"
# grep -c (not -q): under this script's pipefail, grep -q exits on first match while
# strings is still streaming the ~22 MB binary -> SIGPIPE(141) fails the pipeline ON MATCH,
# making this assertion impossible to pass. -c drains stdin; || true guards the zero-match
# exit(1) so the numeric check below reports the failure instead of a silent set -e death.
BAKED_COUNT="$(strings -a "$HELPERS/Skylight" | grep -c "^/Applications/Skylight.app/Contents/Resources/assets" || true)"
[ "$BAKED_COUNT" -gt 0 ] || fail "daemon does not bake the canonical bundled assets path"
# The daemon's embedded __info_plist names daemon-triggered macOS permission prompts (local
# network, firewall). The upstream dev.lizardbyte.sunshine identifier surfaced verbatim in an
# owner-facing prompt (2026-08-14); the embedded identity must match the codesign identifier.
# Scoped to the plist section: internal dispatch-queue labels legitimately keep the upstream
# prefix elsewhere in the binary (sc_capture.m/sc_audio.m — diagnostics-only, never prompted).
EMBEDDED_PLIST="$(launchctl plist __TEXT,__info_plist "$HELPERS/Skylight" 2>/dev/null || true)"
printf '%s' "$EMBEDDED_PLIST" | grep -q "io.github.joaodriessen.skylight.host" || fail "daemon embedded __info_plist does not carry the Skylight host identifier"
printf '%s' "$EMBEDDED_PLIST" | grep -q "dev.lizardbyte.sunshine" && fail "daemon embedded __info_plist still carries the upstream identity" || true

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" = Skylight ] || fail "wrong outer executable"
# Shown as Moonwalk Host: Finder uses the localized name only while the plain one matches the file name.
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")" = Skylight ] || fail "plain display name no longer matches the bundle's file name, Skylight.app, so Finder would ignore the localized name"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSHasLocalizedDisplayName' "$PLIST")" = true ] || fail "localized display name is not enabled"
grep -qx '"CFBundleDisplayName" = "Moonwalk Host";' "$APP/Contents/Resources/en.lproj/InfoPlist.strings" || fail "app is not shown as Moonwalk Host"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$SKYLIGHT_VERSION" ] || fail "wrong alpha version (expected $SKYLIGHT_VERSION)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" = 14.0 ] || fail "wrong minimum macOS"
[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$AGENT")" = Contents/Resources/Helpers/Skylight ] || fail "LaunchAgent does not use BundleProgram"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProcessType' "$AGENT")" = Interactive ] || fail "host is not interactive-priority"
/usr/libexec/PlistBuddy -c 'Print :MachServices:io.github.joaodriessen.skylight.xpc' "$AGENT" | grep -qx true || fail "XPC service is missing"

[ ! -e "$APP/Contents/Helpers/SkylightMenu.app" ] || fail "nested menu app remains"
[ ! -e "$APP/Contents/MacOS/SkylightLauncher" ] || fail "launcher stub remains"
if plutil -p "$PLIST" | grep -q 'SkylightSourceRepoPath'; then fail "source checkout path leaked into Info.plist"; fi
if find "$APP" -type f -name 'com.lumen.sunshine.plist' -print -quit | grep -q .; then fail "legacy user LaunchAgent was copied"; fi

echo "PASS: release app layout is self-contained and user-facing"
