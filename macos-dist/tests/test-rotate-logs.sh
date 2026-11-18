#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROTATOR="$TEST_DIR/../rotate-logs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_content() {
  local expected="$1" file="$2"
  [ -f "$file" ] || fail "missing $file"
  [ "$(cat "$file")" = "$expected" ] || fail "unexpected content in $file"
}

# Below-threshold files are untouched and do not acquire a generation.
printf 'small' > "$WORK/launchd.out.log"
bash "$ROTATOR" --log-dir "$WORK" --max-bytes 32
assert_content "small" "$WORK/launchd.out.log"
[ ! -e "$WORK/launchd.out.log.1" ] || fail "small log rotated"

# Rotate both streams, shift old generations down, retain exactly three, and truncate the live
# inode so a long-running launchd child can keep writing through its existing descriptor.
printf 'stdout-current-abcdefghijklmnopqrstuvwxyz' > "$WORK/launchd.out.log"
printf 'stdout-one' > "$WORK/launchd.out.log.1"
printf 'stdout-two' > "$WORK/launchd.out.log.2"
printf 'stdout-three' > "$WORK/launchd.out.log.3"
printf 'stderr-current-abcdefghijklmnopqrstuvwxyz' > "$WORK/launchd.err.log"

bash "$ROTATOR" --log-dir "$WORK" --max-bytes 32

[ ! -s "$WORK/launchd.out.log" ] || fail "stdout active log was not truncated"
[ ! -s "$WORK/launchd.err.log" ] || fail "stderr active log was not truncated"
assert_content "stdout-current-abcdefghijklmnopqrstuvwxyz" "$WORK/launchd.out.log.1"
assert_content "stdout-one" "$WORK/launchd.out.log.2"
assert_content "stdout-two" "$WORK/launchd.out.log.3"
assert_content "stderr-current-abcdefghijklmnopqrstuvwxyz" "$WORK/launchd.err.log.1"
[ ! -e "$WORK/launchd.out.log.4" ] || fail "fourth generation retained"

if bash "$ROTATOR" --log-dir "$WORK" --max-bytes nope >/dev/null 2>&1; then
  fail "invalid byte threshold accepted"
fi

echo "log rotation tests: PASS"
