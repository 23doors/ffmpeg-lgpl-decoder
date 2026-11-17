#!/bin/sh
# Builds the Matroska seek harness against the pack's FFmpeg: the portfile's
# REF (checked against its SHA512) with the portfile's patch series applied in
# order, a minimal static host build (the matroska demuxer, http/tcp/file) and
# mkvseek, then the fixture media with the system ffmpeg.
#
# usage: tests/matroska/setup.sh WORKDIR [LAST_PATCH]
#   LAST_PATCH  apply the series only up to this number (e.g. 0159), to see
#               the checks fail without the later patches
# Needs: curl, a C compiler, make, python3, an ffmpeg with libx264 on PATH
# (fixture media only; with libvpx for the WebM one). Builds with make -j${JOBS:-4}.
set -eu
W=$(mkdir -p "$1" && cd "$1" && pwd)
LAST=${2:-9999}
HERE=$(cd "$(dirname "$0")" && pwd)
PORT_DIR="$HERE/../../overlay-ports/ffmpeg"
VERSION=$(sed -n 's/.*"version": "\([0-9.]*\)".*/\1/p' "$PORT_DIR/vcpkg.json" | head -1)
SHA=$(sed -n 's/^ *SHA512 \([0-9a-f]*\)$/\1/p' "$PORT_DIR/portfile.cmake" | head -1)
REF=$(sed -n 's/^ *REF "*\([^" ]*\)"*$/\1/p' "$PORT_DIR/portfile.cmake" | head -1)
[ "$REF" = 'n${VERSION}' ] && REF=n$VERSION

cd "$W"
if [ ! -f "$REF.tar.gz" ]; then
    curl -fsSL -o "$REF.tar.gz.part" "https://github.com/FFmpeg/FFmpeg/archive/$REF.tar.gz"
    mv "$REF.tar.gz.part" "$REF.tar.gz"
fi
echo "$SHA  $REF.tar.gz" | shasum -a 512 -c -

rm -rf src build
tar xzf "$REF.tar.gz"
mv "FFmpeg-$REF" src
(cd src
 for p in $(sed -n '/PATCHES/,/^)/p' "$PORT_DIR/portfile.cmake" | grep -o '[0-9][0-9][0-9][0-9]-[^ ]*\.patch'); do
     n=${p%%-*}
     [ "$n" -le "$LAST" ] || break
     git apply --ignore-whitespace --whitespace=nowarn "$PORT_DIR/$p"
 done)

mkdir build
(cd build
 ../src/configure --disable-everything --disable-programs --disable-doc \
     --disable-autodetect --enable-static --disable-shared \
     --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
     --enable-demuxer=matroska --enable-protocol=http,tcp,file \
     --enable-parser=h264 > configure.log
 make -j"${JOBS:-4}" libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a > make.log)

EXTRA=
[ "$(uname)" = Darwin ] && EXTRA="-framework CoreFoundation -liconv"
cc -O1 -g -Ibuild -Isrc -o mkvseek "$HERE/mkvseek.c" \
    build/libavformat/libavformat.a build/libavcodec/libavcodec.a build/libavutil/libavutil.a \
    -lz -lm -lpthread $EXTRA

M="$W/media"
if [ ! -f "$M/cues_end.mkv" ]; then
    # 120 s, a keyframe every 2 s, the Cues after the Clusters (the muxer's
    # default, as most films in a library have them): the first seek reads them
    mkdir -p "$M"
    ffmpeg -nostdin -v error -f lavfi -i testsrc=size=320x240:rate=25 -t 120 \
        -c:v libx264 -g 50 -keyint_min 50 -sc_threshold 0 -b:v 300k -an \
        "$M/cues_end.mkv"
fi
# the same film without cues (written to a pipe), with them at the front,
# and as WebM (VP8) with them at the end
[ -f "$M/no_cues.mkv" ] || ffmpeg -nostdin -v error -i "$M/cues_end.mkv" -c copy -f matroska - > "$M/no_cues.mkv"
[ -f "$M/cues_front.mkv" ] || ffmpeg -nostdin -v error -i "$M/cues_end.mkv" -c copy -cues_to_front 1 "$M/cues_front.mkv"
[ -f "$M/cues_end.webm" ] || ffmpeg -nostdin -v error -f lavfi -i testsrc=size=320x240:rate=25 -t 120 \
    -c:v libvpx -g 50 -keyint_min 50 -b:v 300k -deadline realtime -cpu-used 8 -an "$M/cues_end.webm"
echo "harness ready in $W"
