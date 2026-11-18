#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

usage() {
  echo "Usage: $0 --identity 'Developer ID Application: Name (TEAMID)'"
}

IDENTITY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

[ -n "$IDENTITY" ] || { echo "ERROR: --identity is required" >&2; usage >&2; exit 64; }
require_release_tools
require_developer_id "$IDENTITY"
TEAM_ID="$(release_team_id "$IDENTITY")"

echo "release tools: ready"
echo "signing identity: $IDENTITY"
echo "team identifier: $TEAM_ID"
echo "preflight: ready"
