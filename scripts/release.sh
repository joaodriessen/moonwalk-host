#!/bin/bash
set -euo pipefail

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -P "$DIR/.." && pwd -P)"
IDENTITY=""
PROFILE=""
ALLOW_DIRTY=0
QUIET=0
RESUME=0
PRINT_FINGERPRINT=0
LOCK=""
PUBLISH_TMP=""
START_SECONDS="$SECONDS"

usage() {
  echo "Usage: $0 --identity ID --notary-profile PROFILE [--resume] [--quiet] [--allow-dirty]"
  echo "       $0 [--allow-dirty] --print-fingerprint"
}

die() { echo "ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; IDENTITY="$2"; shift 2 ;;
    --notary-profile) [ "$#" -ge 2 ] || { usage >&2; exit 64; }; PROFILE="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --resume) RESUME=1; shift ;;
    --print-fingerprint) PRINT_FINGERPRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

cd "$REPO"
[ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$REPO" ] || die "release script is not inside the repository root"
BRANCH="$(git branch --show-current)"
[ "$BRANCH" = main ] || die "releases must be built from main (current branch: ${BRANCH:-detached})"
COMMIT="$(git rev-parse HEAD)"
export COMMIT # preserved through clean source snapshots and into host/menu diagnostics
STATUS="$(git status --porcelain=v1 --untracked-files=all)"
DIRTY=false
if [ -n "$STATUS" ]; then
  DIRTY=true
  [ "$ALLOW_DIRTY" -eq 1 ] || die "working tree is dirty; commit it or use --allow-dirty for a private test artifact"
fi

source_state() {
  git status --porcelain=v1 --untracked-files=all
  git diff --binary HEAD -- .
  git ls-files --others --exclude-standard -z | LC_ALL=C sort -z | while IFS= read -r -d '' path; do
    printf 'untracked=%s\n' "$path"
    [ -f "$path" ] && shasum -a 256 "$path"
  done
}
INITIAL_SOURCE_STATE_SHA="$(source_state | shasum -a 256 | awk '{print $1}')"

source "$REPO/macos-dist/skylight-identity.conf"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || true)"

fingerprint_input() {
  printf 'commit=%s\nbranch=%s\ndirty=%s\nversion=%s\narch=arm64\ntarget=14.0\nidentity=%s\nxcode=%s\nsdk=%s\nsdk_build=%s\n' \
    "$COMMIT" "$BRANCH" "$DIRTY" "$SKYLIGHT_VERSION" "${IDENTITY:-unspecified}" "$XCODE_VERSION" "$SDK_VERSION" "$SDK_BUILD"
  printf 'source_state=%s\n' "$INITIAL_SOURCE_STATE_SHA"
  git ls-files 'scripts/release.sh' 'scripts/package-release.sh' 'scripts/notarize-release.sh' \
    'scripts/release/*.sh' 'macos-dist/skylight-identity.conf' | LC_ALL=C sort | while IFS= read -r path; do
      [ -f "$path" ] && shasum -a 256 "$path"
    done
}

FINGERPRINT="$(fingerprint_input | shasum -a 256 | awk '{print $1}')"
if [ "$PRINT_FINGERPRINT" -eq 1 ]; then
  printf '%s\n' "$FINGERPRINT"
  exit 0
fi

[ -n "$IDENTITY" ] || { echo "ERROR: --identity is required" >&2; usage >&2; exit 64; }
[ -n "$PROFILE" ] || { echo "ERROR: --notary-profile is required" >&2; usage >&2; exit 64; }

RELEASES="$REPO/build/releases"
CANDIDATE="$RELEASES/$FINGERPRINT"
LOGS="$CANDIDATE/logs"
APP="$CANDIDATE/Skylight.app"
BUILD="$CANDIDATE/build"
SOURCE="$CANDIDATE/source"
DMG_NAME="Moonwalk-Host-$SKYLIGHT_VERSION-macOS-arm64.dmg"
DMG="$CANDIDATE/$DMG_NAME"
MANIFEST="$CANDIDATE/release-manifest.json"
STAPLED_DIGEST="$CANDIDATE/stapled-app.sha256"
APP_NOTARY_RESULT="$CANDIDATE/notary-app-result.json"
PUBLISHED="$REPO/build/release/$DMG_NAME"
LOCK="$RELEASES/.release.lock"

