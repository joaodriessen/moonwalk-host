#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../.." && pwd)"
HELPERS="$REPO/scripts/release/macho-dependencies.sh"
BUNDLER="$REPO/scripts/release/bundle-libraries.sh"
AUDITOR="$REPO/scripts/release/audit-dependencies.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$HELPERS" ] || fail "dependency helper is missing"
# shellcheck source=/dev/null
source "$HELPERS"

is_system_dependency /usr/lib/libSystem.B.dylib || fail "/usr/lib was not classified as system"
is_system_dependency /System/Library/Frameworks/AppKit.framework/AppKit || fail "/System/Library was not classified as system"
if is_system_dependency /opt/homebrew/lib/libopus.0.dylib; then
  fail "Homebrew dependency was classified as system"
fi

APP="$WORK/Skylight.app"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Helpers"
touch "$APP/Contents/Frameworks/libinside.dylib"
resolved="$(resolve_dependency "$APP" "$APP/Contents/Resources/Helpers/Skylight" '@rpath/libinside.dylib')"
[ "$resolved" = "$APP/Contents/Frameworks/libinside.dylib" ] || fail "@rpath did not resolve inside Frameworks"

mkdir -p "$WORK/a" "$WORK/b"
printf first > "$WORK/a/libcollision.dylib"
printf second > "$WORK/b/libcollision.dylib"
copy_dependency_into_frameworks "$APP" "$WORK/a/libcollision.dylib" >/dev/null
if copy_dependency_into_frameworks "$APP" "$WORK/b/libcollision.dylib" >"$WORK/collision.out" 2>&1; then
  fail "different libraries with the same basename were accepted"
fi
grep -Fqi collision "$WORK/collision.out" || fail "collision error was not actionable"

[ -x "$BUNDLER" ] || fail "dependency bundler is missing or not executable"
[ -x "$AUDITOR" ] || fail "dependency auditor is missing or not executable"

echo "PASS: Mach-O dependency classification and collisions are fail-closed"
