#!/bin/sh
# The fixture checks of patches 0160 and 0161 against a harness built by
# setup.sh: a Matroska file with its Cues after the Clusters, served with byte
# ranges by server.py, whose network goes away at the first seek's cue read.
# Each check prints PASS or FAIL; the exit status is the number of failures.
# With the series only up to 0159 (setup.sh WORKDIR 0159) the mkv-cues-*
# checks fail (the seek during the outage lost the index: it read 2.5 MB of
# clusters, or landed short of its target) and so do the mkv-loaded-* ones
# (a seek during an outage after the cues were read reported success and
# landed past its target); with 0160 and not 0161 the
# mkv-cues-noreconnect-* ones do (the generic search landed on the last
# cluster read and reported success). mkv-truncated, mkv-intact and the
# mkv-variant-* checks hold what stock FFmpeg does.
#
# usage: tests/matroska/check.sh WORKDIR [CHECK...]
#   checks: cues cues-noreconnect loaded truncated intact variants classifier
#   (default: all)
set -u
W=$(cd "$1" && pwd); shift
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$W/out"; mkdir -p "$OUT"
if [ "$HERE/mkvseek.c" -nt "$W/mkvseek" ]; then
    echo "FAIL harness: $W/mkvseek is older than $HERE/mkvseek.c (run setup.sh $W)"
    exit 1
fi
PORT=${PORT:-18990}
FAIL=0
CAP=$(command -v timeout || command -v gtimeout || true)
cap() { if [ -n "$CAP" ]; then "$CAP" 90 "$@"; else "$@"; fi; }
# the options RMP passes for a progressive network input (ffmpeg_input_options.rs)
RMPO="-o reconnect=1 -o reconnect_streamed=1 -o reconnect_on_network_error=1 -o reconnect_on_http_error=5xx,408,429 -o reconnect_max_retries=3 -o reconnect_delay_max=4 -o rw_timeout=8000000"
# a seek's landing is right when it is the keyframe at or before its target
# (2 s apart) and it read less than this: the cues and a cluster, not a run
# of clusters
MAX_BYTES=524288

# run NAME FILE "server args" [mkvseek args]: $OUT/NAME.log, $OUT/NAME.server.log
run() {
    name=$1; file=$2; sargs=$3; shift 3
    PORT=$((PORT + 1))
    python3 -I "$HERE/server.py" $PORT "$W/media/$file" $sargs > "$OUT/$name.server.log" 2>&1 &
    srv=$!
    i=0
    until grep -q listening "$OUT/$name.server.log" 2>/dev/null || [ $i -ge 300 ]; do
        sleep 0.1; i=$((i + 1))
    done
    cap "$W/mkvseek" "http://127.0.0.1:$PORT/$file" "$@" > "$OUT/$name.log" 2> "$OUT/$name.err.log"
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
}
result() { # NAME CONDITION-TEXT 0|1
    if [ "$3" = 0 ]; then echo "PASS $1: $2"; else echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); fi
}
# landings NAME [MAX]: 0 when every seek that succeeded landed right (within
# MAX bytes, default MAX_BYTES) and the last one landed; prints what each
# seek did
landings() {
    awk -v max=${2:-$MAX_BYTES} '
        /^seek / { n++; ok = 0; t = $2 + 0; s = s " seek" n "(" t "):" $3 }
        /^landed / { p = substr($3, 5) + 0; b = substr($4, 7) + 0
                     s = s ",pts=" p ",bytes=" b
                     if (p > t || p < t - 2 || b >= max) bad = 1; ok = 1 }
        /^noland / { s = s "," $3; bad = 1 }
        END { print s; exit !(n >= 2 && ok && !bad) }' "$OUT/$1.log"
}

