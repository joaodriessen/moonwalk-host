#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/release/common.sh"
VERSION=9.0.2
SOURCE_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
COMPANION_TAG=v2026.621.21936
COMPANION_SHA256=d4706499ec1c7b0032308fa5ebaf697035415093c5878075666bd2128f323c47
PATCH_SHA256=5ea6c3ca88532e5e122abdb7c29142229674bfdc249e150d0c618e7e257bf29c
COMPLETION_PATCH_SHA256=2d1edb981c09007e0330f155b07be95d94b5785145c6357cbd64940856cea260
LIVE_BITRATE_PATCH_SHA256=feab50d9b6fae9ff11b5ebb0c8233f60425fec7c33099fc9671505af3ea11046
ROOT="$REPO/build/ffmpeg-release"
SOURCE="$ROOT/ffmpeg-$VERSION"
PREFIX="$ROOT/prepared"
DOWNLOADS="$REPO/build/release-deps/ffmpeg-downloads"
ARCHIVE="$DOWNLOADS/ffmpeg-$VERSION.tar.xz"
COMPANIONS="$DOWNLOADS/Darwin-arm64-ffmpeg-$COMPANION_TAG.tar.gz"
PATCH="$REPO/patches/ffmpeg-vtenc-sync-output.patch"
COMPLETION_PATCH="$REPO/patches/ffmpeg-vtenc-completion.patch"
LIVE_BITRATE_PATCH="$REPO/patches/ffmpeg-vtenc-live-bitrate.patch"
JOBS="${SKYLIGHT_BUILD_JOBS:-6}"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
verify() { [ -f "$2" ] && [ "$(sha "$2")" = "$1" ] || { echo "ERROR: checksum mismatch: $2" >&2; exit 1; }; }
prepared_manifest() {
  local sdk compiler library digest
  sdk="$(xcrun --sdk macosx --show-sdk-build-version)" || return 1
  compiler="$(/usr/bin/clang --version | shasum -a 256 | awk '{print $1}')" || return 1
  printf 'version=%s source=%s patch=%s completion_patch=%s live_bitrate_patch=%s companion=%s recipe=%s sdk=%s compiler=%s\n' \
    "$VERSION" "$SOURCE_SHA256" "$PATCH_SHA256" "$COMPLETION_PATCH_SHA256" "$LIVE_BITRATE_PATCH_SHA256" \
    "$COMPANION_SHA256" "$(sha "$0")" "$sdk" "$compiler"
  for library in libavcodec.a libavutil.a libswscale.a libcbs.a libx264.a libx265.a libSvtAv1Enc.a; do
    digest="$(sha "$PREFIX/lib/$library")" || return 1
    printf '%s=%s\n' "$library" "$digest"
  done
}
verify_prepared() {
  local recorded="$PREFIX/.skylight-ffmpeg"
  local expected
  [ -f "$recorded" ] || return 1
  [ -s "$PREFIX/include/libavcodec/avcodec.h" ] || return 1
  expected="$(prepared_manifest 2>/dev/null)" || return 1
  [ "$(cat "$recorded")" = "$expected" ]
}

case "${1:-}" in
  --print-version) echo "$VERSION"; exit 0 ;;
  --print-manifest) echo "ffmpeg=$VERSION sha256=$SOURCE_SHA256 patch_sha256=$PATCH_SHA256 completion_patch_sha256=$COMPLETION_PATCH_SHA256 live_bitrate_patch_sha256=$LIVE_BITRATE_PATCH_SHA256 companion=$COMPANION_TAG companion_sha256=$COMPANION_SHA256"; exit 0 ;;
  --print-prefix) echo "$PREFIX"; exit 0 ;;
  --verify) verify "$PATCH_SHA256" "$PATCH"; verify "$COMPLETION_PATCH_SHA256" "$COMPLETION_PATCH"; verify "$LIVE_BITRATE_PATCH_SHA256" "$LIVE_BITRATE_PATCH"; verify_prepared || { echo "ERROR: prepared FFmpeg missing or changed" >&2; exit 1; }; exit 0 ;;
  "") ;;
  *) echo "Usage: $0 [--print-version|--print-manifest|--print-prefix|--verify]" >&2; exit 64 ;;
esac

verify "$PATCH_SHA256" "$PATCH"
verify "$COMPLETION_PATCH_SHA256" "$COMPLETION_PATCH"
verify "$LIVE_BITRATE_PATCH_SHA256" "$LIVE_BITRATE_PATCH"
if verify_prepared; then echo "Prepared FFmpeg $VERSION: $PREFIX"; exit 0; fi
PKG_CONFIG="$(command -v pkg-config)" || { echo "ERROR: pkg-config is required to build FFmpeg" >&2; exit 1; }
mkdir -p "$ROOT" "$DOWNLOADS"
release_fetch_archive "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" "$ARCHIVE" "$SOURCE_SHA256"
release_fetch_archive "https://github.com/LizardByte/build-deps/releases/download/$COMPANION_TAG/Darwin-arm64-ffmpeg.tar.gz" \
  "$COMPANIONS" "$COMPANION_SHA256"
COMPANION_ROOT="$ROOT/companion-$COMPANION_SHA256"
if [ ! -f "$COMPANION_ROOT/.archive-complete" ]; then
  mkdir -p "$COMPANION_ROOT"
  tar -xf "$COMPANIONS" -C "$COMPANION_ROOT"
  touch "$COMPANION_ROOT/.archive-complete"
