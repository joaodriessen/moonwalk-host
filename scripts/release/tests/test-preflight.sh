#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/security" <<'SH'
#!/bin/bash
if [ "$1" = "find-identity" ]; then
  cat <<EOF
  1) AAAA "Apple Development: Test Person (ALPHA12345)"
  2) BBBB "Developer ID Application: Test Person (TEAM123456)"
     2 valid identities found
EOF
  exit 0
fi
if [ "$1" = "find-certificate" ] && [ "$3" = "Example Local Signing" ]; then
  echo "SHA-1 hash: 1234567890ABCDEF1234567890ABCDEF12345678"
  exit 0
fi
exit 64
SH

cat > "$FAKE_BIN/codesign" <<'SH'
#!/bin/bash
if [ "$1" = "-s" ]; then
  identity="$2"
  printf '%s\n' "$identity" > "${FAKE_CODESIGN_IDENTITY_FILE:?}"
  exit 0
fi
if [ "$1" = "-dvv" ]; then
  echo "TeamIdentifier=TEAM123456" >&2
  exit 0
fi
exit 64
SH

cat > "$FAKE_BIN/xcrun" <<'SH'
#!/bin/bash
case "${1:-} ${2:-}" in
  "--find notarytool"|"--find stapler") exit 0 ;;
esac
exit 64
SH

for tool in hdiutil otool install_name_tool realpath vtool; do
  cat > "$FAKE_BIN/$tool" <<'SH'
#!/bin/bash
exit 0
SH
done
chmod +x "$FAKE_BIN"/*

export FAKE_CODESIGN_IDENTITY_FILE="$WORK/codesign-identity"
export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck source=../common.sh
source "$REPO/scripts/release/common.sh"

if require_developer_id "Apple Development: Test Person (ALPHA12345)" >"$WORK/out" 2>&1; then
  fail "Apple Development identity was accepted for release"
fi
assert_contains "$(cat "$WORK/out")" "Developer ID Application"

require_developer_id "Developer ID Application: Test Person (TEAM123456)"
team_id="$(release_team_id "Developer ID Application: Test Person (TEAM123456)")"
[ "$team_id" = "TEAM123456" ] || fail "unexpected Team ID: $team_id"
[ "$(cat "$FAKE_CODESIGN_IDENTITY_FILE")" = "Developer ID Application: Test Person (TEAM123456)" ] || fail "wrong signing identity inspected"

if require_developer_id "Developer ID Application: Missing (MISS123456)" >"$WORK/out" 2>&1; then
  fail "missing identity was accepted"
fi
assert_contains "$(cat "$WORK/out")" "not installed"

CPP_OUT="$WORK/generated_identity.h"
SWIFT_OUT="$WORK/GeneratedIdentity.swift"
"$REPO/macos-dist/generate-identity.sh" \
  --mode release \
  --identity "Developer ID Application: Test Person (TEAM123456)" \
  --cpp-output "$CPP_OUT" \
  --swift-output "$SWIFT_OUT"

cpp="$(cat "$CPP_OUT")"
swift="$(cat "$SWIFT_OUT")"
for generated in "$cpp" "$swift"; do
  assert_contains "$generated" "anchor apple generic"
  assert_contains "$generated" 'certificate leaf[subject.OU] = \"TEAM123456\"'
  assert_not_contains "$generated" "certificate leaf = H"
done
assert_contains "$cpp" 'identifier \"io.github.joaodriessen.skylight\"'
assert_contains "$swift" 'identifier \"io.github.joaodriessen.skylight.host\"'
assert_contains "$swift" 'hostExecutableRelativePath = "Contents/Resources/Helpers/Skylight"'
assert_contains "$swift" 'launchAgentPlistName = "io.github.joaodriessen.skylight.daemon.plist"'

"$REPO/macos-dist/generate-identity.sh" --mode local-bundle --identity "Example Local Signing" \
  --cpp-output "$CPP_OUT" --swift-output "$SWIFT_OUT"
assert_contains "$(cat "$CPP_OUT")" 'identifier \"io.github.joaodriessen.skylight\"'
assert_contains "$(cat "$SWIFT_OUT")" 'identifier \"io.github.joaodriessen.skylight.host\"'
for generated in "$CPP_OUT" "$SWIFT_OUT"; do
  assert_contains "$(cat "$generated")" 'certificate leaf = H\"1234567890abcdef1234567890abcdef12345678\"'
  assert_not_contains "$(cat "$generated")" "anchor apple generic"
done

require_release_tools

echo "PASS: release preflight and generated trust requirements"
