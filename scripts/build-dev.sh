#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Building Moonwalk Host with a local development signature."
exec "$DIR/../macos-dist/make-bundle.sh" "$@"
