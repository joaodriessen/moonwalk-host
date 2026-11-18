#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "Usage: $0 --identity IDENTITY --notary-profile PROFILE --app APP --dmg DMG"; }
IDENTITY=""; PROFILE=""; APP=""; DMG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notary-profile) PROFILE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --dmg) DMG="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done
[ -n "$PROFILE" ] || { echo "ERROR: --notary-profile is required" >&2; exit 64; }
[ -n "$IDENTITY" ] || { echo "ERROR: --identity is required" >&2; exit 64; }
[ -d "$APP/Contents" ] || { echo "ERROR: invalid app: ${APP:-missing}" >&2; exit 1; }
[ -f "$DMG" ] || { echo "ERROR: invalid DMG: ${DMG:-missing}" >&2; exit 1; }

source "$DIR/release/common.sh"
TEAM_ID="$(release_team_id "$IDENTITY")"
codesign --verify --strict "$DMG" >/dev/null 2>&1 || {
  echo "ERROR: DMG signature is invalid: $DMG" >&2
  exit 1
}

RESULT="$(dirname "$DMG")/notary-result.json"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT"
status="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || sed -n 's/.*"status"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$RESULT")"
if [ "$status" != Accepted ]; then
  submission="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
  [ -n "$submission" ] && xcrun notarytool log "$submission" --keychain-profile "$PROFILE" "$(dirname "$DMG")/notary-log.json" || true
  echo "ERROR: notarization status: ${status:-unknown}" >&2
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
"$DIR/release/verify-artifact.sh" --team-id "$TEAM_ID" "$APP"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Notarized artifact: $DMG"
