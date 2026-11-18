#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_failure() {
  local fixture="$1"
  local expected="$2"
  if "$REPO/scripts/release/audit-signing.sh" --team-id TEAM123456 "$fixture" >"$WORK/out" 2>&1; then
    fail "$(basename "$fixture") unexpectedly passed"
  fi
  grep -Fq "$expected" "$WORK/out" || fail "$(basename "$fixture") did not report '$expected': $(cat "$WORK/out")"
}

FAKE_BIN="$WORK/bin"
FIXTURES="$WORK/fixtures"
mkdir -p "$FAKE_BIN" "$FIXTURES"
for name in valid unsigned no-runtime debug wrong-team no-timestamp; do
  cp /usr/bin/true "$FIXTURES/$name"
done
mkdir -p "$FIXTURES/Skylight.app/Contents/Resources/Helpers"
cp /usr/bin/true "$FIXTURES/Skylight.app/Contents/Resources/Helpers/Skylight"

cat > "$FAKE_BIN/file" <<'SH'
#!/bin/bash
echo "$2: Mach-O 64-bit executable arm64"
SH

cat > "$FAKE_BIN/codesign" <<'SH'
#!/bin/bash
target="${@: -1}"
name="$(basename "$target")"
case "$1" in
  --verify)
    [ "$name" != "unsigned" ]
    ;;
  -dvv)
    [ "$name" != "unsigned" ] || exit 1
    flags="0x10000(runtime)"
    team="TEAM123456"
    timestamp="Timestamp=Aug 13, 2026 at 12:00:00"
    [ "$name" != "no-runtime" ] || flags="0x0(none)"
    [ "$name" != "wrong-team" ] || team="OTHER12345"
    [ "$name" != "no-timestamp" ] || timestamp=""
    echo "CodeDirectory v=20500 size=533 flags=$flags hashes=5+7 location=embedded" >&2
    if [ "$name" = "Skylight" ]; then
      echo "Identifier=${FAKE_HOST_IDENTIFIER:-io.github.joaodriessen.skylight.host}" >&2
    else
      echo "Identifier=io.github.joaodriessen.skylight" >&2
    fi
    echo "TeamIdentifier=$team" >&2
    [ -z "$timestamp" ] || echo "$timestamp" >&2
    ;;
  -d)
    if [ "$name" = "debug" ]; then
      echo '<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>'
    else
      echo '<plist><dict/></plist>'
    fi
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$FAKE_BIN"/*

export CODESIGN_BIN="$FAKE_BIN/codesign"
export FILE_BIN="$FAKE_BIN/file"

"$REPO/scripts/release/audit-signing.sh" --team-id TEAM123456 "$FIXTURES/valid" >/dev/null
"$REPO/scripts/release/audit-signing.sh" --team-id TEAM123456 "$FIXTURES/Skylight.app" >/dev/null
export FAKE_HOST_IDENTIFIER="wrong.host.identifier"
assert_failure "$FIXTURES/Skylight.app" "host signing identifier"
unset FAKE_HOST_IDENTIFIER
assert_failure "$FIXTURES/unsigned" "invalid or missing signature"
assert_failure "$FIXTURES/no-runtime" "hardened runtime"
assert_failure "$FIXTURES/debug" "get-task-allow"
assert_failure "$FIXTURES/wrong-team" "Team Identifier"
assert_failure "$FIXTURES/no-timestamp" "secure timestamp"

echo "PASS: release signing audit rejects unsafe signatures"
