#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "Usage: $0 --identity IDENTITY --notary-profile PROFILE [--app APP] [--dmg DMG]"; }
IDENTITY=""; PROFILE=""; APP=""; DMG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; IDENTITY="$2"; shift 2 ;;
    --notary-profile) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; PROFILE="$2"; shift 2 ;;
    --app) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; APP="$2"; shift 2 ;;
    --dmg) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; DMG="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "ERROR: --notary-profile is required" >&2; exit 64; }
[ -n "$IDENTITY" ] || { echo "ERROR: --identity is required" >&2; exit 64; }
[ -n "$APP" ] || [ -n "$DMG" ] || { echo "ERROR: supply --app or --dmg" >&2; exit 64; }
[ -z "$APP" ] || [ -d "$APP/Contents" ] || { echo "ERROR: invalid app: $APP" >&2; exit 1; }
[ -z "$DMG" ] || [ -f "$DMG" ] || { echo "ERROR: invalid DMG: $DMG" >&2; exit 1; }

source "$DIR/release/common.sh"
TEAM_ID="$(release_team_id "$IDENTITY")"
submit() {
  local package="$1" result="$2" status submission
  xcrun notarytool submit "$package" --keychain-profile "$PROFILE" --wait --output-format json > "$result"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || sed -n 's/.*"status"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$result")"
  if [ "$status" != Accepted ]; then
    submission="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    [ -n "$submission" ] && xcrun notarytool log "$submission" --keychain-profile "$PROFILE" "${result%-result.json}-log.json" || true
    echo "ERROR: notarization status: ${status:-unknown}" >&2
    return 1
  fi
}

if [ -n "$DMG" ]; then
  codesign --verify --strict "$DMG"
  submit "$DMG" "$(dirname "$DMG")/notary-result.json"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
if [ -n "$APP" ]; then
  if [ -z "$DMG" ]; then
    "$DIR/release/verify-artifact.sh" --team-id "$TEAM_ID" "$APP"
    work="$(mktemp -d)"
    trap 'unlink "$work/Skylight.zip" 2>/dev/null || true; rmdir "$work"' EXIT
    ditto -c -k --keepParent "$APP" "$work/Skylight.zip"
    submit "$work/Skylight.zip" "$(dirname "$APP")/notary-app-result.json"
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  "$DIR/release/verify-artifact.sh" --team-id "$TEAM_ID" "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
