#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"
usage() { echo "Usage: $0 [--replace] [--expected-app-sha SHA256] APP OUTPUT_DMG"; }
REPLACE=0
EXPECTED_APP_SHA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --replace) REPLACE=1; shift ;;
    --expected-app-sha) EXPECTED_APP_SHA="$2"; shift 2 ;;
    *) break ;;
  esac
done
[ "${1:-}" != "--help" ] || { usage; exit 0; }
[ "$#" -eq 2 ] || { usage >&2; exit 64; }
APP="$1"; OUTPUT="$2"
[ -d "$APP/Contents" ] || { echo "ERROR: invalid app: $APP" >&2; exit 1; }
if [ -e "$OUTPUT" ] && [ "$REPLACE" -ne 1 ]; then
  echo "ERROR: output exists; pass --replace to overwrite: $OUTPUT" >&2
  exit 1
fi
WORK="$(mktemp -d)"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT_TMP="$OUTPUT_DIR/.$(basename "$OUTPUT").$$.tmp.dmg"
cleanup() {
  rm -rf "$WORK"
  unlink "$OUTPUT_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
STAGE="$WORK/Skylight"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Skylight.app"
[ -z "$EXPECTED_APP_SHA" ] || [ "$(release_app_digest "$STAGE/Skylight.app")" = "$EXPECTED_APP_SHA" ] || {
  echo "ERROR: staged app digest does not match frozen candidate" >&2
  exit 1
}
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "Moonwalk Host" -srcfolder "$STAGE" "$OUTPUT_TMP"
mv -f "$OUTPUT_TMP" "$OUTPUT"
echo "Created $OUTPUT"
