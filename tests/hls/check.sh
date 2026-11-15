#!/bin/sh
# The fixture checks of patches 0098-0103 (and the I54 trace) against a
# harness built by setup.sh. Each check prints PASS or FAIL; the exit status
# is the number of failures. With the series only up to 0097
# (setup.sh WORKDIR 0097) b19, b20, i51, i52 and init-dedup fail.
#
# usage: tests/hls/check.sh WORKDIR [CHECK...]
#   checks: b19 b20 i51 i52 init-dedup i54 (default: all)
set -u
W=$(cd "$1" && pwd); shift
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$W/out"; mkdir -p "$OUT"
export HLS_FIXTURE_MEDIA="$W/media"
PORT=${PORT:-18790}
FAIL=0
# the options RMP passes for a network HLS input (ffmpeg_input_options.rs)
RMPO="-o seg_max_retry=0 -o seg_skip=live -o m3u8_hold_counters=10 -o reconnect=1 -o reconnect_streamed=1 -o reconnect_on_network_error=1 -o reconnect_on_http_error=5xx,408,429 -o reconnect_max_retries=3 -o reconnect_delay_max=2 -o rw_timeout=8000000 -o extension_picky=0"

# run NAME "server args" PATH [hlsread args]: the log in $OUT/NAME.log, the
# server's request log in $OUT/NAME.server.log
run() {
    name=$1; sargs=$2; path=$3; shift 3
    PORT=$((PORT + 1))
    python3 -I "$HERE/server.py" $PORT $sargs > "$OUT/$name.server.log" 2>&1 &
    srv=$!
    i=0
    until grep -q listening "$OUT/$name.server.log" 2>/dev/null || [ $i -ge 50 ]; do
        sleep 0.1; i=$((i + 1))
    done
    timeout 60 "$W/hlsread" "http://127.0.0.1:$PORT$path" "$@" > "$OUT/$name.log" 2>&1
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
}
result() { # NAME CONDITION-TEXT 0|1
    if [ "$3" = 0 ]; then echo "PASS $1: $2"; else echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); fi
}
summary() { grep '^summary' "$OUT/$1.log"; }
field() { summary "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

check_b19() { # 0098: the cues of WebVTT segments read on as one stream
    run b19 "" /vtt/subs.m3u8
    bad=$(grep '^pkt' "$OUT/b19.log" | grep -c -v -E '"cue [0-9]"$')
    n=$(grep -c '^pkt' "$OUT/b19.log")
    [ "$n" = 5 ] && [ "$bad" = 0 ]; result b19 "5 cues, none with header lines ($n cues, $bad bad)" $?
}
check_b20() { # 0099: an interrupt during a segment's body loses nothing
    run b20-ref "" /vod/index.m3u8 -q
    run b20 "--stall 12:15000:1500" /vod/index.m3u8 -q -stallint 300
    ref=$(field b20-ref s0); got=$(field b20 s0); ex=$(field b20 exits); step=$(field b20 maxstep0)
    [ "$ex" -ge 1 ] && [ "$got" = "$ref" ] && [ "$(echo "$step < 0.25" | bc)" = 1 ]
    result b20 "interrupted ($ex), all $ref video packets ($got), no gap (largest step $step s)" $?
}
check_i51() { # 0100: a cut address line fails the load with a log
    run i51-fits "--long-line 16000" /long/index.m3u8 -q
    run i51-cut "--long-line 17000" /long/index.m3u8 -q
    fits=$(field i51-fits s0)
    grep -q 'Playlist line longer than 16383 characters' "$OUT/i51-cut.log" &&
        grep -q '^open failed: Invalid data' "$OUT/i51-cut.log" && [ "$fits" = 125 ]
    result i51 "16000 chars play (s0=$fits of 125), 17000 fail with INVALIDDATA and a log" $?
}
check_i52() { # 0101: a live init section failure fails its segment, not the input
    run i52-once "--init-fail 1" /livefmp4/index.m3u8 -q -maxtime 5 -o seg_max_retry=0 -o seg_skip=live
    run i52-always "--init-fail 1000000" /livefmp4/index.m3u8 -q -maxtime 20 -o seg_max_retry=0 -o seg_skip=live -o live_reload_timeout=3
    played=$(field i52-once s0)
    grep -q 'skipping the segment' "$OUT/i52-once.log" && [ "${played:-0}" -gt 50 ] &&
        grep -q 'Initialization section of segment .* failed too many times: ' "$OUT/i52-always.log"
    result i52 "one failed request skips its segment (s0=${played:-none}); failing for live_reload_timeout fails" $?
}
check_init_dedup() { # 0103: a live playlist's unchanged init section is read once
    run dedup "" /livefmp4/index.m3u8 -q -maxtime 5
    req=$(grep -c 'GET /livefmp4/init.mp4' "$OUT/dedup.server.log")
    [ "$req" = 1 ]; result init-dedup "the init section requested once in 5 s of reloads ($req)" $?
}
check_i54() { # trace: two 404s in a row, RMP's options, a player 2-3 s behind the edge
    for lsi in -2 -3; do
        run i54_$lsi "--live-404 12,13" /live/index.m3u8 -q -maxtime 16 -nofsi -pace 10 -start 0.5 -o live_start_index=$lsi $RMPO
        r12=$(grep -c 'GET /live/s12.ts' "$OUT/i54_$lsi.server.log")
        r13=$(grep -c 'GET /live/s13.ts' "$OUT/i54_$lsi.server.log")
        echo "     i54 live_start_index=$lsi: s12 requests $r12, s13 requests $r13; $(summary i54_$lsi | grep -o 'stalls.*')"
        [ "$r12" -le 2 ] && [ "$r13" -le 2 ]
        result i54_$lsi "each 404 asked for at most twice (an early open and once when due, 0075)" $?
    done
}

CHECKS=${*:-b19 b20 i51 i52 init_dedup i54}
for c in $CHECKS; do "check_$(echo "$c" | tr - _)"; done
exit $FAIL
