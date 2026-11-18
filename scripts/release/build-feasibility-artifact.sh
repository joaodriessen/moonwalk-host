#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"
source "$REPO/macos-dist/skylight-identity.conf"

usage() {
  echo "Usage: $0 --identity 'Developer ID Application: Name (TEAMID)' --notary-profile PROFILE"
}

IDENTITY=""
PROFILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --notary-profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
[ -n "$IDENTITY" ] && [ -n "$PROFILE" ] || { usage >&2; exit 64; }

require_release_tools
TEAM_ID="$(release_team_id "$IDENTITY")"
BUILD_DIR="$REPO/build/release-feasibility"
EVIDENCE_DIR="$REPO/build/release-evidence"
PAYLOAD="$BUILD_DIR/SkylightFeasibility"
ZIP="$EVIDENCE_DIR/SkylightFeasibility.zip"
RESULT="$EVIDENCE_DIR/notary-feasibility.json"
mkdir -p "$BUILD_DIR" "$EVIDENCE_DIR"

cmake -S "$REPO" -B "$BUILD_DIR/cmake" -DCMAKE_BUILD_TYPE=Release -DSKYLIGHT_VERSION="$SKYLIGHT_VERSION"
cmake --build "$BUILD_DIR/cmake" --target sunshine vd_helper -j "$(sysctl -n hw.activecpu)"

mkdir -p "$PAYLOAD"
for binary in sunshine vd_helper; do
  source_path="$BUILD_DIR/cmake/$binary"
  [ -f "$source_path" ] || { echo "ERROR: expected build output missing: $source_path" >&2; exit 1; }
  cp "$source_path" "$PAYLOAD/$binary"
  entitlement="$REPO/macos-dist/entitlements/release-helper.plist"
  [ "$binary" = sunshine ] && entitlement="$REPO/macos-dist/entitlements/release-host.plist"
  codesign -s "$IDENTITY" --force --options runtime --timestamp --entitlements "$entitlement" "$PAYLOAD/$binary"
done

"$DIR/audit-signing.sh" --team-id "$TEAM_ID" "$PAYLOAD"
rm -f "$ZIP"
ditto -c -k --keepParent "$PAYLOAD" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json | tee "$RESULT"
STATUS="$(/usr/bin/plutil -extract status raw -o - "$RESULT")"
if [ "$STATUS" != "Accepted" ]; then
  SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$RESULT")"
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "$EVIDENCE_DIR/notary-feasibility-log.json" || true
  echo "ERROR: notarization status was $STATUS" >&2
  exit 1
fi

echo "feasibility gate: Accepted ($ZIP)"
