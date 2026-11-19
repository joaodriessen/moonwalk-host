#!/bin/bash
set -euo pipefail

SOURCE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$SOURCE_REPO/scripts/release.sh" ] || fail "release orchestrator is missing or not executable"

REPO="$WORK/repo with a \"quote\""
mkdir -p "$REPO/scripts/release" "$REPO/macos-dist" "$REPO/bin"
SHASUM_DIR="$(dirname "$(command -v shasum)")"
cp "$SOURCE_REPO/scripts/release.sh" "$REPO/scripts/release.sh"
cp "$SOURCE_REPO/scripts/release/make-release-receipt.py" "$REPO/scripts/release/make-release-receipt.py"
cat > "$REPO/macos-dist/skylight-identity.conf" <<'EOF'
SKYLIGHT_VERSION=9.8.7-test
SKYLIGHT_BUNDLE_ID=example.skylight
EOF
echo 'build/' > "$REPO/.gitignore"

cat > "$REPO/scripts/release/preflight.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$REPO/scripts/release/common.sh" <<'EOF'
#!/bin/bash
release_team_id() { echo TESTTEAM01; }
release_app_digest() {
  (cd "$1" && find . -type f -print | sort | xargs shasum -a 256) | shasum -a 256 | awk '{print $1}'
}
EOF
cat > "$REPO/scripts/package-release.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
app=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-app) app="$2"; shift 2 ;;
    --identity|--build-dir) shift 2 ;;
    --with-tests) shift ;;
    *) exit 64 ;;
  esac
done
[ -n "$app" ]
# A clean candidate uses the shared dependency cache through a symlink.
# Exercise directory creation there before writing the mock bundle.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -L "$repo/build/release-deps" ]; then
  mkdir -p "$repo/build/release-deps/fixture"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Helpers"
printf 'signed-app\n' > "$app/Contents/MacOS/Skylight"
source "$repo/macos-dist/skylight-identity.conf"
version_commit="$COMMIT"
if [ "${SKYLIGHT_FAKE_WRONG_SOURCE:-0}" = 1 ]; then
  version_commit=0123456789abcdef0123456789abcdef01234567
fi
cat > "$app/Contents/Resources/Helpers/Skylight" <<CLI
#!/bin/bash
test "\$1" = --version || exit 64
echo "Moonwalk Host $SKYLIGHT_VERSION source $version_commit"
CLI
chmod +x "$app/Contents/Resources/Helpers/Skylight"
count_file="${SKYLIGHT_FAKE_COUNTS:?}/package"
count=0; [ ! -f "$count_file" ] || count="$(cat "$count_file")"
echo $((count + 1)) > "$count_file"
[ "${SKYLIGHT_FAKE_MUTATE_SOURCE:-0}" != 1 ] || echo '# changed during build' >> "${SKYLIGHT_FAKE_SOURCE_TO_MUTATE:?}"
EOF
cat > "$REPO/scripts/release/create-dmg.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = "--replace" ] && shift
[ "${1:-}" = "--expected-app-sha" ] && shift 2
[ -f "$1/Contents/CodeResources" ] || { echo "fixture app must be stapled before DMG creation" >&2; exit 1; }
printf 'signed-dmg\n' > "$2"
EOF
cat > "$REPO/scripts/notarize-release.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
app="" dmg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dmg) dmg="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --identity|--notary-profile) shift 2 ;;
    *) exit 64 ;;
  esac
done
if [ -z "$dmg" ]; then
  printf 'stapled-ticket\n' > "$app/Contents/CodeResources"
  printf '{"id":"fixture-app-submission","status":"Accepted"}\n' > "$(dirname "$app")/notary-app-result.json"
  count_file="${SKYLIGHT_FAKE_COUNTS:?}/notarize-app"
else
  printf '{"id":"fixture-submission","status":"Accepted"}\n' > "$(dirname "$dmg")/notary-result.json"
  count_file="${SKYLIGHT_FAKE_COUNTS:?}/notarize"
fi
count=0; [ ! -f "$count_file" ] || count="$(cat "$count_file")"
echo $((count + 1)) > "$count_file"
EOF
cat > "$REPO/scripts/release/verify-artifact.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$REPO/scripts/release/verify-dmg-payload.sh" <<'EOF'
#!/bin/bash
set -e
[ -f "$1" ] && [ -f "$2/Contents/CodeResources" ]
EOF
cat > "$REPO/scripts/release/build-dependencies.sh" <<'EOF'
#!/bin/bash
if [ "${1:-}" = --print-manifest ]; then
  printf 'deployment_target=14.0\nfixture=1 sha256=test\n'
  exit 0
fi
exit 64
EOF

