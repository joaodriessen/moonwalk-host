#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

DEV="$WORK/dev"
mkdir -p "$DEV/macos-dist" "$DEV/scripts" "$DEV/home"
cp "$REPO/scripts/build-dev.sh" "$DEV/scripts/"
cp "$REPO/macos-dist/make-bundle.sh" "$REPO/macos-dist/skylight-identity.conf" "$DEV/macos-dist/"
cat > "$DEV/macos-dist/generate-identity.sh" <<'SH'
#!/bin/bash
touch "${DEV_TRIPWIRE:?}"
exit 88
SH
chmod +x "$DEV/macos-dist/generate-identity.sh"
dev_build() { HOME="$DEV/home" DEV_TRIPWIRE="$WORK/dev-started" "$DEV/scripts/build-dev.sh" "$@"; }
dev_build --help > "$WORK/out" 2>&1 || fail "developer help attempted a build"
grep -Fqi usage "$WORK/out" || fail "developer build has no help"
for invalid in --prefix --prefx; do
  rc=0
  dev_build "$invalid" > "$WORK/out" 2>&1 || rc=$?
  [ "$rc" -eq 64 ] || fail "developer build accepted invalid arguments: $invalid"
done
rc=0
dev_build --prefix "$DEV/out" extra > "$WORK/out" 2>&1 || rc=$?
[ "$rc" -eq 64 ] || fail "developer build accepted an extra argument"
[ ! -e "$WORK/dev-started" ] || fail "developer build reached signing with unsupported arguments"

for script in scripts/release.sh scripts/package-release.sh scripts/notarize-release.sh scripts/release/create-dmg.sh scripts/release/verify-artifact.sh; do
  help_output="$("$REPO/$script" --help)"
  grep -Fqi usage <<<"$help_output" || fail "$script has no help"
done

if "$REPO/scripts/package-release.sh" >"$WORK/out" 2>&1; then fail "package release accepted no identity"; fi
grep -Fq -- '--identity is required' "$WORK/out" || fail "missing identity error is unclear"
if "$REPO/scripts/notarize-release.sh" --identity test >"$WORK/out" 2>&1; then fail "notarize accepted no profile"; fi
grep -Fq -- '--notary-profile is required' "$WORK/out" || fail "missing profile error is unclear"

package_help="$($REPO/scripts/package-release.sh --help)"
for option in --output-app --build-dir --with-tests; do
  [[ "$package_help" == *"$option"* ]] || fail "package help omits $option"
done
if SKYLIGHT_RELEASE_DEPS_ROOT="$WORK/unsafe-deps" \
  "$REPO/scripts/package-release.sh" --identity test --output-app "$REPO/build/releases/test/Skylight.app" \
    --build-dir "$REPO/build/releases/test/build" >"$WORK/out" 2>&1; then
  fail "release packaging accepted a dependency-root override"
fi
grep -Fqi 'forbidden' "$WORK/out" || fail "dependency-root override error is unclear"

if "$REPO/scripts/notarize-release.sh" --identity test --notary-profile test \
  --app "$WORK/missing.app" --dmg "$WORK/missing.dmg" >"$WORK/out" 2>&1; then
  fail "notarization accepted missing frozen artifacts"
fi
grep -Fqi 'invalid app' "$WORK/out" || fail "notarization does not validate its app input first"

# Exercise a copied notarization primitive with only Apple/network boundaries
# replaced. A sibling package script is a tripwire: invoking it is a regression.
FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE/scripts/release" "$FIXTURE/app/Contents/MacOS" "$FIXTURE/bin"
cp "$REPO/scripts/notarize-release.sh" "$FIXTURE/scripts/notarize-release.sh"
printf 'binary\n' > "$FIXTURE/app/Contents/MacOS/Skylight"
printf 'dmg\n' > "$FIXTURE/input.dmg"
cat > "$FIXTURE/scripts/package-release.sh" <<'SH'
#!/bin/bash
touch "${PACKAGE_TRIPWIRE:?}"
exit 99
SH
cat > "$FIXTURE/scripts/release/common.sh" <<'SH'
#!/bin/bash
release_team_id() { echo TEAM123456; }
SH
cat > "$FIXTURE/scripts/release/verify-artifact.sh" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$FIXTURE/bin/xcrun" <<'SH'
#!/bin/bash
if [ "${1:-}" = notarytool ] && [ "${2:-}" = submit ]; then
  echo '{"id":"test-submission","status":"Accepted"}'
  exit 0
fi
exit 0
SH
cat > "$FIXTURE/bin/spctl" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$FIXTURE/bin/codesign" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$FIXTURE/scripts/"*.sh "$FIXTURE/scripts/release/"*.sh "$FIXTURE/bin/"*
export PACKAGE_TRIPWIRE="$WORK/package-was-invoked"
PATH="$FIXTURE/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$FIXTURE/scripts/notarize-release.sh" --identity test --notary-profile profile \
    --app "$FIXTURE/app" --dmg "$FIXTURE/input.dmg" >"$WORK/notary-out" 2>&1
[ ! -e "$PACKAGE_TRIPWIRE" ] || fail "notarization rebuilt its frozen input"

TMPDIR="$WORK/dmg-tmp"
mkdir -p "$TMPDIR" "$WORK/dmg-app/Contents"
cat > "$FIXTURE/bin/hdiutil" <<'SH'
#!/bin/bash
exit 23
SH
chmod +x "$FIXTURE/bin/hdiutil"
if TMPDIR="$TMPDIR" PATH="$FIXTURE/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$REPO/scripts/release/create-dmg.sh" "$WORK/dmg-app" "$WORK/out.dmg" >/dev/null 2>&1; then
  fail "DMG creation unexpectedly succeeded with a failing hdiutil"
fi
[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ] || fail "DMG failure leaked temporary files"

echo "PASS: release CLI is explicit and fail-closed"
