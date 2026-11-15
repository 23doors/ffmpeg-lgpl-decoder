#!/bin/sh
# Builds the hls fixture harness against the pack's FFmpeg: downloads the
# pinned FFmpeg release (checked against the portfile's SHA512), applies the
# portfile's patch series in order, configures a minimal static host build
# (the hls, mpegts, mov, webvtt and aac demuxers, http/tcp/file/crypto/data,
# the aac decoder for the packed audio's stream info) and links hlsread,
# then generates the fixture media with the system ffmpeg.
#
# usage: tests/hls/setup.sh WORKDIR [LAST_PATCH]
#   LAST_PATCH  apply the series only up to this number (e.g. 0097), to see
#               the checks fail without the later patches
# Needs: curl, git, a C compiler, make, python3, openssl, an ffmpeg with
# libx264 and aac encoders on PATH (fixture media only). Builds with
# make -j${JOBS:-4}.
set -eu
W=$(mkdir -p "$1" && cd "$1" && pwd)
LAST=${2:-9999}
HERE=$(cd "$(dirname "$0")" && pwd)
PORT_DIR="$HERE/../../overlay-ports/ffmpeg"
VERSION=$(sed -n 's/.*"version": "\([0-9.]*\)".*/\1/p' "$PORT_DIR/vcpkg.json" | head -1)
SHA=$(sed -n 's/^ *SHA512 \([0-9a-f]*\)$/\1/p' "$PORT_DIR/portfile.cmake" | head -1)

cd "$W"
if [ ! -f "n$VERSION.tar.gz" ]; then
    curl -fsSL -o "n$VERSION.tar.gz.part" "https://github.com/FFmpeg/FFmpeg/archive/n$VERSION.tar.gz"
    mv "n$VERSION.tar.gz.part" "n$VERSION.tar.gz"
fi
echo "$SHA  n$VERSION.tar.gz" | shasum -a 512 -c -

rm -rf src build
tar xzf "n$VERSION.tar.gz"
mv "FFmpeg-n$VERSION" src
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
     --enable-demuxer=hls,mpegts,mov,webvtt,aac \
     --enable-protocol=http,tcp,file,crypto,data \
     --enable-parser=h264,aac --enable-decoder=aac > configure.log
 make -j"${JOBS:-4}" libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a > make.log)

EXTRA=
[ "$(uname)" = Darwin ] && EXTRA="-framework CoreFoundation -framework Security -liconv"
cc -O1 -g -Ibuild -Isrc -o hlsread "$HERE/hlsread.c" \
    build/libavformat/libavformat.a build/libavcodec/libavcodec.a build/libavutil/libavutil.a \
    -lz -lbz2 -lm -lpthread $EXTRA

M="$W/media"
if [ ! -f "$M/ts/s59.ts" ] || [ ! -f "$M/fmp4/s59.m4s" ]; then
    rm -rf "$M"; mkdir -p "$M/ts" "$M/fmp4"
    for kind in ts fmp4; do
        if [ $kind = ts ]; then seg="-hls_segment_filename $M/ts/s%d.ts"
        else seg="-hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 -hls_segment_filename $M/fmp4/s%d.m4s"; fi
        ffmpeg -nostdin -v error -f lavfi -i testsrc=size=320x240:rate=25 \
            -f lavfi -i sine=f=440:sample_rate=48000 -t 60 \
            -c:v libx264 -g 25 -keyint_min 25 -sc_threshold 0 -b:v 300k -c:a aac -b:a 64k \
            -f hls -hls_time 1 -hls_list_size 0 $seg "$M/$kind/full.m3u8"
    done
fi
if [ ! -f "$M/fmp4big/s19.m4s" ]; then
    # 20 s of fMP4 whose keyframes are over 64 KiB (twice hls's I/O buffer:
    # avio_read() reads such a sample past the buffer); the noise keeps x264
    # from making them small
    rm -rf "$M/fmp4big"; mkdir -p "$M/fmp4big"
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=640x360:rate=25 \
        -f lavfi -i sine=f=440:sample_rate=48000 -t 20 -vf noise=alls=12:all_seed=1 \
        -c:v libx264 -preset veryfast -g 25 -keyint_min 25 -sc_threshold 0 -crf 20 \
        -c:a aac -b:a 64k -f hls -hls_time 1 -hls_list_size 0 -hls_segment_type fmp4 \
        -hls_fmp4_init_filename init.mp4 -hls_segment_filename "$M/fmp4big/s%d.m4s" "$M/fmp4big/full.m3u8"
fi
if [ ! -f "$M/tsbig/s19.ts" ]; then
    # the same in TS: 6.5 MB, past mpegts's 5 MB probe window
    rm -rf "$M/tsbig"; mkdir -p "$M/tsbig"
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=size=640x360:rate=25 \
        -f lavfi -i sine=f=440:sample_rate=48000 -t 20 -vf noise=alls=12:all_seed=1 \
        -c:v libx264 -preset veryfast -g 25 -keyint_min 25 -sc_threshold 0 -crf 20 \
        -c:a aac -b:a 64k -f hls -hls_time 1 -hls_list_size 0 \
        -hls_segment_filename "$M/tsbig/s%d.ts" "$M/tsbig/full.m3u8"
