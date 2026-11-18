#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCE_ROOT="$WORK/source"
APP_ROOT="$WORK/Skylight.app"
SOURCE_SCHEMA="$SOURCE_ROOT/src_assets/common/assets/web/config_schema.json"
INSTALLED_SCHEMA="$APP_ROOT/Contents/Resources/assets/web/config_schema.json"

mkdir -p "$(dirname "$SOURCE_SCHEMA")" "$(dirname "$INSTALLED_SCHEMA")"
printf '%s\n' '{"version":1,"source":"committed"}' > "$SOURCE_SCHEMA"
printf '%s\n' '{"version":0,"source":"stale-build"}' > "$INSTALLED_SCHEMA"

bash "$REPO/macos-dist/install-runtime-assets.sh" "$SOURCE_ROOT" "$APP_ROOT"

cmp "$SOURCE_SCHEMA" "$INSTALLED_SCHEMA"
echo "schema packaging test: PASS"
