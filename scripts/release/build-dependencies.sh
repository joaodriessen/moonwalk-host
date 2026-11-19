#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd -P)"
source "$DIR/common.sh"
DEPLOYMENT_TARGET="14.0"
OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPUS_VERSION="1.6.1"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
OPUS_URL="https://ftp.osuosl.org/pub/xiph/releases/opus/opus-${OPUS_VERSION}.tar.gz"
MINIUPNPC_VERSION="2.3.5"
MINIUPNPC_SHA256="b9a1e57233216c5f62572de6d628e73e910f50cdb71e9c0eb89b169ce154d256"
MINIUPNPC_URL="https://github.com/miniupnp/miniupnp/releases/download/miniupnpc_2_3_5/miniupnpc-${MINIUPNPC_VERSION}.tar.gz"

JOBS="${SKYLIGHT_BUILD_JOBS:-6}"

print_manifest() {
  echo "deployment_target=$DEPLOYMENT_TARGET"
  echo "openssl=$OPENSSL_VERSION sha256=$OPENSSL_SHA256"
  echo "opus=$OPUS_VERSION sha256=$OPUS_SHA256"
  echo "miniupnpc=$MINIUPNPC_VERSION sha256=$MINIUPNPC_SHA256"
  "$DIR/build-ffmpeg.sh" --print-manifest
}

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
RECIPE_SHA="$(shasum -a 256 "$0" "$DIR/common.sh" | awk '{print $1}' | shasum -a 256 | awk '{print $1}')"
CACHE_KEY="$(
  print_manifest
  printf 'architecture=arm64\nxcode=%s\nsdk=%s\nrecipe=%s\n' \
    "$XCODE_VERSION" "$SDK_VERSION" "$RECIPE_SHA"
)"
CACHE_KEY="$(printf '%s' "$CACHE_KEY" | shasum -a 256 | awk '{print $1}')"
CACHE_DIR="$REPO/build/release-deps"
if [ -d "$CACHE_DIR" ]; then
  # Installed pkg-config files must point to the shared cache after a source snapshot is removed.
  CACHE_DIR="$(cd "$CACHE_DIR" && pwd -P)"
fi
ROOT="${SKYLIGHT_RELEASE_DEPS_ROOT:-$CACHE_DIR/$CACHE_KEY}"
DOWNLOADS="$ROOT/downloads"
SOURCES="$ROOT/sources"
BUILDS="$ROOT/builds"
PREFIX="$ROOT/prefix"

print_cmake_args() {
  echo "-DOPENSSL_ROOT_DIR=$PREFIX"
  echo "-DOPENSSL_CRYPTO_LIBRARY=$PREFIX/lib/libcrypto.a"
  echo "-DOPENSSL_SSL_LIBRARY=$PREFIX/lib/libssl.a"
  echo "-DOPENSSL_INCLUDE_DIR=$PREFIX/include"
  echo "-DCMAKE_PREFIX_PATH=$PREFIX"
}

case "${1:-}" in
  --print-manifest) print_manifest; exit 0 ;;
  --print-root) printf '%s\n' "$ROOT"; exit 0 ;;
  --print-cmake-args) print_cmake_args; exit 0 ;;
  --verify-file)
    [ "$#" -eq 3 ] || { echo "Usage: $0 --verify-file SHA256 FILE" >&2; exit 64; }
    release_verify_archive "$2" "$3"
    exit 0
    ;;
  -h|--help)
    echo "Usage: $0 [--print-manifest | --print-root | --print-cmake-args | --verify-file SHA256 FILE]"
    exit 0
    ;;
  "") ;;
  *) echo "ERROR: unknown argument: $1" >&2; exit 64 ;;
esac

fetch_archive() {
  local name="$1"
  local url="$2"
  local sha256="$3"
  local archive="$DOWNLOADS/$name"
  release_fetch_archive "$url" "$archive" "$sha256" || return 1
  printf '%s\n' "$archive"
}

extract_archive() {
  local archive="$1"
  local destination="$2"
  if [ ! -f "$destination/.archive-complete" ]; then
    mkdir -p "$destination"
    tar -xf "$archive" -C "$destination" --strip-components=1
    touch "$destination/.archive-complete"
  fi
}

mkdir -p "$DOWNLOADS" "$SOURCES" "$BUILDS" "$PREFIX"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

# Apple ships libcurl in the macOS SDK but not a pkg-config file. Generate the
# minimal metadata in the isolated prefix so release configuration never needs
# Homebrew's host-version-specific compatibility files.
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/libcurl.pc" <<PC
prefix=$SDKROOT/usr
exec_prefix=/usr
libdir=/usr/lib
includedir=$SDKROOT/usr/include

