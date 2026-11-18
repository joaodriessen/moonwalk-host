#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 DMG STAPLED_APP" >&2
  exit 64
fi
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/common.sh"
DMG="$1"
APP="$2"
MOUNT="$(mktemp -d)"
ATTACHED=false
cleanup() {
  if [ "$ATTACHED" = true ]; then hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; fi
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT"
ATTACHED=true
PAYLOAD="$MOUNT/Skylight.app"
codesign --verify --deep --strict "$PAYLOAD"
xcrun stapler validate "$PAYLOAD"
if [ "$(release_app_digest "$PAYLOAD")" != "$(release_app_digest "$APP")" ]; then
  echo "ERROR: the DMG payload differs from the stapled app" >&2
  exit 1
fi
hdiutil detach "$MOUNT" >/dev/null
ATTACHED=false
echo "Verified the signed and stapled app inside the DMG"
