#!/bin/sh
# The fixture checks of patches 0098-0110 (and the I54 trace) against a
# harness built by setup.sh. Each check prints PASS or FAIL; the exit status
# is the number of failures. With the series only up to 0097
# (setup.sh WORKDIR 0097) all but xo-ipv6 and i54 fail (without 0104 the
# headers go everywhere, IPv6 included).
#
# usage: tests/hls/check.sh WORKDIR [CHECK...]
#   checks: b19 b20 id3 i51 i52 init-dedup init-cut headers-origin i54 cut-body
#   (default: all)
set -u
W=$(cd "$1" && pwd); shift
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$W/out"; mkdir -p "$OUT"
export HLS_FIXTURE_MEDIA="$W/media"
PORT=${PORT:-18790}
FAIL=0
# each run capped at 60 s: timeout (GNU coreutils, Linux) or gtimeout (its
# Homebrew name on macOS); without either the runs go uncapped
CAP=$(command -v timeout || command -v gtimeout || true)
[ -n "$CAP" ] || echo "note: no timeout or gtimeout, runs are not capped"
cap() { if [ -n "$CAP" ]; then "$CAP" 60 "$@"; else "$@"; fi; }
# the options RMP passes for a network HLS input (ffmpeg_input_options.rs)
RMPO="-o seg_max_retry=0 -o seg_skip=live -o m3u8_hold_counters=10 -o reconnect=1 -o reconnect_streamed=1 -o reconnect_on_network_error=1 -o reconnect_on_http_error=5xx,408,429 -o reconnect_max_retries=3 -o reconnect_delay_max=2 -o rw_timeout=8000000 -o extension_picky=0"

