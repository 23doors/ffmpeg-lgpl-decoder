#!/bin/sh
# The fixture checks of patches 0160 and 0161 against a harness built by
# setup.sh: a Matroska file with its Cues after the Clusters, served with byte
# ranges by server.py, whose network goes away at the first seek's cue read.
# Each check prints PASS or FAIL; the exit status is the number of failures.
# With the series only up to 0159 (setup.sh WORKDIR 0159) the mkv-cues-*
# checks fail (the seek during the outage lost the index: it read 2.5 MB of
# clusters, or landed short of its target); with 0160 and not 0161 the
# mkv-cues-noreconnect-* ones do (the generic search landed on the last
# cluster read and reported success). mkv-truncated and mkv-intact hold what
# stock FFmpeg does.
#
# usage: tests/matroska/check.sh WORKDIR [CHECK...]
#   checks: cues cues-noreconnect truncated intact (default: all)
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
# landings NAME: 0 when every seek that succeeded landed right and the last
# one landed; prints what each seek did
landings() {
    awk -v max=$MAX_BYTES '
        /^seek / { n++; ok = 0; t = $2 + 0; s = s " seek" n "(" t "):" $3 }
        /^landed / { p = substr($3, 5) + 0; b = substr($4, 7) + 0
                     s = s ",pts=" p ",bytes=" b
                     if (p > t || p < t - 2 || b >= max) bad = 1; ok = 1 }
        /^noland / { s = s "," $3; bad = 1 }
        END { print s; exit !(n >= 2 && ok && !bad) }' "$OUT/$1.log"
}

# 0160: the cue read failed in the outage is read again at the next seek;
# the seek during it fails or lands right, never reads on from the clusters
check_cues() {
    for mode in cut 503 close; do
        run "mkv-cues-$mode" cues_end.mkv "--down-at-cues 6:$mode" $RMPO -read 4 -seek 90 -pause 7000 -seek 90
        s=$(landings "mkv-cues-$mode"); ok=$?
        result "mkv-cues-$mode" "a seek during the outage ($mode) fails or lands at 88-90 s within $MAX_BYTES bytes, the next lands there:$s" $ok
    done
}
# 0161: without reconnects the generic search's read fails: the seek fails,
# it does not land on the last cluster read
check_cues_noreconnect() {
    for mode in cut 503; do
        run "mkv-cues-noreconnect-$mode" cues_end.mkv "--down-at-cues 2:$mode" -read 4 -seek 90 -pause 3000 -seek 90
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

CHECKS=${*:-cues cues-noreconnect truncated intact}
for c in $CHECKS; do
    "check_$(echo "$c" | tr - _)"
done
exit $FAIL
