#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/.." && pwd -P)"
IDENTITY=""
JOBS="${SKYLIGHT_BUILD_JOBS:-6}"
APP=""
BUILD=""
WITH_TESTS=0
WITH_DEVICE_TESTS=0
DEVELOPER=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity|--output-app|--build-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: $1 requires a value" >&2; exit 64; }
      ;;
  esac
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --output-app) APP="$2"; shift 2 ;;
    --build-dir) BUILD="$2"; shift 2 ;;
    --developer) DEVELOPER=1; shift ;;
    --with-tests) WITH_TESTS=1; shift ;;
    --with-device-tests) WITH_TESTS=1; WITH_DEVICE_TESTS=1; shift ;;
    -h|--help) echo "Usage: $0 --identity ID --output-app APP --build-dir BUILD [--with-tests | --with-device-tests]"; echo "       $0 --developer [--identity ID] --output-app APP --build-dir BUILD"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
  esac
done
[ "$DEVELOPER" -eq 1 ] || [ -n "$IDENTITY" ] || { echo "ERROR: --identity is required for release packaging" >&2; exit 64; }
[ -n "$APP" ] || { echo "ERROR: --output-app is required" >&2; exit 64; }
[ -n "$BUILD" ] || { echo "ERROR: --build-dir is required" >&2; exit 64; }
[ -z "${SKYLIGHT_RELEASE_DEPS_ROOT:-}" ] || {
  echo "ERROR: SKYLIGHT_RELEASE_DEPS_ROOT is forbidden for release packaging" >&2
  exit 1
}

source "$REPO/macos-dist/skylight-identity.conf"
source "$DIR/release/common.sh"
if [ "$DEVELOPER" -eq 1 ]; then
  [ ! -f "$REPO/macos-dist/skylight-identity.local.conf" ] || source "$REPO/macos-dist/skylight-identity.local.conf"
  IDENTITY="${IDENTITY:-$SKYLIGHT_SIGNING_IDENTITY}"
  case "$APP" in "$REPO/build/dev/Skylight.app") ;; *) echo "ERROR: developer app must stay under build/dev" >&2; exit 64 ;; esac
  case "$BUILD" in "$REPO/build/dev-compile") ;; *) echo "ERROR: developer build must stay under build/dev-compile" >&2; exit 64 ;; esac
  for directory in "$REPO/build" "$REPO/build/dev" "$BUILD"; do
    [ ! -L "$directory" ] || { echo "ERROR: developer output directories cannot be symbolic links" >&2; exit 64; }
  done
  require_release_tools
  "$REPO/macos-dist/generate-identity.sh" --mode local-bundle --identity "$IDENTITY"
else
  "$DIR/release/preflight.sh" --identity "$IDENTITY"
  "$REPO/macos-dist/generate-identity.sh" --mode release --identity "$IDENTITY"
fi
SOURCE_REVISION="${COMMIT:-$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf unknown)}"
DEPS_ROOT="$("$DIR/release/build-dependencies.sh" --print-root)"
"$DIR/release/build-dependencies.sh"
"$DIR/release/build-ffmpeg.sh"
FFMPEG_PREFIX="$("$DIR/release/build-ffmpeg.sh" --print-prefix)"

DEPS="$DEPS_ROOT/prefix"
case "$BUILD" in "$REPO/build/"*) ;; *) echo "ERROR: build directory must stay under $REPO/build" >&2; exit 1 ;; esac
case "$APP" in
  "$REPO/build/release/Skylight.app"|"$REPO/build/releases/"*/Skylight.app) ;;
  "$REPO/build/dev/Skylight.app") [ "$DEVELOPER" -eq 1 ] || { echo "ERROR: release output cannot use the developer path" >&2; exit 1; } ;;
  *) echo "ERROR: output app must be a release path under $REPO/build" >&2; exit 1 ;;
esac
OUTPUT_APP="$APP"
APP="$OUTPUT_APP.staging.$$"
cleanup_staging() {
  case "$APP" in "$OUTPUT_APP.staging."*) rm -rf "$APP" ;; esac
}
trap cleanup_staging EXIT INT TERM
BUILD_TESTS=OFF
[ "$WITH_TESTS" -eq 1 ] && BUILD_TESTS=ON
PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" \
  cmake -S "$REPO" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DSKYLIGHT_MAP_SOURCE_PATHS=ON \
    -DCMAKE_PREFIX_PATH="$DEPS" \
    -DOPENSSL_ROOT_DIR="$DEPS" \
    -DOPENSSL_CRYPTO_LIBRARY="$DEPS/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$DEPS/lib/libssl.a" \
    -DOPENSSL_INCLUDE_DIR="$DEPS/include" \
    -DCMAKE_DISABLE_FIND_PACKAGE_Boost=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_nlohmann_json=TRUE \
    -DBOOST_USE_STATIC=ON \
    -DBOOST_LOCALE_ENABLE_ICU=OFF \
    -DBOOST_LOCALE_ENABLE_ICONV=OFF \
    -DBUILD_TESTS="$BUILD_TESTS" -DBUILD_DOCS=OFF \
    -DFFMPEG_PREPARED_BINARIES="$FFMPEG_PREFIX" \
    -DSKYLIGHT_VERSION="$SKYLIGHT_VERSION" \
    -DSUNSHINE_ASSETS_DIR=/Applications/Skylight.app/Contents/Resources/assets