cat > "$REPO/bin/xcodebuild" <<'EOF'
#!/bin/bash
printf 'Xcode 26.0\nBuild version TEST\n'
EOF
cat > "$REPO/bin/xcrun" <<'EOF'
#!/bin/bash
case "$*" in
  *--show-sdk-version*) echo 26.0 ;;
  *--show-sdk-build-version*) echo TESTSDK ;;
  *stapler*validate*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$REPO/bin/codesign" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$REPO/bin/spctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$REPO/scripts/release.sh" "$REPO/scripts/package-release.sh" \
  "$REPO/scripts/notarize-release.sh" "$REPO/scripts/release/"*.sh "$REPO/bin/"*

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add .
git -C "$REPO" commit -qm initial

export PATH="$REPO/bin:$SHASUM_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
export SKYLIGHT_FAKE_COUNTS="$WORK/counts"
export SKYLIGHT_FAKE_SOURCE_TO_MUTATE="$REPO/macos-dist/skylight-identity.conf"
mkdir -p "$SKYLIGHT_FAKE_COUNTS"

fingerprint1="$(cd "$REPO" && scripts/release.sh --print-fingerprint)"
fingerprint2="$(cd "$REPO" && scripts/release.sh --print-fingerprint)"
[[ "$fingerprint1" =~ ^[0-9a-f]{64}$ ]] || fail "fingerprint is not a SHA-256"
[ "$fingerprint1" = "$fingerprint2" ] || fail "unchanged source produced an unstable fingerprint"
signer_a="$(cd "$REPO" && scripts/release.sh --identity signer-a --print-fingerprint)"
signer_b="$(cd "$REPO" && scripts/release.sh --identity signer-b --print-fingerprint)"
[ "$signer_a" != "$signer_b" ] || fail "signing identity did not alter the fingerprint"

echo dirty > "$REPO/untracked"
if (cd "$REPO" && scripts/release.sh --print-fingerprint) >"$WORK/out" 2>&1; then
  fail "dirty source was accepted by default"
fi
grep -Fqi 'dirty' "$WORK/out" || fail "dirty-source error is unclear"
dirty_fingerprint="$(cd "$REPO" && scripts/release.sh --allow-dirty --print-fingerprint)"
[ "$dirty_fingerprint" != "$fingerprint1" ] || fail "dirty source did not alter the fingerprint"
rm "$REPO/untracked"

mkdir -p "$REPO/build/releases/.release.lock"
echo $$ > "$REPO/build/releases/.release.lock/pid"
if (cd "$REPO" && scripts/release.sh --identity test --notary-profile test --quiet) >"$WORK/out" 2>&1; then
  fail "concurrent release lock was ignored"
fi
grep -Fqi 'release is already running' "$WORK/out" || fail "lock error is unclear"
rm "$REPO/build/releases/.release.lock/pid"
rmdir "$REPO/build/releases/.release.lock"

mkdir -p "$REPO/build/releases/.release.lock"

json="$(cd "$REPO" && scripts/release.sh --identity test --notary-profile test --quiet)"
[ "$(printf '%s' "$json" | plutil -extract status raw -o - -- -)" = "complete" ] || fail "quiet result is not successful JSON"
published_path="$(printf '%s' "$json" | plutil -extract artifact raw -o - -- -)"
[ "$published_path" -ef "$REPO/build/release/Moonwalk-Host-9.8.7-test-macOS-arm64.dmg" ] || fail "quiet result corrupted the artifact path"
release_fingerprint="$(printf '%s' "$json" | plutil -extract fingerprint raw -o - -- -)"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/package")" = 1 ] || fail "package stage count is wrong"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/notarize-app")" = 1 ] || fail "app notarize stage count is wrong"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/notarize")" = 1 ] || fail "notarize stage count is wrong"
[ -d "$REPO/build/release-deps/fixture" ] || fail "clean snapshot did not use the shared dependency cache"
[ ! -e "$REPO/build/releases/$release_fingerprint/source" ] || fail "completed release retained its build snapshot"

manifest="$REPO/build/releases/$release_fingerprint/release-manifest.json"
[ -f "$manifest" ] || fail "release manifest was not written"
[ "$(plutil -extract git.dirty raw -o - "$manifest")" = false ] || fail "manifest did not record clean source"
[ "$(plutil -extract fingerprint raw -o - "$manifest")" = "$release_fingerprint" ] || fail "manifest fingerprint is wrong"
[ -n "$(plutil -extract artifact.sha256 raw -o - "$manifest")" ] || fail "artifact digest is missing"
[ -n "$(plutil -extract artifact.submittedSha256 raw -o - "$manifest")" ] || fail "submitted artifact digest is missing"
[ "$(plutil -extract app.notarizationId raw -o - "$manifest")" = fixture-app-submission ] || fail "app notarization is missing"
[ -f "$REPO/build/release/Moonwalk-Host-9.8.7-test-macOS-arm64.dmg" ] || fail "conventional DMG was not published"
[ ! -e "$REPO/build/release/.Moonwalk-Host-9.8.7-test-macOS-arm64.dmg.tmp" ] || fail "publication left a temporary artifact"

