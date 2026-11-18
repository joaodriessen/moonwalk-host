#!/bin/bash
set -euo pipefail

usage() { echo "Usage: $0 --team-id TEAMID APP_OR_DIRECTORY"; }
die() { echo "ERROR: $*" >&2; exit 1; }

TEAM_ID=""
TARGET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team-id) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; TEAM_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$TARGET" ] || die "only one target may be audited"; TARGET="$1"; shift ;;
  esac
done

[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "--team-id must be ten uppercase letters or digits"
[ -n "$TARGET" ] || { usage >&2; exit 64; }
[ -e "$TARGET" ] || die "target does not exist: $TARGET"

CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"
FILE_BIN="${FILE_BIN:-/usr/bin/file}"
MACHO_COUNT=0

audit_macho() {
  local binary="$1"
  local details entitlements actual_team actual_identifier
  if ! "$CODESIGN_BIN" --verify --strict "$binary" >/dev/null 2>&1; then
    die "invalid or missing signature: $binary"
  fi
  details="$("$CODESIGN_BIN" -dvv "$binary" 2>&1)" || die "cannot inspect signature: $binary"
  printf '%s\n' "$details" | grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' || die "hardened runtime is missing: $binary"
  printf '%s\n' "$details" | grep -Eq '^Timestamp=' || die "secure timestamp is missing: $binary"
  actual_team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  [ "$actual_team" = "$TEAM_ID" ] || die "unexpected Team Identifier '$actual_team' in $binary (expected $TEAM_ID)"
  if [[ "$binary" == */Contents/Resources/Helpers/Skylight ]]; then
    actual_identifier="$(printf '%s\n' "$details" | sed -n 's/^Identifier=//p' | head -1)"
    [ "$actual_identifier" = "io.github.joaodriessen.skylight.host" ] || \
      die "unexpected host signing identifier '$actual_identifier' (expected io.github.joaodriessen.skylight.host)"
  fi
  entitlements="$("$CODESIGN_BIN" -d --entitlements :- "$binary" 2>&1 || true)"
  if printf '%s\n' "$entitlements" | grep -Fq '<key>com.apple.security.get-task-allow</key>'; then
    die "get-task-allow entitlement is forbidden: $binary"
  fi
}

if [ -f "$TARGET" ]; then
  if "$FILE_BIN" -b "$TARGET" | grep -Fq 'Mach-O'; then
    MACHO_COUNT=1
    audit_macho "$TARGET"
  fi
else
  while IFS= read -r -d '' candidate; do
    if "$FILE_BIN" -b "$candidate" | grep -Fq 'Mach-O'; then
      MACHO_COUNT=$((MACHO_COUNT + 1))
      audit_macho "$candidate"
    fi
  done < <(find "$TARGET" -type f -print0)
fi
[ "$MACHO_COUNT" -gt 0 ] || die "no Mach-O executables found under $TARGET"

if [ -d "$TARGET" ] && [[ "$TARGET" == *.app ]]; then
  "$CODESIGN_BIN" --verify --deep --strict "$TARGET" >/dev/null 2>&1 || die "application bundle seal is invalid: $TARGET"
fi

echo "signing audit: PASS ($MACHO_COUNT Mach-O files, Team ID $TEAM_ID)"
