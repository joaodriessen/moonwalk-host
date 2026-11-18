#!/bin/bash
# Install runtime assets that must come from committed source, independent of whether the
# optional web-ui build target refreshed build/assets.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <source-root> <Skylight.app>" >&2
  exit 2
fi

SOURCE_ROOT="$1"
APP_ROOT="$2"
SOURCE_SCHEMA="$SOURCE_ROOT/src_assets/common/assets/web/config_schema.json"
DEST_DIR="$APP_ROOT/Contents/Resources/assets/web"

if [ ! -f "$SOURCE_SCHEMA" ]; then
  echo "ERROR: committed config schema not found: $SOURCE_SCHEMA" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp -f "$SOURCE_SCHEMA" "$DEST_DIR/config_schema.json"