cmake --build "$BUILD" -j "$JOBS"
if [ "$WITH_TESTS" -eq 1 ]; then
  TEST_BINARY="$BUILD/tests/test_sunshine"
  [ -x "$TEST_BINARY" ] || {
    echo "ERROR: C++ test binary is missing: $TEST_BINARY" >&2
    exit 1
  }
  TEST_ROOT="$(mktemp -d "$BUILD/tests-private.XXXXXX")"
  mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/config" "$TEST_ROOT/cache" "$TEST_ROOT/data" "$TEST_ROOT/state" "$TEST_ROOT/runtime" "$TEST_ROOT/tmp" "$TEST_ROOT/coverage-list" "$TEST_ROOT/coverage-run"
  TEST_ENV=("HOME=$TEST_ROOT/home" "XDG_CONFIG_HOME=$TEST_ROOT/config" "XDG_CACHE_HOME=$TEST_ROOT/cache"
            "XDG_DATA_HOME=$TEST_ROOT/data" "XDG_STATE_HOME=$TEST_ROOT/state" "XDG_RUNTIME_DIR=$TEST_ROOT/runtime"
            "TMPDIR=$TEST_ROOT/tmp/" "DBUS_SESSION_BUS_ADDRESS=unix:path=$TEST_ROOT/no-session-bus")
  # These upstream fixtures initialize the real XPC/platform owner, move the
  # mouse and capture audio/video. Ordinary packaging verifies the logic suite;
  # device fixtures belong to a separately guarded native session.
  TEST_FILTER='-MouseInputs/*:Configurations/AudioTest.*:EncoderVariants/*'
  [ "$WITH_DEVICE_TESTS" -eq 0 ] || TEST_FILTER='*'
  printf '%s\n' "$TEST_FILTER" > "$TEST_ROOT/filter.txt"
  (cd "$TEST_ROOT" && env "${TEST_ENV[@]}" GCOV_PREFIX="$TEST_ROOT/coverage-list" "$TEST_BINARY" --gtest_list_tests > discovery-all.log)
  TEST_COUNT="$(cd "$TEST_ROOT" && env "${TEST_ENV[@]}" GCOV_PREFIX="$TEST_ROOT/coverage-list" "$TEST_BINARY" "--gtest_filter=$TEST_FILTER" --gtest_list_tests | tee discovery.log | awk '/^  / { count++ } END { print count + 0 }')"
  [ "$TEST_COUNT" -gt 0 ] || { echo "ERROR: C++ test binary discovered zero tests" >&2; exit 1; }
  (cd "$TEST_ROOT" && env "${TEST_ENV[@]}" GCOV_PREFIX="$TEST_ROOT/coverage-run" "$TEST_BINARY" "--gtest_filter=$TEST_FILTER" --gtest_brief=1 --gtest_output="xml:$TEST_ROOT/results.xml")
  swift test --package-path "$REPO/macos-dist/SkylightMenu"
fi

(cd "$REPO/macos-dist/SkylightMenu" && swift build -c release \
  -Xswiftc -debug-prefix-map -Xswiftc "$REPO=.")
MENU_BIN="$REPO/macos-dist/SkylightMenu/.build/release/SkylightMenu"
HOST_BIN="$BUILD/sunshine"
[ -f "$MENU_BIN" ] || { echo "ERROR: menu executable was not built" >&2; exit 1; }
[ -e "$HOST_BIN" ] || { echo "ERROR: host executable was not built" >&2; exit 1; }
[ -f "$BUILD/vd_helper" ] || { echo "ERROR: virtual-display helper was not built" >&2; exit 1; }

cleanup_staging
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/Helpers" \
  "$APP/Contents/Frameworks" \
  "$APP/Contents/Library/LaunchAgents"
cp "$MENU_BIN" "$APP/Contents/MacOS/Skylight"
cp -L "$HOST_BIN" "$APP/Contents/Resources/Helpers/Skylight"
cp "$BUILD/vd_helper" "$APP/Contents/Resources/Helpers/vd_helper"
strip -S "$APP/Contents/MacOS/Skylight"
strip -S "$APP/Contents/Resources/Helpers/Skylight"
strip -S "$APP/Contents/Resources/Helpers/vd_helper"
cp "$REPO/sunshine.icns" "$APP/Contents/Resources/sunshine.icns"
"$REPO/macos-dist/compile-app-icon.sh" "$APP"
cp "$REPO/src_assets/common/assets/web/config_schema.json" "$APP/Contents/Resources/config_schema.json"
# The menu app's Lucide glyphs, loaded from Bundle.main as template PDFs (Lucide.swift).
cp -R "$REPO/macos-dist/SkylightMenu/Lucide/pdf" "$APP/Contents/Resources/Lucide"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$REPO/NOTICE" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
python3 "$DIR/release/install-notices.py" "$DEPS_ROOT" "$(dirname "$FFMPEG_PREFIX")" "$BUILD" \
  "$APP/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$APP/Contents/Resources/Defaults"
