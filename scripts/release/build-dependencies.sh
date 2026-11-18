#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEPLOYMENT_TARGET="14.0"
OPENSSL_VERSION="3.6.3"
OPENSSL_SHA256="243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPUS_VERSION="1.6.1"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
OPUS_URL="https://ftp.osuosl.org/pub/xiph/releases/opus/opus-${OPUS_VERSION}.tar.gz"
MINIUPNPC_VERSION="2.3.3"
MINIUPNPC_SHA256="d52a0afa614ad6c088cc9ddff1ae7d29c8c595ac5fdd321170a05f41e634bd1a"
MINIUPNPC_URL="https://github.com/miniupnp/miniupnp/releases/download/miniupnpc_2_3_3/miniupnpc-${MINIUPNPC_VERSION}.tar.gz"

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
RECIPE_SHA="$(shasum -a 256 "$0" | awk '{print $1}')"
CACHE_KEY="$(
  print_manifest
  printf 'architecture=arm64\nxcode=%s\nsdk=%s\nrecipe=%s\n' \
    "$XCODE_VERSION" "$SDK_VERSION" "$RECIPE_SHA"
)"
CACHE_KEY="$(printf '%s' "$CACHE_KEY" | shasum -a 256 | awk '{print $1}')"
ROOT="${SKYLIGHT_RELEASE_DEPS_ROOT:-$REPO/build/release-deps/$CACHE_KEY}"
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

verify_file() {
  local expected="$1"
  local file="$2"
  local actual
  [ -f "$file" ] || { echo "ERROR: dependency archive is missing: $file" >&2; return 1; }
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: checksum mismatch for $file (expected $expected, got $actual)" >&2
    return 1
  fi
}

case "${1:-}" in
  --print-manifest) print_manifest; exit 0 ;;
  --print-root) printf '%s\n' "$ROOT"; exit 0 ;;
  --print-cmake-args) print_cmake_args; exit 0 ;;
  --verify-file)
    [ "$#" -eq 3 ] || { echo "Usage: $0 --verify-file SHA256 FILE" >&2; exit 64; }
    verify_file "$2" "$3"
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
  if [ ! -f "$archive" ]; then
    curl --fail --location --retry 3 --output "$archive" "$url"
  fi
  verify_file "$sha256" "$archive"
  printf '%s\n' "$archive"
}

extract_archive() {
  local archive="$1"
  local destination="$2"
  if [ ! -d "$destination" ]; then
    mkdir -p "$destination"
    tar -xf "$archive" -C "$destination" --strip-components=1
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
  (
    cd "$OPUS_SOURCE"
    CFLAGS="-O2 -mmacosx-version-min=$DEPLOYMENT_TARGET" \
    CXXFLAGS="-O2 -mmacosx-version-min=$DEPLOYMENT_TARGET" \
      ./configure --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-doc --disable-extra-programs
    make -j "$JOBS"
    make install
  )
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