Name: libcurl
Description: Apple system libcurl
Version: 8.7.1
Libs: -L\${libdir} -lcurl
Cflags:
PC

OPENSSL_ARCHIVE="$(fetch_archive "openssl-${OPENSSL_VERSION}.tar.gz" "$OPENSSL_URL" "$OPENSSL_SHA256")"
OPENSSL_SOURCE="$SOURCES/openssl-${OPENSSL_VERSION}"
extract_archive "$OPENSSL_ARCHIVE" "$OPENSSL_SOURCE"
if [ ! -f "$PREFIX/.openssl-${OPENSSL_VERSION}-portable-v2-complete" ]; then
  OPENSSL_STAGE="$BUILDS/openssl-stage"
  cmake -E remove_directory "$OPENSSL_STAGE"
  mkdir -p "$OPENSSL_STAGE"
  (
    cd "$OPENSSL_SOURCE"
    make clean >/dev/null 2>&1 || true
    ./Configure darwin64-arm64-cc no-shared no-tests \
      --prefix=/usr/local --openssldir=/etc/ssl \
      -mmacosx-version-min="$DEPLOYMENT_TARGET"
    make -j "$JOBS"
    make install_sw "DESTDIR=$OPENSSL_STAGE"
  )
  cp -R "$OPENSSL_STAGE/usr/local/include/." "$PREFIX/include/"
  cp -R "$OPENSSL_STAGE/usr/local/lib/." "$PREFIX/lib/"
  touch "$PREFIX/.openssl-${OPENSSL_VERSION}-portable-v2-complete"
fi

OPUS_ARCHIVE="$(fetch_archive "opus-${OPUS_VERSION}.tar.gz" "$OPUS_URL" "$OPUS_SHA256")"
OPUS_SOURCE="$SOURCES/opus-${OPUS_VERSION}"
extract_archive "$OPUS_ARCHIVE" "$OPUS_SOURCE"
if [ ! -f "$PREFIX/.opus-${OPUS_VERSION}-complete" ]; then
  # Opus's libtool installer splits prefixes containing spaces.
  cmake -S "$OPUS_SOURCE" -B "$BUILDS/opus" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-ffile-prefix-map=\"$OPUS_SOURCE=opus-$OPUS_VERSION\"" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBUILD_SHARED_LIBS=OFF \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_BUILD_TESTING=OFF
  cmake --build "$BUILDS/opus" -j "$JOBS"
  cmake --install "$BUILDS/opus"
  # The upstream CMake metadata embeds absolute paths in unquoted flags.
  OPUS_PC="$PREFIX/lib/pkgconfig/opus.pc"
  sed -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
      -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
      -e 's|^libdir=.*|libdir=${prefix}/lib|' \
      -e 's|^includedir=.*|includedir=${prefix}/include|' \
      -e 's|^Libs: .*|Libs: -L${libdir} -lopus|' \
      -e 's|^Cflags: .*|Cflags: -I${includedir}/opus|' "$OPUS_PC" > "$OPUS_PC.tmp"
  mv "$OPUS_PC.tmp" "$OPUS_PC"
  touch "$PREFIX/.opus-${OPUS_VERSION}-complete"
fi

MINIUPNPC_ARCHIVE="$(fetch_archive "miniupnpc-${MINIUPNPC_VERSION}.tar.gz" "$MINIUPNPC_URL" "$MINIUPNPC_SHA256")"
MINIUPNPC_SOURCE="$SOURCES/miniupnpc-${MINIUPNPC_VERSION}"
extract_archive "$MINIUPNPC_ARCHIVE" "$MINIUPNPC_SOURCE"
if [ ! -f "$PREFIX/.miniupnpc-${MINIUPNPC_VERSION}-complete" ]; then
  cmake -S "$MINIUPNPC_SOURCE" -B "$BUILDS/miniupnpc" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DUPNPC_BUILD_SHARED=OFF \
    -DUPNPC_BUILD_STATIC=ON \
    -DUPNPC_BUILD_TESTS=OFF \
    -DUPNPC_BUILD_SAMPLE=OFF
  cmake --build "$BUILDS/miniupnpc" -j "$JOBS"
  cmake --install "$BUILDS/miniupnpc"
  touch "$PREFIX/.miniupnpc-${MINIUPNPC_VERSION}-complete"
fi

echo "release dependency prefix: $PREFIX"
print_manifest