fi
if [ ! -f "$M/sidx/sidx.mp4" ]; then
    # a fragmented MP4 with a global sidx (as DASH on-demand and CMAF files
    # have: mov switches roots at every fragment), video only, so that mov
    # reads it in order: server.py serves it with byte ranges
    rm -rf "$M/sidx"; mkdir -p "$M/sidx"
    ffmpeg -nostdin -v error -f lavfi -i testsrc=size=320x240:rate=25 -t 240 \
        -c:v libx264 -g 50 -keyint_min 50 -sc_threshold 0 -b:v 300k -an \
        -movflags +frag_keyframe+empty_moov+default_base_moof+global_sidx "$M/sidx/sidx.mp4"
fi
if [ ! -f "$M/aes/s19.ts" ]; then
    # the TS segments AES-128 encrypted (CBC, PKCS7), as server.py's /aes/ lists them
    rm -rf "$M/aes"; mkdir -p "$M/aes"
    KEY=00112233445566778899aabbccddeeff
    python3 -I -c 'import sys; open(sys.argv[1], "wb").write(bytes.fromhex(sys.argv[2]))' "$M/aes/key.bin" "$KEY"
    for n in $(seq 0 19); do
        openssl enc -aes-128-cbc -K "$KEY" -iv 000102030405060708090a0b0c0d0e0f \
            -in "$M/ts/s$n.ts" -out "$M/aes/s$n.ts"
    done
fi
if [ ! -f "$M/id3/a9.aac" ]; then
    # 1 s ADTS segments of a tone (server.py leads each with its ID3 timestamp)
    rm -rf "$M/id3"; mkdir -p "$M/id3"
    ffmpeg -nostdin -v error -f lavfi -i sine=f=440:sample_rate=48000 -t 10 -c:a aac -b:a 64k \
        -f segment -segment_time 1 -segment_format adts "$M/id3/a%d.aac"
fi
if [ ! -f "$M/mv/a/index.m3u8" ]; then
    # a multi-variant VOD with a long GOP (6 s, one keyframe at each 6 s
    # segment's start, B-frames: the keyframe's DTS is 80 ms below its PTS):
    # two video-only variants v1/v2 with a separate audio rendition a, and two
    # muxed variants m1/m2 (video and audio in one TS). The audio starts
    # 0.1 s after the video, so the timeline's first timestamp is the video
    # keyframe's PTS, above its DTS (as in the trace this fixture is from)
    rm -rf "$M/mv"
    for v in v1:320x240 v2:480x360 m1:320x240 m2:480x360; do
        name=${v%%:*}; size=${v#*:}; mkdir -p "$M/mv/$name"
        audio=-an; case $name in m*) audio="-c:a aac -b:a 64k";; esac
        ffmpeg -nostdin -v error -f lavfi -i testsrc=size=$size:rate=25 \
            -itsoffset 0.1 -f lavfi -i sine=f=440:sample_rate=48000 -t 36 \
            -c:v libx264 -g 150 -keyint_min 150 -sc_threshold 0 -b:v 300k $audio \
            -f hls -hls_time 6 -hls_list_size 0 -hls_segment_filename "$M/mv/$name/s%d.ts" "$M/mv/$name/index.m3u8"
    done
    # f1, f2: v1 and v2 in fMP4
    for v in f1:320x240 f2:480x360; do
        name=${v%%:*}; size=${v#*:}; mkdir -p "$M/mv/$name"
        ffmpeg -nostdin -v error -f lavfi -i testsrc=size=$size:rate=25 -t 36 \
            -c:v libx264 -g 150 -keyint_min 150 -sc_threshold 0 -b:v 300k -an \
            -f hls -hls_time 6 -hls_list_size 0 -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 \
            -hls_segment_filename "$M/mv/$name/s%d.m4s" "$M/mv/$name/index.m3u8"
    done
    # n1: no keyframe after the first (an intra-refresh stream's segments
    # carry none either), cut every 6 s all the same
    mkdir -p "$M/mv/n1"
    ffmpeg -nostdin -v error -f lavfi -i testsrc=size=480x360:rate=25 -t 36 \
        -c:v libx264 -g 10000 -keyint_min 10000 -sc_threshold 0 -b:v 300k -an \
        -f hls -hls_time 6 -hls_flags split_by_time -hls_list_size 0 \
        -hls_segment_filename "$M/mv/n1/s%d.ts" "$M/mv/n1/index.m3u8"
    mkdir -p "$M/mv/a"
    ffmpeg -nostdin -v error -f lavfi -i sine=f=440:sample_rate=48000 -t 35.9 -c:a aac -b:a 64k \
        -output_ts_offset 0.1 -f hls -hls_time 6 -hls_list_size 0 -hls_segment_filename "$M/mv/a/s%d.ts" "$M/mv/a/index.m3u8"
fi
echo "ready: $W/hlsread (patches up to $LAST)"