# run NAME "server args" PATH [hlsread args]: the log in $OUT/NAME.log, the
# server's request log in $OUT/NAME.server.log; HOST: the address asked for
# (127.0.0.1)
run() {
    name=$1; sargs=$2; path=$3; shift 3
    PORT=$((PORT + 1))
    python3 -I "$HERE/server.py" $PORT $sargs > "$OUT/$name.server.log" 2>&1 &
    srv=$!
    i=0
    until grep -q listening "$OUT/$name.server.log" 2>/dev/null || [ $i -ge 50 ]; do
        sleep 0.1; i=$((i + 1))
    done
    cap "$W/hlsread" "http://${HOST:-127.0.0.1}:$PORT$path" "$@" > "$OUT/$name.log" 2>&1
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
read_on() { # NAME REF "server args" PATH [LOSS]: interrupted in a stall, nothing lost
    name=$1; ref=$2; sargs=$3; path=$4; loss=${5:-}
    run "$name" "$sargs" "$path" -q -stallint 300
    want=$(field "$ref" s0); got=$(field "$name" s0); ex=$(field "$name" exits); step=$(field "$name" maxstep0)
    want1=$(field "$ref" s1); got1=$(field "$name" s1)
    # hlsread's interrupts (each may give more than one AVERROR_EXIT)
    ints=$(grep -c '^interrupt at' "$OUT/$name.log")
    # interrupted and read on; no video packet lost (LOSS=interrupts: at most
    # one per interrupt), no audio packet (0110: mpegts kept a cut PES), none
    # handed on cut, no gap
    allowed=0; [ "$loss" = interrupts ] && allowed=$ints
    [ "$ints" -ge 1 ] && [ "${ex:-0}" -ge 1 ] && [ -n "$want" ] && [ -n "$got" ] && [ "$got" -le "$want" ] &&
        [ $((want - got)) -le "$allowed" ] && [ -n "$want1" ] && [ "$got1" = "$want1" ] &&
        ! grep -q 'Packet corrupt' "$OUT/$name.log" &&
        awk -v s="$step" 'BEGIN { exit !(s != "" && s + 0 < 0.25) }'
    ok=$?; bad=$(grep -c 'Packet corrupt' "$OUT/$name.log")
    result "$name" "interrupted ($ints, $ex AVERROR_EXIT), $want video packets ($got, $allowed may be lost), all $want1 audio ($got1), none corrupt ($bad), no gap (largest step $step s)" $ok
}
check_b20() { # 0099: an interrupt during a segment's body loses nothing
    run b20-ref "" /vod/index.m3u8 -q
    read_on b20 b20-ref "--stall 12:15000:1500" /vod/index.m3u8
    # 0106: the stall inside a chunk-size line (chunked transfer encoding);
    # 0110: the interrupt falls inside an audio PES there
    read_on b20-chunked b20-ref "--chunked --stall 12:15000:1500" /vod/index.m3u8
    # 0105: an AES-128 segment (crypto.c took the interrupt for its end)
    run b20-aes-ref "" /aes/index.m3u8 -q
    read_on b20-aes b20-aes-ref "--stall 12:15000:1500" /aes/index.m3u8
    # 0108: fMP4 (mov reads the sample an interrupt cut again; one that
    # spanned a refill of hls's buffer cannot be read again and is lost: at
    # most one per interrupt, never handed on cut)
    run b20-fmp4-ref "" /vodfmp4/index.m3u8 -q
    read_on b20-fmp4 b20-fmp4-ref "--stall 12:15000:1500" /vodfmp4/index.m3u8 interrupts
}
check_id3() { # 0099: an interrupt in a segment's first read keeps its ID3 timestamp
    # a5's timestamp alone is 100 s on: the step is there only if a5's ID3
    # tag was taken out (a5's first read is the one interrupted)
    # (no avformat_find_stream_info(): it would read past a5 before the
    # first packet, when hlsread does not interrupt yet)
    run id3-ref "" /id3/index.m3u8 -q -nofsi -o http_multiple=0
    run id3 "--stall 5:0:1500" /id3/index.m3u8 -q -nofsi -o http_multiple=0 -stallint 300
    want=$(field id3-ref s0); got=$(field id3 s0); ex=$(field id3 exits)
    rstep=$(field id3-ref maxstep0); step=$(field id3 maxstep0)
    [ "${ex:-0}" -ge 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] &&
        awk -v r="$rstep" -v s="$step" 'BEGIN { exit !(r + 0 > 99 && s + 0 > 99) }'
    result id3 "interrupted ($ex), all $want packets ($got), a5's 100 s on kept (largest step $step s, $rstep s uninterrupted)" $?
}
check_i51() { # 0100: a cut address line fails the load with a log
    run i51-fits "--long-line 16000" /long/index.m3u8 -q
    run i51-cut "--long-line 17000" /long/index.m3u8 -q
    # a cut tag whose address this demuxer does not read (EXT-X-DATERANGE's
    # X-ASSET-URI=) only warns
    run i51-tag "--long-tag 17000" /long/index.m3u8 -q
    fits=$(field i51-fits s0); tag=$(field i51-tag s0)
    grep -q 'Playlist line longer than 16383 characters' "$OUT/i51-cut.log" &&
        grep -q '^open failed: Invalid data' "$OUT/i51-cut.log" && [ "$fits" = 125 ] &&
        grep -q 'Playlist line longer than 16383 characters cut' "$OUT/i51-tag.log" && [ "$tag" = 125 ]
    result i51 "16000 chars play (s0=$fits of 125), 17000 fail with INVALIDDATA and a log, a cut DATERANGE plays (s0=$tag)" $?
}
check_i52() { # 0101: a live init section failure fails its segment, not the input
    run i52-once "--init-fail 1" /livefmp4/index.m3u8 -q -maxtime 5 -o seg_max_retry=0 -o seg_skip=live
    run i52-always "--init-fail 1000000" /livefmp4/index.m3u8 -q -maxtime 20 -o seg_max_retry=0 -o seg_skip=live -o live_reload_timeout=3
    played=$(field i52-once s0)
    grep -q 'skipping the segment' "$OUT/i52-once.log" && [ "${played:-0}" -gt 50 ] &&
        grep -q 'Initialization section of segment .* failed too many times: ' "$OUT/i52-always.log"
    result i52 "one failed request skips its segment (s0=${played:-none}); failing for live_reload_timeout fails" $?
}
check_init_cut() { # 0109: a live init section cut part way is not stored
    # (stock hls stored the half section: the subdemuxer failed on it and
    # the playlist was lost)
    run init-cut "--init-cut 1" /livefmp4/index.m3u8 -q -maxtime 5 -o seg_max_retry=0 -o seg_skip=live
    played=$(field init-cut s0)
    req=$(grep -c 'GET /livefmp4/init.mp4' "$OUT/init-cut.server.log")
    [ "${played:-0}" -gt 50 ] && [ "$req" -ge 2 ]
    result init-cut "the cut section asked for again ($req requests), the stream plays (s0=${played:-none})" $?
}
check_init_dedup() { # 0103: a live playlist's unchanged init section is read once
    run dedup "" /livefmp4/index.m3u8 -q -maxtime 5
    req=$(grep -c 'GET /livefmp4/init.mp4' "$OUT/dedup.server.log")
    [ "$req" = 1 ]; result init-dedup "the init section requested once in 5 s of reloads ($req)" $?
}
run2() { # 0104's fixture
    # run2 NAME A|B [ORIGIN]: the server on two ports (two origins A and B),
    # the input opened on A or B; with ORIGIN: headers_origin=ORIGIN (A: A's)
    name=$1; which=$2; named=${3:-}
    PORT=$((PORT + 2)); a=$((PORT - 1)); b=$PORT
    python3 -I "$HERE/server.py" $a --second-port $b > "$OUT/$name.server.log" 2>&1 &
    srv=$!
    i=0
    until grep -q listening "$OUT/$name.server.log" 2>/dev/null || [ $i -ge 50 ]; do
        sleep 0.1; i=$((i + 1))
    done
    if [ "$which" = A ]; then port=$a; else port=$b; fi
    [ "$named" = A ] && named=http://127.0.0.1:$a
    [ "$named" = A-noscheme ] && named=127.0.0.1:$a
    if [ -n "$named" ]; then
        cap "$W/hlsread" "http://127.0.0.1:$port/xo/index.m3u8" -q -o http_multiple=0 -o "headers=X-Token: secret" \
            -o "headers_origin=$named" > "$OUT/$name.log" 2>&1
    else
        cap "$W/hlsread" "http://127.0.0.1:$port/xo/index.m3u8" -q -o http_multiple=0 -o "headers=X-Token: secret" > "$OUT/$name.log" 2>&1
    fi
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
    A_PORT=$a
}
origin_result() { # NAME: every request on A carried the token, none on B, all 5 segments read
    log="$OUT/$1.server.log"
    a_no=$(grep 'GET /xo/' "$log" | grep "port=$A_PORT " | grep -c 'token=no')
    b_yes=$(grep 'GET /xo/' "$log" | grep -v "port=$A_PORT " | grep -c 'token=yes')
    segs=$(grep -c 'GET /xo/s[0-9]' "$log")
    # s1 is asked for on the connection the redirect to s2 left open (a new
    # request on a kept-alive connection)
    c2=$(sed -n 's|.*GET /xo/s2.ts .* conn=\([0-9]*\).*|\1|p' "$log")
    c1=$(sed -n 's|.*GET /xo/s1.ts .* conn=\([0-9]*\).*|\1|p' "$log")
    [ "$a_no" = 0 ] && [ "$b_yes" = 0 ] && [ "$segs" = 5 ] && [ -n "$c1" ] && [ "$c1" = "$c2" ]
    result "$1" "the token at origin A's requests only ($a_no without it on A, $b_yes with it on B, $segs segments; s1 on s2's connection: $c1/$c2)" $?
}
check_headers_origin() {
    # opened on A: the playlist, its segments on A and a redirect back to A
    # get the token; redirects to B and a new request on the connection to B
    # a redirect left open do not
    run2 xo-opened-a A; origin_result xo-opened-a
    # opened on B with headers_origin=A (an external track opened with the
    # media's options): nothing to B, the token only where A is asked
    run2 xo-origin-a B A; origin_result xo-origin-a
    # an origin that cannot be read: the headers go nowhere (fail closed)
    run2 xo-origin-bad A "not an origin"
    sent=$(grep 'GET /xo/' "$OUT/xo-origin-bad.server.log" | grep -c 'token=yes')
    segs=$(grep -c 'GET /xo/s[0-9]' "$OUT/xo-origin-bad.server.log")
    [ "$sent" = 0 ] && [ "$segs" = 5 ] && grep -q 'Custom headers not sent: no origin' "$OUT/xo-origin-bad.log"
    result xo-origin-bad "an unreadable headers_origin sends the token nowhere ($sent requests with it, $segs segments)" $?
    # one without the scheme is no origin either, and says so
    run2 xo-origin-noscheme A A-noscheme
    sent=$(grep 'GET /xo/' "$OUT/xo-origin-noscheme.server.log" | grep -c 'token=yes')
    segs=$(grep -c 'GET /xo/s[0-9]' "$OUT/xo-origin-noscheme.server.log")
    [ "$sent" = 0 ] && [ "$segs" = 5 ] && grep -q 'Custom headers not sent: no origin' "$OUT/xo-origin-noscheme.log"
    result xo-origin-noscheme "headers_origin=host:port sends the token nowhere, with a warning ($sent requests with it, $segs segments)" $?
    # an IPv6 literal origin ([::1]): one origin, every request gets the token
    if python3 -I -c 'import socket; s = socket.socket(socket.AF_INET6); s.bind(("::1", 0))' 2>/dev/null; then
        HOST="[::1]"
        run xo-ipv6 "--ipv6" /xo/index.m3u8 -q -o http_multiple=0 -o "headers=X-Token: secret"
        HOST=
        no=$(grep 'GET /xo/' "$OUT/xo-ipv6.server.log" | grep -c 'token=no')
        segs=$(grep -c 'GET /xo/s[0-9]' "$OUT/xo-ipv6.server.log")
        [ "$no" = 0 ] && [ "$segs" = 5 ] && ! grep -q 'Custom headers not sent' "$OUT/xo-ipv6.log"
        result xo-ipv6 "an IPv6 literal origin gets the token on every request ($no without it, $segs segments)" $?
    else
        echo "SKIP xo-ipv6: no IPv6 loopback here"
    fi
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
check_cut_body() { # 0107: a cut body from a server without ranges is not read again from byte 0
    # a progressive file with reconnect_streamed (RMP's progressive options):
    # one request, the read ends in an error at the cut, with no byte twice
    # (stock http reads the file's start again, appended, without end)
    # (the reference reads the whole body, so it needs no reconnect options)
    run cut-prog-ref "" /prog/file.ts -q
    run cut-prog "--cut 0" /prog/file.ts -q -maxtime 20 -o reconnect=1 -o reconnect_streamed=1 -o reconnect_on_network_error=1
    req=$(grep -c 'GET /prog/file.ts' "$OUT/cut-prog.server.log")
    full=$(field cut-prog-ref s0); got=$(field cut-prog s0)
    grep -q '^end: Input/output error' "$OUT/cut-prog.log" && [ "$req" = 1 ] && [ -n "$full" ] &&
        [ "${got:-0}" -gt 0 ] && [ "$got" -lt "$full" ]
    result cut-prog "requested once ($req), ends in an I/O error, $got of $full video packets" $?
    # a live stream with Akamai's placeholder Content-Length (2147483647),
    # which http.c keeps streamed: a cut still reconnects at byte 0
    run cut-akamai "" /prog/akamai.ts -q -maxtime 8 -o reconnect=1 -o reconnect_streamed=1 -o reconnect_on_network_error=1
    req=$(grep -c 'GET /prog/akamai.ts' "$OUT/cut-akamai.server.log")
    ! grep -q '^end: Input/output error' "$OUT/cut-akamai.log" && ! grep -q 'Body cut at' "$OUT/cut-akamai.log" &&
        [ "$req" -ge 2 ]
    result cut-akamai "a placeholder length still reconnects ($req requests), no I/O error" $?
    # an hls segment with RMP's options (0070 passes reconnect_streamed on to
    # it): the segment once, then the rest of the playlist
    run cut-hls-ref "" /vod/index.m3u8 -q
    run cut-hls "--cut 5" /vod/index.m3u8 -q -maxtime 20 $RMPO
    req=$(grep -c 'GET /vod/s5.ts' "$OUT/cut-hls.server.log")
    after=$(grep -c 'GET /vod/s19.ts' "$OUT/cut-hls.server.log")
    full=$(field cut-hls-ref s0); got=$(field cut-hls s0)
    grep -q '^end: End of file' "$OUT/cut-hls.log" && [ "$req" = 1 ] && [ "$after" = 1 ] &&
        [ -n "$full" ] && [ "${got:-0}" -lt "$full" ] && [ "$got" -gt $((full * 3 / 4)) ]
    result cut-hls "the cut segment requested once ($req), read on to the end (s19: $after), $got of $full video packets" $?
    # an AES-128 one (0105 returns the inner read's EIO, no longer taken for
    # the segment's end with its last block unpadded): the playlist reads on
    run cut-aes-ref "" /aes/index.m3u8 -q
    run cut-aes "--cut 5" /aes/index.m3u8 -q -maxtime 20 $RMPO
    req=$(grep -c 'GET /aes/s5.ts' "$OUT/cut-aes.server.log")
    after=$(grep -c 'GET /aes/s19.ts' "$OUT/cut-aes.server.log")
    full=$(field cut-aes-ref s0); got=$(field cut-aes s0)
    grep -q '^end: End of file' "$OUT/cut-aes.log" && [ "$req" = 1 ] && [ "$after" = 1 ] &&
        [ -n "$full" ] && [ "${got:-0}" -lt "$full" ] && [ "$got" -gt $((full * 3 / 4)) ]
    result cut-aes "the cut AES-128 segment requested once ($req), read on to the end (s19: $after), $got of $full video packets" $?
}

CHECKS=${*:-b19 b20 id3 i51 i52 init_dedup init_cut headers_origin i54 cut_body}
for c in $CHECKS; do "check_$(echo "$c" | tr - _)"; done
exit $FAIL