image="$REPO/build/release/Moonwalk-Host-9.8.7-test-macOS-arm64.dmg"
receipt="$WORK/release-receipt.json"
python3 "$REPO/scripts/release/make-release-receipt.py" "$manifest" "$image" > "$receipt"
[ "$(plutil -extract source_commit raw -o - "$receipt")" = "$(git -C "$REPO" rev-parse HEAD)" ] || fail "receipt source revision is wrong"
[ "$(plutil -extract artifact.sha256 raw -o - "$receipt")" = "$(shasum -a 256 "$image" | awk '{print $1}')" ] || fail "receipt checksum is wrong"
if grep -Eq 'signing|notarization|fixture-app-submission|fixture-submission|/private/tmp|/Users' "$receipt"; then
  fail "receipt contains private build metadata"
fi
mkdir "$WORK/mixed-candidate"
altered_image="$WORK/mixed-candidate/$(basename "$image")"
printf 'unrelated candidate bytes\n' > "$altered_image"
if python3 "$REPO/scripts/release/make-release-receipt.py" "$manifest" "$altered_image" > "$WORK/bad-receipt.json" 2> "$WORK/out"; then
  fail "receipt accepted an image from another build"
fi
grep -Fq 'checksum differs' "$WORK/out" || fail "receipt mismatch error is unclear"
[ ! -s "$WORK/bad-receipt.json" ] || fail "failed receipt emitted public metadata"

resume_json="$(cd "$REPO" && scripts/release.sh --identity test --notary-profile test --quiet --resume)"
[ "$(printf '%s' "$resume_json" | plutil -extract resumed raw -o - -- -)" = true ] || fail "resume was not reported"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/package")" = 1 ] || fail "resume rebuilt a verified app"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/notarize-app")" = 1 ] || fail "resume resubmitted a verified app"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/notarize")" = 1 ] || fail "resume resubmitted a verified DMG"

printf 'tampered\n' >> "$REPO/build/releases/$release_fingerprint/Skylight.app/Contents/MacOS/Skylight"
(cd "$REPO" && scripts/release.sh --identity test --notary-profile test --quiet --resume) >/dev/null
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/package")" = 2 ] || fail "corrupted resumed app was not rebuilt"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/notarize")" = 2 ] || fail "corrupted resumed app reused old notarization"

published="$REPO/build/release/Moonwalk-Host-9.8.7-test-macOS-arm64.dmg"
published_before="$(shasum -a 256 "$published" | awk '{print $1}')"
mkdir -p "$WORK/failbin"
cat > "$WORK/failbin/cp" <<'SH'
#!/bin/bash
exit 23
SH
chmod +x "$WORK/failbin/cp"
if (cd "$REPO" && PATH="$WORK/failbin:$PATH" scripts/release.sh \
  --identity test --notary-profile test --quiet --resume) >"$WORK/out" 2>&1; then
  fail "publication succeeded when its copy failed"
fi
[ "$(shasum -a 256 "$published" | awk '{print $1}')" = "$published_before" ] || fail "failed publication damaged the previous artifact"

wrong_identity_before="$(cat "$SKYLIGHT_FAKE_COUNTS/notarize-app")"
if (cd "$REPO" && SKYLIGHT_FAKE_WRONG_SOURCE=1 scripts/release.sh \
  --identity test --notary-profile test --quiet) >"$WORK/out" 2>&1; then
  fail "a daemon from a different source revision was accepted"
fi
grep -Fq "packaged daemon does not match the release version and source revision" "$WORK/out" ||
  fail "daemon identity mismatch error is unclear"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/notarize-app")" = "$wrong_identity_before" ] ||
  fail "the mismatched daemon reached notarization"
[ "$(shasum -a 256 "$published" | awk '{print $1}')" = "$published_before" ] ||
  fail "the mismatched daemon replaced the previous artifact"

export SKYLIGHT_FAKE_MUTATE_SOURCE=1
if (cd "$REPO" && scripts/release.sh --identity test --notary-profile test --quiet) >"$WORK/out" 2>&1; then
  fail "release accepted source changes made during the build"
fi
grep -Fqi 'source changed during release' "$WORK/out" || fail "mid-build source change error is unclear"
[ "$(cat "$SKYLIGHT_FAKE_COUNTS/notarize")" = 2 ] || fail "changed source reached notarization"
[ -d "$REPO/build/releases/$release_fingerprint/source" ] || fail "failed build lost its snapshot for diagnosis"

echo "PASS: release orchestration is clean, locked, resumable, and compact"
