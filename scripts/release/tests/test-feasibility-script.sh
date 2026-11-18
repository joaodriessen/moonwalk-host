#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$REPO/scripts/release/build-feasibility-artifact.sh"

grep -Fq -- '--target sunshine vd_helper' "$SCRIPT" || {
  echo "FAIL: feasibility build does not request the two real release targets" >&2
  exit 1
}
if grep -Fq 'get_display_origin' "$SCRIPT"; then
  echo "FAIL: feasibility build requires obsolete get_display_origin target" >&2
  exit 1
fi

echo "PASS: feasibility build targets exist in a clean CMake tree"
