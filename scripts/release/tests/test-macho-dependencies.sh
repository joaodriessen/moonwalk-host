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

mkdir "$WORK/bin"
cat > "$WORK/bin/file" <<'SH'
#!/bin/bash
case "$2" in
  */Resources/Helpers/Skylight) echo 'Mach-O 64-bit executable arm64' ;;
  *) echo 'data' ;;
esac
SH
cat > "$WORK/bin/lipo" <<'SH'
#!/bin/bash
echo arm64
SH
cat > "$WORK/bin/vtool" <<'SH'
#!/bin/bash
printf 'platform MACOS\n    minos %s\n' "$FIXTURE_MINOS"
SH
cat > "$WORK/bin/otool" <<'SH'
#!/bin/bash
[ "$FIXTURE_DEPENDENCY" != fail ] || exit 1
printf 'helper:\n\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$FIXTURE_DEPENDENCY"
SH
chmod +x "$WORK/bin/"*
touch "$APP/Contents/Resources/Helpers/Skylight" "$WORK/liboutside.dylib"
touch "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
mkdir -p "$APP/Contents/Frameworks/Stable"
touch "$APP/Contents/Frameworks/Stable/liblinked.dylib"
ln -s Stable/liblinked.dylib "$APP/Contents/Frameworks/liblinked.dylib"
ln -s "$WORK/liboutside.dylib" "$APP/Contents/Frameworks/libescape.dylib"

audit() {
  local version="$1" dependency="$2"
  shift 2
  PATH="$WORK/bin:$PATH" FIXTURE_MINOS="$version" FIXTURE_DEPENDENCY="$dependency" "$AUDITOR" "$APP" "$@"
}
expect_audit_failure() {
  if audit "$1" "$2" > "$WORK/audit.out" 2>&1; then
    fail "accepted $1 / $2"
  fi
  grep -Fq "$3" "$WORK/audit.out" || { cat "$WORK/audit.out" >&2; fail "expected $3"; }
}

audit 14.0 '@rpath/liblinked.dylib'
audit 13.6.7 '@loader_path/../../Frameworks/libinside.dylib'
touch "$APP/Contents/Frameworks/lib with spaces.dylib"
audit 14.0 '@rpath/lib with spaces.dylib'
expect_audit_failure 14.0.1 '@rpath/libinside.dylib' 'deployment target exceeds macOS 14.0'
expect_audit_failure 14.0 '@rpath/libescape.dylib' 'dependency escapes app bundle'
expect_audit_failure 14.0 '@loader_path/../../../../liboutside.dylib' 'dependency escapes app bundle'
expect_audit_failure 14.0 fail 'could not read dependencies'

private_root="$WORK/Release workspace"
helper="$APP/Contents/Resources/Helpers/Skylight"
printf '\0opus-1.6.1/src/opus_decoder.c\0' > "$helper"
audit 14.0 '@rpath/libinside.dylib' "$private_root"
printf '\0%s/build/src/opus_decoder.c\0' "$private_root" > "$helper"
if audit 14.0 '@rpath/libinside.dylib' "$private_root" > "$WORK/audit.out" 2>&1; then
  fail "accepted embedded build path"
fi
grep -Fq 'embedded build path in Contents/Resources/Helpers/Skylight' "$WORK/audit.out" ||
  fail "embedded build path error did not identify the binary"
if grep -Fq "$private_root" "$WORK/audit.out"; then
  fail "the error printed the private build path"
fi

echo "PASS: Mach-O dependency audit rejects support floor, bundle escapes, and embedded build paths"
