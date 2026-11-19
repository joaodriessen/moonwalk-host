#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd -P)"

usage() {
  echo "Usage: $0 [--prefix $REPO/build/dev]"
  echo "Build and sign a developer app in build/dev without installing it or registering its service."
}

if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
  usage
  exit 0
fi
if [ "$#" -ne 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --prefix ] && [ "$2" = "$REPO/build/dev" ] || { usage >&2; exit 64; }
fi

exec "$DIR/package-release.sh" --developer --output-app "$REPO/build/dev/Skylight.app" --build-dir "$REPO/build/dev-compile"