cp "$REPO/macos-dist/sunshine.conf.example" "$APP/Contents/Resources/Defaults/sunshine.conf"
cp "$REPO/src_assets/macos/assets/apps.json" "$APP/Contents/Resources/Defaults/apps.json"
[ -d "$BUILD/assets" ] && cp -R "$BUILD/assets" "$APP/Contents/Resources/assets"
rm -f "$APP/Contents/Resources/assets/Info.plist"   # upstream CPack template; dead in our bundle

sed \
  -e "s|@DAEMON_LABEL@|$SKYLIGHT_DAEMON_LABEL|g" \
  -e "s|@XPC_SERVICE@|$SKYLIGHT_XPC_SERVICE|g" \
  "$REPO/macos-dist/launch-agents/io.github.joaodriessen.skylight.daemon.plist.in" \
  > "$APP/Contents/Library/LaunchAgents/$SKYLIGHT_LAUNCH_AGENT_PLIST_NAME"

# The app is called Moonwalk Host, but the bundle stays Skylight.app: the daemon bakes
# /Applications/Skylight.app into its asset path, and installs, rollbacks and macOS's records of
# the background service all know it by that path. Finder, Launchpad and Spotlight show the
# localized name instead, which they only do when the plain CFBundleDisplayName matches the
# file name, so that stays Skylight and en.lproj carries Moonwalk Host.
mkdir -p "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"CFBundleName" = "Moonwalk Host";
"CFBundleDisplayName" = "Moonwalk Host";
STRINGS

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Skylight</string>
  <key>CFBundleDisplayName</key><string>Skylight</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIdentifier</key><string>$SKYLIGHT_BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>SkylightSourceRevision</key><string>$SOURCE_REVISION</string>
  <key>CFBundleShortVersionString</key><string>$SKYLIGHT_VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Skylight</string>
  <key>CFBundleIconFile</key><string>sunshine</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Moonwalk Host uses the audio source you select to stream sound and test its signal.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Moonwalk and Moonlight use your local network to find and connect to this Mac.</string>
</dict></plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/en.lproj/InfoPlist.strings" "$APP/Contents/Library/LaunchAgents/$SKYLIGHT_LAUNCH_AGENT_PLIST_NAME"
"$DIR/release/bundle-libraries.sh" "$APP" \
  "$APP/Contents/MacOS/Skylight" \
  "$APP/Contents/Resources/Helpers/Skylight" \
  "$APP/Contents/Resources/Helpers/vd_helper"
"$DIR/release/audit-dependencies.sh" "$APP"
"$DIR/release/tests/test-app-layout.sh" "$APP"

signing_options=(--force --options runtime)
if [ "$DEVELOPER" -eq 1 ]; then signing_options+=(--timestamp=none); else signing_options+=(--timestamp); fi
codesign -s "$IDENTITY" -i "${SKYLIGHT_BUNDLE_ID}.vd_helper" "${signing_options[@]}" \
  --entitlements "$REPO/macos-dist/entitlements/release-helper.plist" "$APP/Contents/Resources/Helpers/vd_helper"
codesign -s "$IDENTITY" -i "$SKYLIGHT_HOST_BUNDLE_ID" "${signing_options[@]}" \
  --entitlements "$REPO/macos-dist/entitlements/release-host.plist" "$APP/Contents/Resources/Helpers/Skylight"
codesign -s "$IDENTITY" -i "$SKYLIGHT_BUNDLE_ID" "${signing_options[@]}" \
  --entitlements "$REPO/macos-dist/entitlements/release-menu.plist" "$APP/Contents/MacOS/Skylight"
codesign -s "$IDENTITY" "${signing_options[@]}" \
  --entitlements "$REPO/macos-dist/entitlements/release-menu.plist" "$APP"
if [ "$DEVELOPER" -eq 1 ]; then
  codesign --verify --deep --strict "$APP"
else
  "$DIR/release/audit-signing.sh" --team-id "$(release_team_id "$IDENTITY")" "$APP"
fi

if [ -e "$OUTPUT_APP" ]; then
  case "$OUTPUT_APP" in
    "$REPO/build/release/Skylight.app"|"$REPO/build/releases/"*/Skylight.app) rm -rf "$OUTPUT_APP" ;;
    "$REPO/build/dev/Skylight.app") [ "$DEVELOPER" -eq 1 ] && rm -rf "$OUTPUT_APP" ;;
    *) exit 1 ;;
  esac
fi
mv "$APP" "$OUTPUT_APP"
APP="$OUTPUT_APP"
trap - EXIT INT TERM
echo "Signed portable app assembled at $OUTPUT_APP"