mkdir -p "$RELEASES"
if ! mkdir "$LOCK" 2>/dev/null; then
  LOCK_PID="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
    unlink "$LOCK/pid" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || die "stale release lock could not be removed: $LOCK"
    mkdir "$LOCK" || die "release lock could not be reacquired: $LOCK"
  elif [ -n "$LOCK_PID" ]; then
    die "a release is already running (lock: $LOCK)"
  else
    rmdir "$LOCK" 2>/dev/null || die "empty release lock could not be removed: $LOCK"
    mkdir "$LOCK" || die "release lock could not be reacquired: $LOCK"
  fi
fi
printf '%s\n' "$$" > "$LOCK/pid"
cleanup() {
  [ -z "$PUBLISH_TMP" ] || unlink "$PUBLISH_TMP" 2>/dev/null || true
  [ -z "$LOCK" ] || unlink "$LOCK/pid" 2>/dev/null || true
  [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
mkdir -p "$LOGS"

stage() {
  local name="$1"
  shift
  local log="$LOGS/$name.log"
  [ "$QUIET" -eq 1 ] || printf '%-12s ' "$name"
  if "$@" >"$log" 2>&1; then
    [ "$QUIET" -eq 1 ] || echo "ok"
  else
    [ "$QUIET" -eq 1 ] || echo "failed"
    echo "ERROR: stage '$name' failed; log: $log" >&2
    tail -40 "$log" >&2 || true
    exit 1
  fi
}

assert_source_unchanged() {
  local current
  current="$(source_state | shasum -a 256 | awk '{print $1}')"
  if [ "$current" != "$INITIAL_SOURCE_STATE_SHA" ]; then
    echo "ERROR: source changed during release; candidate was not notarized" >&2
    return 1
  fi
}

validate_complete() {
  [ -f "$MANIFEST" ] && [ -d "$APP" ] && [ -f "$DMG" ] || return 1
  [ "$(plutil -extract status raw -o - "$MANIFEST" 2>/dev/null)" = complete ] || return 1
  [ "$(plutil -extract fingerprint raw -o - "$MANIFEST" 2>/dev/null)" = "$FINGERPRINT" ] || return 1
  local expected actual expected_app actual_app
  expected="$(plutil -extract artifact.sha256 raw -o - "$MANIFEST" 2>/dev/null)"
  actual="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || return 1
  expected_app="$(plutil -extract app.finalSha256 raw -o - "$MANIFEST" 2>/dev/null)"
  actual_app="$(release_app_digest "$APP")"
  [ "$expected_app" = "$actual_app" ] || return 1
  "$DIR/release/verify-artifact.sh" --team-id "$TEAM_ID" "$APP" >/dev/null 2>&1 || return 1
  xcrun stapler validate "$APP" >/dev/null 2>&1 || return 1
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || return 1
  spctl --assess --type execute "$APP" >/dev/null 2>&1 || return 1
  spctl --assess --type open --context context:primary-signature "$DMG" >/dev/null 2>&1 || return 1
  "$DIR/release/verify-dmg-payload.sh" "$DMG" "$APP" >/dev/null 2>&1 || return 1
}

stapled_app_is_valid() {
  [ -f "$STAPLED_DIGEST" ] && [ -s "$APP_NOTARY_RESULT" ] &&
    [ "$(cat "$STAPLED_DIGEST")" = "$(release_app_digest "$APP" 2>/dev/null)" ] &&
    [ "$(plutil -extract status raw -o - "$APP_NOTARY_RESULT" 2>/dev/null)" = Accepted ] &&
    xcrun stapler validate "$APP" >/dev/null 2>&1
}

write_manifest() {
  local submitted_app_sha="$1"
  local final_app_sha="$2"
  local submitted_dmg_sha="$3"
  local dmg_sha="$4"
  local resumed="$5"
  local tmp="$MANIFEST.tmp.plist"
  local json_tmp="$MANIFEST.tmp.json"
  plutil -create xml1 "$tmp"
  plutil -insert status -string complete "$tmp"
  plutil -insert fingerprint -string "$FINGERPRINT" "$tmp"
  plutil -insert version -string "$SKYLIGHT_VERSION" "$tmp"
  plutil -insert architecture -string arm64 "$tmp"
  plutil -insert deploymentTarget -string 14.0 "$tmp"
  plutil -insert resumed -bool "$resumed" "$tmp"
  plutil -insert elapsedSeconds -integer "$((SECONDS - START_SECONDS))" "$tmp"
  plutil -insert git -dictionary "$tmp"
  plutil -insert git.commit -string "$COMMIT" "$tmp"
  plutil -insert git.branch -string "$BRANCH" "$tmp"
  plutil -insert git.dirty -bool "$DIRTY" "$tmp"
  plutil -insert toolchain -dictionary "$tmp"
  plutil -insert toolchain.xcode -string "$XCODE_VERSION" "$tmp"
  plutil -insert toolchain.sdkVersion -string "$SDK_VERSION" "$tmp"
  plutil -insert toolchain.sdkBuild -string "$SDK_BUILD" "$tmp"
  plutil -insert dependencies -dictionary "$tmp"
  plutil -insert dependencies.manifest -string "$DEPENDENCY_MANIFEST" "$tmp"
  plutil -insert signing -dictionary "$tmp"
  plutil -insert signing.teamId -string "$TEAM_ID" "$tmp"
  plutil -insert notarization -dictionary "$tmp"
  plutil -insert notarization.id -string "$NOTARY_ID" "$tmp"
  plutil -insert notarization.status -string "$NOTARY_STATUS" "$tmp"
  plutil -insert app -dictionary "$tmp"
  plutil -insert app.submittedSha256 -string "$submitted_app_sha" "$tmp"
  plutil -insert app.finalSha256 -string "$final_app_sha" "$tmp"
  plutil -insert app.notarizationId -string "$APP_NOTARY_ID" "$tmp"
  plutil -insert artifact -dictionary "$tmp"
  plutil -insert artifact.path -string "$DMG" "$tmp"
  plutil -insert artifact.submittedSha256 -string "$submitted_dmg_sha" "$tmp"
  plutil -insert artifact.sha256 -string "$dmg_sha" "$tmp"
  plutil -convert json -o "$json_tmp" "$tmp"
  unlink "$tmp"
  mv -f "$json_tmp" "$MANIFEST"
}

publish_artifact() {
  mkdir -p "$(dirname "$PUBLISHED")"
  PUBLISH_TMP="$(dirname "$PUBLISHED")/.$(basename "$PUBLISHED").tmp"
  cp "$DMG" "$PUBLISH_TMP" || return 1
  mv -f "$PUBLISH_TMP" "$PUBLISHED" || return 1
  PUBLISH_TMP=""
}

emit_result() {
  local resumed="$1"
  local sha
  sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  printf '{"status":"complete","version":"%s","fingerprint":"%s","commit":"%s","dirty":%s,"resumed":%s,"elapsedSeconds":%s,"artifact":"%s","sha256":"%s","manifest":"%s"}\n' \
    "$SKYLIGHT_VERSION" "$FINGERPRINT" "$COMMIT" "$DIRTY" "$resumed" "$((SECONDS - START_SECONDS))" "$PUBLISHED" "$sha" "$MANIFEST"
}

source "$DIR/release/common.sh"
stage preflight "$DIR/release/preflight.sh" --identity "$IDENTITY"
TEAM_ID="$(release_team_id "$IDENTITY")"
DEPENDENCY_MANIFEST="$("$DIR/release/build-dependencies.sh" --print-manifest)"

if [ "$RESUME" -eq 1 ] && validate_complete; then
  stage publish publish_artifact
  emit_result true
  exit 0
fi

if [ "$RESUME" -eq 1 ] && [ -f "$CANDIDATE/build.complete" ] && [ -f "$CANDIDATE/build-app.sha256" ] && \
   { stapled_app_is_valid ||
     [ "$(cat "$CANDIDATE/build-app.sha256")" = "$(release_app_digest "$APP" 2>/dev/null || true)" ]; } && \
   "$DIR/release/verify-artifact.sh" --team-id "$TEAM_ID" "$APP" >/dev/null 2>&1; then
  [ "$QUIET" -eq 1 ] || echo "build        reused"
else
  unlink "$STAPLED_DIGEST" 2>/dev/null || true
  if [ "$DIRTY" = false ]; then
    prepare_source() {
      local tmp="$SOURCE.staging.$$"
      rm -rf "$tmp" || return 1
      mkdir -p "$tmp" || return 1
      git archive "$COMMIT" | tar -xf - -C "$tmp" || return 1
      mkdir -p "$tmp/build" "$REPO/build/release-deps" || return 1
      ln -s "$REPO/build/release-deps" "$tmp/build/release-deps" || return 1
      rm -rf "$SOURCE" || return 1
      mv "$tmp" "$SOURCE"
    }
    stage snapshot prepare_source
    SNAPSHOT_APP="$SOURCE/build/releases/$FINGERPRINT/Skylight.app"
    SNAPSHOT_BUILD="$SOURCE/build/releases/$FINGERPRINT/build"
    stage build "$SOURCE/scripts/package-release.sh" --identity "$IDENTITY" --output-app "$SNAPSHOT_APP" --build-dir "$SNAPSHOT_BUILD" --with-tests
    rm -rf "$APP"
    mv "$SNAPSHOT_APP" "$APP"
  else
    stage build "$DIR/package-release.sh" --identity "$IDENTITY" --output-app "$APP" --build-dir "$BUILD" --with-tests
  fi
  release_app_digest "$APP" > "$CANDIDATE/build-app.sha256"
  touch "$CANDIDATE/build.complete"
fi

stage source assert_source_unchanged
SUBMITTED_APP_SHA="$(cat "$CANDIDATE/build-app.sha256")"
if [ "$RESUME" -eq 1 ] && stapled_app_is_valid; then
  [ "$QUIET" -eq 1 ] || echo "notarize-app reused"
else
  stage notarize-app "$DIR/notarize-release.sh" --identity "$IDENTITY" --notary-profile "$PROFILE" --app "$APP"
  release_app_digest "$APP" > "$STAPLED_DIGEST"
fi
FINAL_APP_SHA="$(cat "$STAPLED_DIGEST")"
create_signed_dmg() {
  "$DIR/release/create-dmg.sh" --replace --expected-app-sha "$FINAL_APP_SHA" "$APP" "$DMG" || return 1
  [ "$(release_app_digest "$APP")" = "$FINAL_APP_SHA" ] || {
    echo "ERROR: frozen app changed while creating the DMG" >&2
    return 1
  }
  codesign -s "$IDENTITY" --timestamp "$DMG"
}
stage dmg create_signed_dmg
SUBMITTED_DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
stage notarize-dmg "$DIR/notarize-release.sh" --identity "$IDENTITY" --notary-profile "$PROFILE" --dmg "$DMG"
stage verify-payload "$DIR/release/verify-dmg-payload.sh" "$DMG" "$APP"

DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
APP_NOTARY_ID="$(plutil -extract id raw -o - "$APP_NOTARY_RESULT")"
NOTARY_ID="$(plutil -extract id raw -o - "$CANDIDATE/notary-result.json")"
NOTARY_STATUS="$(plutil -extract status raw -o - "$CANDIDATE/notary-result.json")"
write_manifest "$SUBMITTED_APP_SHA" "$FINAL_APP_SHA" "$SUBMITTED_DMG_SHA" "$DMG_SHA" false
stage publish publish_artifact
emit_result false
