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
  'openssl=3.6.3 sha256=243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1' \
  'opus=1.6.1 sha256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1' \
  'miniupnpc=2.3.3 sha256=d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a'; do
  [[ "$manifest" == *"$expected"* ]] || fail "manifest missing: $expected"
done

printf 'not the expected archive' > "$WORK/archive"
if "$SCRIPT" --verify-file 243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1 "$WORK/archive" >"$WORK/out" 2>&1; then
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
cp "$SCRIPT" "$REPO/scripts/release/build-ffmpeg.sh" "$FIXTURE/"
root_before="$("$FIXTURE/build-dependencies.sh" --print-root)"
printf '\n# recipe mutation\n' >> "$FIXTURE/build-dependencies.sh"
root_after="$("$FIXTURE/build-dependencies.sh" --print-root)"
[ "$root_before" != "$root_after" ] || fail "dependency recipe change did not invalidate the cache"

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
grep -Fq 'CMAKE_C_FLAGS=-ffile-prefix-map=' "$PACKAGE_SCRIPT" ||
  fail "release C paths are not reproducibly remapped"
grep -Fq -- '-debug-prefix-map' "$PACKAGE_SCRIPT" ||
  fail "release Swift paths are not reproducibly remapped"
grep -Fq 'HOST_BIN="$BUILD/sunshine"' "$PACKAGE_SCRIPT" ||
  fail "package script does not consume CMake's current host symlink"

echo "PASS: release dependency sources are pinned and verified"