# 0160: the cue read failed in the outage (at their start, or within them:
# mid) is read again at the next seek; the seek during it fails or lands
# right, never reads on from the clusters
check_cues() {
    # http's reconnects (4 s) see a drop within the cues through a short
    # outage: mid's is longer
    for mode in cut:5 503:5 close:5 mid:40; do
        down=${mode#*:}; mode=${mode%:*}
        run "mkv-cues-$mode" cues_end.mkv "--down-at-cues $down:$mode" $RMPO -read 4 -seek 90 -pause $(((down + 3) * 1000)) -seek 90
        s=$(landings "mkv-cues-$mode"); ok=$?
        result "mkv-cues-$mode" "a seek during the outage ($mode) fails or lands at 88-90 s within $MAX_BYTES bytes, the next lands there:$s" $ok
    done
}
# 0160: once the cues are read, a seek whose repositioning fails in an
# outage fails, rather than report success and read on from where it was
check_loaded() {
    for mode in 503 close; do
        run "mkv-loaded-$mode" cues_end.mkv "--down-at-cues 15:$mode:1.5" $RMPO -read 4 -seek 90 -pause 4000 -seek 30 -pause 15000 -seek 30
        s=$(landings "mkv-loaded-$mode"); ok=$?
        result "mkv-loaded-$mode" "the cues read, a seek during the outage ($mode) fails or lands at 28-30 s, the next lands there:$s" $ok
    done
}
# 0161: without reconnects the generic search's read fails: the seek fails,
# it does not land on the last cluster read. After a drop within the cues
# (mid) the next seek finds their start in the read buffer and http without
# a connection (it reconnects only on a seek): that seek fails too, the one
# after it lands.
check_cues_noreconnect() {
    for mode in cut 503 mid; do
        run "mkv-cues-noreconnect-$mode" cues_end.mkv "--down-at-cues 2:$mode" -read 4 -seek 90 -pause 5000 -seek 90 -seek 90
        s=$(landings "mkv-cues-noreconnect-$mode"); ok=$?
        result "mkv-cues-noreconnect-$mode" "no reconnects ($mode): the seek during the outage fails, the next lands at 88-90 s:$s" $ok
    done
}
# a file cut before its cues still seeks through its clusters (the index is
# broken by a clean end, not an I/O error)
check_truncated() {
    if [ ! -f "$W/media/truncated.mkv" ]; then
        python3 -I -c 'import sys
b = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(b[:b.rfind(bytes.fromhex("1c53bb6b")) - 100000])' \
            "$W/media/cues_end.mkv" "$W/media/truncated.mkv"
    fi
    run mkv-truncated truncated.mkv "" -read 4 -seek 60
    grep -q '^landed 60.000 pts=60.000' "$OUT/mkv-truncated.log"
    result mkv-truncated "a file cut before its cues lands a seek to 60 s at 60 s: $(grep -E '^(seek|landed|noland)' "$OUT/mkv-truncated.log" | tr '\n' ' ')" $?
}
check_intact() {
    run mkv-intact cues_end.mkv "" -read 4 -seek 90 -seek 30
    s=$(landings mkv-intact); ok=$?
    result mkv-intact "no outage: seeks to 90 and 30 s land there:$s" $ok
}
# files with no deferred cues, read from a file, or with the index ignored:
# seeks to 90 and 30 s land there as with stock FFmpeg (without cues, or
# ignoring them, by reading the clusters)
check_variants() {
    for v in "nocues no_cues.mkv 100000000" "front cues_front.mkv $MAX_BYTES" \
             "webm cues_end.webm $MAX_BYTES" "ignidx cues_end.mkv 100000000 -o fflags=ignidx"; do
        set -- $v; vname=mkv-variant-$1; vfile=$2; vmax=$3; shift 3
        run "$vname" "$vfile" "" "$@" -read 4 -seek 90 -seek 30
        s=$(landings "$vname" "$vmax"); ok=$?
        result "$vname" "no outage: seeks to 90 and 30 s land there:$s" $ok
    done
    cap "$W/mkvseek" "$W/media/cues_end.mkv" -read 4 -seek 90 -seek 30 > "$OUT/mkv-variant-file.log" 2> "$OUT/mkv-variant-file.err.log"
    s=$(landings mkv-variant-file); ok=$?
    result mkv-variant-file "a local file: seeks to 90 and 30 s land there:$s" $ok
}

# 0160's classifier of the cue read errors retried while the network is
# away: the errors tcp and http fail with are transient, a 4xx, invalid data,
# EOF and ENOMEM are not; on Windows also winsock's codes, which tcp returns
# there (ff_neterrno(), a failed connect's SO_ERROR). Built on the host from
# the patched matroskadec.c, once as is and once with winsock's codes
# (wsa_codes.h); with mingw-w64 (x86_64-w64-mingw32-gcc) the function is also
# compiled for Windows against the real network.h and winsock2.h, and
# wsa_codes.h checked against it. REQUIRE_MINGW=1 fails without it.
check_classifier() {
    C="$OUT/classifier"; mkdir -p "$C"
    sed -n '/^static int matroska_io_error_is_transient/,/^}/p' \
        "$W/src/libavformat/matroskadec.c" > "$C/classifier_fn.c"
    if [ ! -s "$C/classifier_fn.c" ]; then
        result mkv-classifier "matroska_io_error_is_transient() is in matroskadec.c" 1
        return
    fi
    for v in posix:0 winsock:1; do
        name=mkv-classifier-${v%%:*}
        if cc -Werror=implicit-function-declaration -DWINSOCK=${v##*:} -I"$C" -I"$HERE" \
               -I"$W/build" -I"$W/src" -o "$C/${v%%:*}" "$HERE/classifier.c" \
               > "$OUT/$name.log" 2>&1 &&
           "$C/${v%%:*}" >> "$OUT/$name.log" 2>&1; then ok=0; else ok=1; fi
        result "$name" "the errors are classified right ($(tail -1 "$OUT/$name.log"))" $ok
    done
    MINGW=${MINGW_CC:-x86_64-w64-mingw32-gcc}
    if ! command -v "$MINGW" > /dev/null 2>&1; then
        if [ "${REQUIRE_MINGW:-0}" = 1 ]; then
            result mkv-classifier-mingw "$MINGW is installed" 1
        else
            echo "SKIP mkv-classifier-mingw: no $MINGW"
        fi
        return
    fi
    # the config.h items network.h and what it includes use on Windows
    mkdir -p "$C/win"
    printf '%s\n' '#define HAVE_WINSOCK2_H 1' '#define CONFIG_NETWORK 1' \
        '#define HAVE_STRUCT_SOCKADDR_STORAGE 1' '#define HAVE_STRUCT_ADDRINFO 1' \
        '#define HAVE_STRUCT_POLLFD 1' '#define HAVE_SOCKLEN_T 1' \
        '#define HAVE_CLOSESOCKET 1' '#define HAVE_STRUCT_SOCKADDR_IN6 1' \
        '#define HAVE_STRUCT_IPV6_MREQ 1' '#define HAVE_INET_ATON 0' \
        '#define HAVE_DIRECT_H 1' '#define HAVE_IO_H 1' \
        > "$C/win/config.h"
    sed -n 's/^#define \(WSAE[A-Z]*\) *\([0-9]*\)$/_Static_assert(\1 == \2, "\1");/p' \
        "$HERE/wsa_codes.h" > "$C/wsa_codes_check.h"
    if "$MINGW" -std=c11 -Werror -c -I"$C/win" -I"$C" -I"$W/build" -I"$W/src" \
           -o "$C/classifier_mingw.o" "$HERE/classifier_mingw.c" \
           > "$OUT/mkv-classifier-mingw.log" 2>&1; then ok=0; else ok=1; fi
    result mkv-classifier-mingw "it compiles for Windows against network.h, and winsock2.h has wsa_codes.h's values" $ok
}

CHECKS=${*:-cues cues-noreconnect loaded truncated intact variants classifier}
for c in $CHECKS; do
    "check_$(echo "$c" | tr - _)"
done
exit $FAIL
