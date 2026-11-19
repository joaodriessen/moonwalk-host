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
ARCHIVE="$ROOT/ffmpeg-$VERSION.tar.xz"
COMPANIONS="$ROOT/Darwin-arm64-ffmpeg.tar.gz"
PATCH="$REPO/patches/ffmpeg-vtenc-sync-output.patch"
COMPLETION_PATCH="$REPO/patches/ffmpeg-vtenc-completion.patch"
LIVE_BITRATE_PATCH="$REPO/patches/ffmpeg-vtenc-live-bitrate.patch"
JOBS="${SKYLIGHT_BUILD_JOBS:-6}"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
verify() { [ -f "$2" ] && [ "$(sha "$2")" = "$1" ] || { echo "ERROR: checksum mismatch: $2" >&2; exit 1; }; }
verify_prepared() {
  local recorded="$PREFIX/.skylight-ffmpeg"
  [ -f "$recorded" ] || return 1
  [ "$(cat "$recorded")" = "version=$VERSION source=$SOURCE_SHA256 patch=$PATCH_SHA256 completion_patch=$COMPLETION_PATCH_SHA256 live_bitrate_patch=$LIVE_BITRATE_PATCH_SHA256 companion=$COMPANION_SHA256 recipe=$(sha "$0") libavcodec=$(sha "$PREFIX/lib/libavcodec.a")" ] || return 1
  [ -f "$PREFIX/include/libavcodec/avcodec.h" ] && [ -f "$PREFIX/lib/libcbs.a" ]
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
mkdir -p "$ROOT"
release_fetch_archive "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" "$ARCHIVE" "$SOURCE_SHA256"
release_fetch_archive "https://github.com/LizardByte/build-deps/releases/download/$COMPANION_TAG/Darwin-arm64-ffmpeg.tar.gz" \
  "$COMPANIONS" "$COMPANION_SHA256"
if [ ! -f "$ROOT/companion/.archive-complete" ]; then
  mkdir -p "$ROOT/companion"
  tar -xf "$COMPANIONS" -C "$ROOT/companion"
  touch "$ROOT/companion/.archive-complete"
fi
COMPANION="$ROOT/companion/ffmpeg"
for lib in libSvtAv1Enc.a libx264.a libx265.a; do [ -f "$COMPANION/lib/$lib" ] || { echo "ERROR: companion library missing: $lib" >&2; exit 1; }; done
PATCH_SET="$PATCH_SHA256:$COMPLETION_PATCH_SHA256:$LIVE_BITRATE_PATCH_SHA256"
if [ ! -f "$SOURCE/.skylight-patched" ] ||
   [ "$(cat "$SOURCE/.skylight-patched")" != "$PATCH_SET" ]; then
  rm -rf "$SOURCE"
  mkdir -p "$SOURCE"
  tar -xf "$ARCHIVE" -C "$SOURCE" --strip-components=1
  (cd "$SOURCE" && patch --fuzz=0 -p1 < "$PATCH" && patch --fuzz=0 -p1 < "$COMPLETION_PATCH" && patch --fuzz=0 -p1 < "$LIVE_BITRATE_PATCH")
  echo "$PATCH_SET" > "$SOURCE/.skylight-patched"
fi
mkdir -p "$ROOT/pkgconfig" "$PREFIX/lib" "$PREFIX/include"
for name in x265 SvtAv1Enc; do
  sed "s|^prefix=.*|prefix=$COMPANION|" "$COMPANION/lib/pkgconfig/$name.pc" > "$ROOT/pkgconfig/$name.pc"
done
cat > "$ROOT/pkgconfig/x264.pc" <<PC
prefix=$COMPANION
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
  ./configure --prefix="$PREFIX" --cc=/usr/bin/clang --cxx=/usr/bin/clang++ --ar=/usr/bin/ar --ranlib=/usr/bin/ranlib \
    --pkg-config=/opt/homebrew/bin/pkg-config --pkg-config-flags=--static \
    --disable-all --disable-autodetect --disable-iconv --enable-gpl --enable-static --disable-shared \
    --enable-avcodec --enable-avutil --enable-bsfs --enable-swscale \
    --enable-encoder=mpeg2video,h263p --enable-libsvtav1 --enable-encoder=libsvtav1 \
    --enable-libx264 --enable-encoder=libx264 --enable-libx265 --enable-encoder=libx265 \
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox --enable-videotoolbox \
    --extra-cflags="-I$COMPANION/include -mmacosx-version-min=14.0" \
    --extra-ldflags="-L$COMPANION/lib -mmacosx-version-min=14.0"
  make -j "$JOBS"
  make install
)
for lib in libSvtAv1Enc.a libx264.a libx265.a; do cp "$COMPANION/lib/$lib" "$PREFIX/lib/$lib"; done
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
echo "version=$VERSION source=$SOURCE_SHA256 patch=$PATCH_SHA256 completion_patch=$COMPLETION_PATCH_SHA256 live_bitrate_patch=$LIVE_BITRATE_PATCH_SHA256 companion=$COMPANION_SHA256 recipe=$(sha "$0") libavcodec=$(sha "$PREFIX/lib/libavcodec.a")" > "$PREFIX/.skylight-ffmpeg"
verify_prepared || { echo "ERROR: prepared FFmpeg verification failed" >&2; exit 1; }
echo "Prepared FFmpeg $VERSION: $PREFIX"