fi
COMPANION="$COMPANION_ROOT/ffmpeg"
for lib in libSvtAv1Enc.a libx264.a libx265.a; do [ -f "$COMPANION/lib/$lib" ] || { echo "ERROR: companion library missing: $lib" >&2; exit 1; }; done
PATCH_SET="$SOURCE_SHA256:$PATCH_SHA256:$COMPLETION_PATCH_SHA256:$LIVE_BITRATE_PATCH_SHA256"
if [ ! -f "$SOURCE/.skylight-patched" ] ||
   [ "$(cat "$SOURCE/.skylight-patched")" != "$PATCH_SET" ]; then
  rm -rf "$SOURCE"
  mkdir -p "$SOURCE"
  tar -xf "$ARCHIVE" -C "$SOURCE" --strip-components=1
  (cd "$SOURCE" && patch --fuzz=0 -p1 < "$PATCH" && patch --fuzz=0 -p1 < "$COMPLETION_PATCH" && patch --fuzz=0 -p1 < "$LIVE_BITRATE_PATCH")
  echo "$PATCH_SET" > "$SOURCE/.skylight-patched"
fi
# FFmpeg's configure and make split paths in compiler flags. Paths relative to
# SOURCE work even when the checkout path contains spaces.
COMPANION_BUILD_PATH="../${COMPANION_ROOT##*/}/ffmpeg"
mkdir -p "$ROOT/pkgconfig" "$PREFIX/lib" "$PREFIX/include"
for name in x265 SvtAv1Enc; do
  sed "s|^prefix=.*|prefix=$COMPANION_BUILD_PATH|" "$COMPANION/lib/pkgconfig/$name.pc" > "$ROOT/pkgconfig/$name.pc"
done
cat > "$ROOT/pkgconfig/x264.pc" <<PC
prefix=$COMPANION_BUILD_PATH
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: x264
Description: H.264 encoding library
Version: 0.165
Libs: -L\${libdir} -lx264
Libs.private: -lpthread -lm -ldl
Cflags: -I\${includedir}
PC
export PKG_CONFIG_PATH="$ROOT/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET=14.0
(
  cd "$SOURCE"
  ./configure --prefix="../${PREFIX##*/}" --cc=/usr/bin/clang --cxx=/usr/bin/clang++ --ar=/usr/bin/ar --ranlib=/usr/bin/ranlib \
    --pkg-config="$PKG_CONFIG" --pkg-config-flags=--static \
    --disable-all --disable-autodetect --disable-iconv --enable-gpl --enable-static --disable-shared \
    --enable-avcodec --enable-avutil --enable-bsfs --enable-swscale \
    --enable-encoder=mpeg2video,h263p --enable-libsvtav1 --enable-encoder=libsvtav1 \
    --enable-libx264 --enable-encoder=libx264 --enable-libx265 --enable-encoder=libx265 \
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox --enable-videotoolbox \
    --extra-cflags="-I$COMPANION_BUILD_PATH/include -mmacosx-version-min=14.0" \
    --extra-ldflags="-L$COMPANION_BUILD_PATH/lib -mmacosx-version-min=14.0"
  make -j "$JOBS"
  make install
)
for lib in libSvtAv1Enc.a libx264.a libx265.a; do cp "$COMPANION/lib/$lib" "$PREFIX/lib/$lib"; done
# Installed metadata must still work from outside SOURCE. Companion archives now
# live beside the FFmpeg libraries, so drop their build-only search path.
for pc in "$PREFIX/lib/pkgconfig/"*.pc; do
  sed -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
      -e 's|^libdir=.*|libdir=${prefix}/lib|' \
      -e 's|^includedir=.*|includedir=${prefix}/include|' \
      -e '/^Libs/s| -L\.\./companion-[a-f0-9]*/ffmpeg/lib||g' "$pc" > "$pc.tmp"
  mv "$pc.tmp" "$pc"
done
# Skylight's CBS wrapper includes FFmpeg private headers. Keep these from the exact source built above.
for subdir in libavcodec libavutil; do
  (cd "$SOURCE" && find "$subdir" -name '*.h' -print0 | while IFS= read -r -d '' header; do
    mkdir -p "$PREFIX/include/$(dirname "$header")"
    cp "$header" "$PREFIX/include/$header"
  done)
done
cp "$SOURCE/config.h" "$PREFIX/include/config.h"
# Maintain the legacy split CBS archive consumed by cmake/dependencies/ffmpeg.cmake.
find "$SOURCE/libavcodec" -maxdepth 1 \( -name 'cbs*.o' -o -name 'h264_levels.o' \) -print0 | xargs -0 /usr/bin/ar rcs "$PREFIX/lib/libcbs.a"
/usr/bin/ranlib "$PREFIX/lib/libcbs.a"
[ "$(strings "$PREFIX/lib/libavcodec.a" | grep -c 'Change the target bitrate of a running session')" -ge 1 ] || { echo "ERROR: live_bitrate option absent from FFmpeg library" >&2; exit 1; }
[ "$(strings "$PREFIX/lib/libavcodec.a" | grep -c 'Block each encode call until VideoToolbox')" -ge 1 ] || { echo "ERROR: sync_output option absent from FFmpeg library" >&2; exit 1; }
prepared_manifest > "$PREFIX/.skylight-ffmpeg.tmp"
mv "$PREFIX/.skylight-ffmpeg.tmp" "$PREFIX/.skylight-ffmpeg"
verify_prepared || { echo "ERROR: prepared FFmpeg verification failed" >&2; exit 1; }
echo "Prepared FFmpeg $VERSION: $PREFIX"
