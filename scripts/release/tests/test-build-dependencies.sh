#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$REPO/scripts/release/build-dependencies.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
manifest="$($SCRIPT --print-manifest)"

for expected in \
  'deployment_target=14.0' \
  'openssl=3.5.9 sha256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a' \
  'opus=1.6.1 sha256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1' \
  'miniupnpc=2.3.5 sha256=b9a1e57233216c5f62572de6d628e73e910f50cdb71e9c0eb89b169ce154d256'; do
  [[ "$manifest" == *"$expected"* ]] || fail "manifest missing: $expected"
done

printf 'not the expected archive' > "$WORK/archive"
if "$SCRIPT" --verify-file 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a "$WORK/archive" >"$WORK/out" 2>&1; then
  fail "bad dependency archive was accepted"
fi
grep -Fq 'checksum mismatch' "$WORK/out" || fail "checksum failure was not actionable"

actual="$(shasum -a 256 "$WORK/archive" | awk '{print $1}')"
"$SCRIPT" --verify-file "$actual" "$WORK/archive"

cmake_args="$($SCRIPT --print-cmake-args)"
for required_arg in OPENSSL_CRYPTO_LIBRARY OPENSSL_SSL_LIBRARY OPENSSL_INCLUDE_DIR; do
  [[ "$cmake_args" == *"-D$required_arg="* ]] || fail "release CMake args do not pin $required_arg"
done

cache_root="$($SCRIPT --print-root)"
case "$cache_root" in
  "$REPO/build/release-deps/"????????????????????????????????????????????????????????????????) ;;
  *) fail "dependency cache root is not content-addressed: $cache_root" ;;
esac

FIXTURE="$WORK/repo/scripts/release"
mkdir -p "$FIXTURE"
cp "$SCRIPT" "$REPO/scripts/release/build-ffmpeg.sh" "$REPO/scripts/release/common.sh" "$FIXTURE/"
root_before="$("$FIXTURE/build-dependencies.sh" --print-root)"
printf '\n# recipe mutation\n' >> "$FIXTURE/build-dependencies.sh"
root_after="$("$FIXTURE/build-dependencies.sh" --print-root)"
[ "$root_before" != "$root_after" ] || fail "dependency recipe change did not invalidate the cache"

(
  source "$REPO/scripts/release/common.sh"
  printf 'truncated prior download' > "$WORK/cached"
  printf 'complete dependency archive' > "$WORK/expected"
  expected="$(shasum -a 256 "$WORK/expected" | awk '{print $1}')"
  curl() {
    # The last two parameters are the destination and source URL.
    output="${@: -2:1}"
    [ "$output" != "$WORK/cached" ] || fail "downloader writes directly into the cache"
    case "$download" in
      interrupted) printf 'partial bytes' > "$output"; return 18 ;;
      invalid) printf 'wrong checksum' > "$output" ;;
      valid) cp "$WORK/expected" "$output" ;;
      *) fail "valid cache unexpectedly downloaded again" ;;
    esac
  }
  for download in interrupted invalid; do
    if release_fetch_archive https://example.invalid/archive "$WORK/cached" "$expected" >"$WORK/out" 2>&1; then
      fail "accepted $download dependency bytes"
    fi
    [ "$(cat "$WORK/cached")" = 'truncated prior download' ] || fail "failed download changed the cache"
    [ -z "$(find "$WORK" -name 'cached.download.*' -print -quit)" ] || fail "failed download left a staging file"
  done
  download=valid
  release_fetch_archive https://example.invalid/archive "$WORK/cached" "$expected"
  cmp "$WORK/cached" "$WORK/expected"
  download=reuse
  release_fetch_archive https://example.invalid/archive "$WORK/cached" "$expected"
)

DEPENDENCIES_CMAKE="$REPO/cmake/dependencies/common.cmake"
LINKS_CMAKE="$REPO/cmake/compile_definitions/common.cmake"
MACOS_LINKS_CMAKE="$REPO/cmake/compile_definitions/macos.cmake"
PACKAGE_SCRIPT="$REPO/scripts/package-release.sh"
grep -Fq 'pkg_check_modules(MINIUPNP REQUIRED IMPORTED_TARGET miniupnpc)' "$DEPENDENCIES_CMAKE" ||
  fail "miniupnpc is not exposed as a resolved pkg-config target"
grep -Fq 'pkg_check_modules(OPUS REQUIRED IMPORTED_TARGET opus)' "$DEPENDENCIES_CMAKE" ||
  fail "Opus is not exposed as a resolved pkg-config target"
grep -Fq 'PkgConfig::MINIUPNP' "$LINKS_CMAKE" ||
  fail "release link does not use the resolved miniupnpc target"
grep -Fq 'PkgConfig::OPUS' "$LINKS_CMAKE" ||
  fail "release link does not use the resolved Opus target"
if grep -Eq '(^|[[:space:]])(/opt/homebrew/lib|/opt/local/lib|/usr/local/lib)([[:space:]]|$)' "$MACOS_LINKS_CMAKE"; then
  fail "macOS build injects machine-local library search paths"
fi
if grep -q '/opt/homebrew' "$PACKAGE_SCRIPT"; then
  fail "release package script contains a machine-local Homebrew path"
fi
grep -Fq 'xcrun --sdk macosx --show-sdk-path' "$SCRIPT" ||
  fail "system libcurl metadata is not derived from the selected macOS SDK"
grep -Fq -- '--prefix=/usr/local --openssldir=/etc/ssl' "$SCRIPT" ||
  fail "OpenSSL embeds the temporary dependency prefix"
grep -Fq -- '-DSKYLIGHT_MAP_SOURCE_PATHS=ON' "$PACKAGE_SCRIPT" ||
  fail "release C paths are not reproducibly remapped"
grep -Fq -- '-debug-prefix-map' "$PACKAGE_SCRIPT" ||
  fail "release Swift paths are not reproducibly remapped"
grep -Fq 'HOST_BIN="$BUILD/sunshine"' "$PACKAGE_SCRIPT" ||
  fail "package script does not consume CMake's current host symlink"

spaced_source="$WORK/source with a space"
mkdir "$spaced_source"
spaced_source="$(cd "$spaced_source" && pwd -P)"
cat > "$spaced_source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.22)
project(SourcePathTest LANGUAGES C)
include("${MOONWALK_OPTIONS}")
add_executable(source_path main.c)
CMAKE
cat > "$spaced_source/main.c" <<'C'
#include <stdio.h>

int main(void) {
  puts(__FILE__);
  return 0;
}
C
cmake -S "$spaced_source" -B "$spaced_source/build" -DSKYLIGHT_MAP_SOURCE_PATHS=ON \
  "-DMOONWALK_OPTIONS=$REPO/cmake/prep/options.cmake" > "$WORK/cmake-path.log" 2>&1 || { cat "$WORK/cmake-path.log"; fail "spaced source would not configure"; }
cmake --build "$spaced_source/build" --verbose >> "$WORK/cmake-path.log" 2>&1 || { cat "$WORK/cmake-path.log"; fail "spaced source would not compile"; }
mapped_source="$("$spaced_source/build/source_path")"
case "$mapped_source" in ./main.c|main.c) ;; *) tail -n 12 "$WORK/cmake-path.log"; fail "source path was not remapped: $mapped_source" ;; esac

echo "PASS: release dependency sources are pinned and verified"
