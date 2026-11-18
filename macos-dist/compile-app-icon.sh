#!/bin/bash
# Compile the layered app icon into a bundle's Resources. Needs Xcode 26 or later.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$1"
PARTIAL="$(mktemp)"
trap 'rm -f "$PARTIAL"' EXIT

xcrun actool "$DIR/AppIcon.icon" \
  --compile "$APP/Contents/Resources" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --output-partial-info-plist "$PARTIAL" \
  --errors --warnings >/dev/null
# sunshine.icns is the full-resolution fallback for macOS 14 and 15; actool's stops at 256 pixels.
rm -f "$APP/Contents/Resources/AppIcon.icns"
[ -f "$APP/Contents/Resources/Assets.car" ]
