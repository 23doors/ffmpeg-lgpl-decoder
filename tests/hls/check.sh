#!/bin/sh
# The fixture checks of patches 0098-0121 (and the I54 trace) against a
# harness built by setup.sh. Each check prints PASS or FAIL; the exit status
# is the number of failures. With the series only up to 0097
# (setup.sh WORKDIR 0097) all fail but xo-ipv6 (without 0104 the headers go
# everywhere, IPv6 included), the i54 trace, and cut-akamai, trunc-*, sidx
# and kf-nokey, which hold what stock FFmpeg does (a placeholder length
# reconnects; an input that ends where an interrupt cut it ends: 0108 and
# 0110 without 0112 fail it; a seekable fragmented MP4 reads with no extra
# request; a video without keyframes starts at the position). With the
# series up to 0112 the vswitch checks fail but kf-nokey; up to 0113, the
# ones that need a playlist read afresh when it is needed again (0114:
# kf-switch-fmp4, afresh-audio, kf-late-switch, kf-late-switch-fmp4,
# afresh-late-audio, live-switch, live-switch-late) and init-seek; up to
# 0114, the ones that count init section requests (0115: kf-switch-fmp4,
# init-seek, latemap-after, kf-late-switch-fmp4) and live-switch,
# live-switch-late (0116). latemap-before holds what the series did before
# 0115 (no init section served before a segment that maps none): it passes
# up to 0114 too. bad-map fails up to 0116 (the garbled reload failed the
# playlist as ENOMEM) and up to 0117 (the failed reload's unread rest was
# read as the next answers: 13 failures, not 3); cut-reload up to 0117 and
# with 0118 before it checked the read's error (a cut answer taken whole,
# no failure); stall-reload up to 0117 and with 0118 before an interrupted
# load stamped no reload time (it failed as INVALIDDATA, asked for again a
# reload interval later). vod-init-gap and
# vod-init-503 fail up to 0118 (a VOD's init section failure ended it),
# init-dedup-aes up to 0120 (a keyed section without an IV fetched again on
# every reload, and not logged).
#
# usage: tests/hls/check.sh WORKDIR [CHECK...]
#   checks: b19 b20 trunc chunk-trailer sidx id3 i51 i52 bad-map vod-init init-dedup
#           init-cut headers-origin i54 cut-body vswitch
#   (default: all)
set -u
W=$(cd "$1" && pwd); shift
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$W/out"; mkdir -p "$OUT"
# a harness older than hlsread.c reports less (no CRCs before round 3's):
# setup.sh builds it again
if [ "$HERE/hlsread.c" -nt "$W/hlsread" ]; then
    echo "FAIL harness: $W/hlsread is older than $HERE/hlsread.c (run setup.sh $W)"
    exit 1
fi
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
read_on() { # NAME REF "server args" PATH: interrupted in a stall, nothing lost
    name=$1; ref=$2; sargs=$3; path=$4
    run "$name" "$sargs" "$path" -q -stallint 300
    want=$(field "$ref" s0); got=$(field "$name" s0); ex=$(field "$name" exits); step=$(field "$name" maxstep0)
    # (every fixture has an audio stream s1: one without would FAIL here on
    # the empty counts, not skip the audio part)
    want1=$(field "$ref" s1); got1=$(field "$name" s1)
    # the packets' data, byte for byte (a TS packet lost inside a video PES
    # of no stated length changes no count)
    same=0
    [ -n "$(field "$ref" crc0)" ] &&
        [ "$(field "$ref" crc0)$(field "$ref" crc1)" = "$(field "$name" crc0)$(field "$name" crc1)" ] && same=1
    # hlsread's interrupts (each may give more than one AVERROR_EXIT); the
    # line comes from stderr into the file stdout also writes, so it is not
    # anchored at a line start
    ints=$(grep -c 'interrupt at' "$OUT/$name.log")
    # interrupted and read on; no video or audio packet lost or changed,
    # none handed on cut, no gap
    [ "$ints" -ge 1 ] && [ "${ex:-0}" -ge 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] &&
        [ -n "$want1" ] && [ "$got1" = "$want1" ] && [ $same = 1 ] && ! grep -q 'Packet corrupt' "$OUT/$name.log" &&
        awk -v s="$step" 'BEGIN { exit !(s != "" && s + 0 < 0.25) }'
    ok=$?; bad=$(grep -c 'Packet corrupt' "$OUT/$name.log")
    if [ $same = 1 ]; then same=same; else same=differ; fi
    result "$name" "interrupted ($ints, $ex AVERROR_EXIT), all $want video packets ($got), all $want1 audio ($got1), their data the reference's ($same), none corrupt ($bad), no gap (largest step $step s)" $ok
}
check_b20() { # 0099: an interrupt during a segment's body loses nothing
    run b20-ref "" /vod/index.m3u8 -q
    read_on b20 b20-ref "--stall 12:15000:1500" /vod/index.m3u8
    # 0106: the stall inside a chunk-size line (chunked transfer encoding);
    # 0110: the interrupt falls inside an audio PES there
    read_on b20-chunked b20-ref "--chunked --stall 12:15000:1500" /vod/index.m3u8
    # 0110: a TS packet begun before a refill of hls's 32 KiB buffer, whose
    # refill brought 50 bytes before the interrupt: the rewind needs the
    # bytes of both (s18 of tsbig is past the 5 MB that mpegts's probe keeps
    # the buffer at; its packet at 32712 spans 32768)
    run b20-tsbig-ref "" /vodtsbig/index.m3u8 -q
    read_on b20-tsbig b20-tsbig-ref "--stall 18:32818:1500" /vodtsbig/index.m3u8
    # 0105: an AES-128 segment (crypto.c took the interrupt for its end)
    run b20-aes-ref "" /aes/index.m3u8 -q
    read_on b20-aes b20-aes-ref "--stall 12:15000:1500" /aes/index.m3u8
    # 0108: fMP4 (mov keeps what came of the sample an interrupt cut and
    # reads its rest on the next call)
    run b20-fmp4-ref "" /vodfmp4/index.m3u8 -q
    read_on b20-fmp4 b20-fmp4-ref "--stall 12:15000:1500" /vodfmp4/index.m3u8
    # 0108: an audio sample begun before a refill (s12's at 32729 spans
    # 32768), 20 bytes of it in the refill before the interrupt
    read_on b20-fmp4-straddle b20-fmp4-ref "--stall 12:32788:1500" /vodfmp4/index.m3u8
    # 0108: the stall where s12's second video sample starts (7987): its
    # read gets nothing but the interrupt
    read_on b20-fmp4-zero b20-fmp4-ref "--stall 12:7987:1500" /vodfmp4/index.m3u8
    # 0108: s12's keyframe of 120093 bytes at 704 (avio_read() reads what
    # the buffer lacks of it past the buffer, which it then empties) cut at
    # 60000
    run b20-fmp4big-ref "" /vodfmp4big/index.m3u8 -q
    read_on b20-fmp4big b20-fmp4big-ref "--stall 12:60000:1500" /vodfmp4big/index.m3u8
    # 0111: the stall before s12's body: the interrupt cuts the read of the
    # next fragment's moof (stock mov forgot the fragment and ended the
    # playlist at the next call); and one inside the moof (704 bytes)
    read_on b20-fmp4-edge b20-fmp4-ref "--stall 12:0:1500" /vodfmp4/index.m3u8
    read_on b20-fmp4-moof b20-fmp4-ref "--stall 12:300:1500" /vodfmp4/index.m3u8
}
check_trunc() { # 0112: an interrupt where a truncated last segment ends
    # s19 sends 15000 bytes, waits and closes: the interrupt cuts a TS packet
    # or an fMP4 sample whose rest never comes; the input then ends (with
    # the interrupt latched, the cut was taken for an interrupt on every
    # call: AVERROR_EXIT without end)
    for kind in ts fmp4; do
        if [ $kind = ts ]; then path=/vod/index.m3u8; else path=/vodfmp4/index.m3u8; fi
        run trunc-$kind "--trunc 19:15000:1500" $path -q -stallint 300 -maxtime 15
        ints=$(grep -c 'interrupt at' "$OUT/trunc-$kind.log"); ex=$(field trunc-$kind exits)
        [ "$ints" -ge 1 ] && grep -q '^end: End of file' "$OUT/trunc-$kind.log"
        ok=$?; how=$(grep -E '^(end|maxtime)' "$OUT/trunc-$kind.log" | head -1)
        result trunc-$kind "interrupted ($ints), the input ends ($ex AVERROR_EXIT; $how)" $ok
    done
}
check_sidx() { # 0111: a seekable fragmented MP4 (sidx) reads as stock mov reads it
    # over http with byte ranges: the request for the file, mov's look at its
    # last 4 bytes (mfro), the one back to the first fragment, then in order
    # (0111's preload ran here too: a Range request where a fragment's atoms
    # spanned the buffer); the packets those of the file read from disk
    run sidx "" /prog/sidx.mp4 -q
    "$W/hlsread" "file:$W/media/sidx/sidx.mp4" -q > "$OUT/sidx-file.log" 2>&1
    req=$(grep -c 'GET /prog/sidx.mp4' "$OUT/sidx.server.log")
    want=$(field sidx-file s0); got=$(field sidx s0); wcrc=$(field sidx-file crc0); crc=$(field sidx crc0)
    [ "$req" = 3 ] && [ -n "$want" ] && [ "$got" = "$want" ] && [ -n "$wcrc" ] && [ "$crc" = "$wcrc" ]
    result sidx "3 requests ($req), all $want packets ($got), the file's data (crc $crc, $wcrc)" $?
}
check_chunk_trailer() { # 0106: a chunked reply with a trailer field, on a kept-alive connection
    run trailer-ref "" /vod/index.m3u8 -q
    run trailer "--chunked --trailer" /vod/index.m3u8 -q
    want=$(field trailer-ref s0); got=$(field trailer s0)
    req=$(grep -c 'GET /vod/s' "$OUT/trailer.server.log")
    conns=$(grep 'GET /vod/s' "$OUT/trailer.server.log" | sed 's/.*conn=//' | sort -u | wc -l | tr -d ' ')
    [ -n "$want" ] && [ "$got" = "$want" ] && [ "$req" = 20 ] && [ "$conns" -le 2 ]
    result chunk-trailer "all $want video packets ($got), 20 segment requests ($req) on kept-alive connections ($conns)" $?
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
check_bad_map() { # 0117, 0118: a garbled EXT-X-MAP on a live reload is played through
    # three reloads list the init section with BYTERANGE="-1": each fails as
    # the answer's error (0117: INVALIDDATA; it was ENOMEM, a local error that
    # failed the playlist at once), the playlist plays on from the last load,
    # and the next good answer is read (0118: a failed load closes its
    # kept-alive connection; its unread rest was read as the next answers,
    # failing them too)
    run bad-map "--bad-map 2:4" /livefmp4/index.m3u8 -q -maxtime 10
    fails=$(grep -c 'Failed to reload playlist' "$OUT/bad-map.log")
    played=$(field bad-map s0)
    [ "$fails" = 3 ] && grep -q '^maxtime' "$OUT/bad-map.log" && [ "${played:-0}" -gt 200 ] &&
        ! grep -q 'Cannot allocate memory' "$OUT/bad-map.log"
    result bad-map "three garbled reloads: three failures ($fails), played on to the end (s0=${played:-none})" $?
    # 0118: three live reloads cut half way (the whole Content-Length, half
    # the answer, the connection closed) fail as I/O errors and are retried,
    # the previous list kept; before, each truncated list was taken whole
    run cut-reload "--cut-reload 2:4" /live/index.m3u8 -q -maxtime 10
    fails=$(grep -c 'Failed to reload playlist 0: Input/output error, retrying' "$OUT/cut-reload.log")
    played=$(field cut-reload s0)
    after=$(awk '/cut after/ { c = NR } /GET \/live\/index.m3u8/ && c && NR > c + 1 { n++ } END { print n + 0 }' "$OUT/cut-reload.server.log")
    [ "$fails" = 3 ] && grep -q '^maxtime' "$OUT/cut-reload.log" && [ "${played:-0}" -gt 200 ] && [ "$after" -ge 3 ] &&
        ! grep -q 'skipping .* segments ahead' "$OUT/cut-reload.log"
    result cut-reload "three reloads cut half way: three I/O failures retried ($fails), the previous list kept (no segments skipped), $after reloads after them, played on (s0=${played:-none})" $?
    # 0118: a reload interrupted (a stall past the interrupt callback) is no
    # load: it fails as AVERROR_EXIT, not INVALIDDATA from the empty first
    # line, and does not stamp last_load_time, so the playlist is asked for
    # again at once (before, a reload interval after the stalled request)
    run stall-reload "--stall-reload 4:4000" /live/index.m3u8 -q -nofsi -maxtime 12 -stallint 1500
    gap=$(awk '/stall [0-9]+ ms before the body/ { s = t } /GET \/live\/index.m3u8/ { if (s != "" && g == "") g = $1 - s; t = $1 } END { print g }' "$OUT/stall-reload.server.log")
    played=$(field stall-reload s0)
    grep -q '^interrupt at' "$OUT/stall-reload.log" && ! grep -q 'Failed to reload playlist' "$OUT/stall-reload.log" &&
        grep -q '^maxtime' "$OUT/stall-reload.log" && [ "${played:-0}" -gt 200 ] &&
        awk -v g="$gap" 'BEGIN { exit !(g != "" && g + 0 < 0.85) }'
    result stall-reload "a reload stalled and interrupted: no failure logged, asked for again ${gap:-never} s after the stalled request, played on (s0=${played:-none})" $?
}
check_vod_init() { # 0119: a finished playlist's init section failure is its segment's
    # (seg_max_retry, seg_skip): retried and skipped, not the playlist's end.
    # gapmap: s3 and s4 map a missing section (404), s5 and s6 init.mp4
    # again: both skipped, s5 and s6 asked for and played (0101's drop of the
    # skipped segment's early open: otherwise the early-opened s3 is read in
    # place of s5, which is never asked for); init.mp4 503 once: the open
    # skips s0 and plays on
    run vod-init-gap "" /vodfmp4/gapmap.m3u8 -q -maxtime 20
    s5=$(grep -c 'GET /vodfmp4/s5.m4s ' "$OUT/vod-init-gap.server.log")
    s6=$(grep -c 'GET /vodfmp4/s6.m4s ' "$OUT/vod-init-gap.server.log")
    last=$(field vod-init-gap last_pts0)
    [ "$s5" = 1 ] && [ "$s6" = 1 ] && grep -q '^end: End of file' "$OUT/vod-init-gap.log" &&
        [ "$(grep -c 'Initialization section of segment [34] .*skipping the segment' "$OUT/vod-init-gap.log")" = 2 ] &&
        awk -v l="$last" 'BEGIN { exit !(l + 0 >= 6.5) }'
    result vod-init-gap "a VOD whose s3-s4 map a missing init section: both skipped, s5 and s6 asked for ($s5, $s6) and played to the end (last pts ${last:-none})" $?
    run vod-init-503 "--vod-init-fail 1" /vodfmp4/index.m3u8 -q -maxtime 20
    last=$(field vod-init-503 last_pts0)
    grep -q '^end: End of file' "$OUT/vod-init-503.log" && awk -v l="$last" 'BEGIN { exit !(l + 0 >= 19) }'
    result vod-init-503 "a VOD's init section 503 once: its segment skipped, played to the end (last pts ${last:-none})" $?
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
    # 0121: an AES-128 init section whose EXT-X-KEY has no IV (its IV is the
    # media sequence number of the segment after the MAP line, which moves
    # with each reload)
    run dedup-aes "" /livefmp4aes/index.m3u8 -q -maxtime 6
    req=$(grep -c 'GET /livefmp4aes/init.mp4' "$OUT/dedup-aes.server.log")
    reloads=$(grep -c 'GET /livefmp4aes/index.m3u8' "$OUT/dedup-aes.server.log")
    played=$(field dedup-aes s0)
    warned=$(grep -c 'AES-128 EXT-X-MAP without an IV' "$OUT/dedup-aes.log")
    [ "$req" = 1 ] && [ "$reloads" -ge 4 ] && [ "${played:-0}" -gt 100 ] && [ "$warned" = 1 ]
    result init-dedup-aes "a keyed init section without an IV requested once over $reloads playlist loads ($req), played (s0=${played:-none}), logged once ($warned)" $?
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

# vswitch's helpers. first NAME STREAM: "pts dts key=K" of the stream's first
# packet after the last group of events (hlsread numbers the groups of events
# that fire together, groups= in its summary: crcaN covers the packets after
# the last group too); nothing when the stream gave none after it
first() {
    e=$(field "$1" groups)
    [ -n "$e" ] && [ "$e" -gt 0 ] && grep "^first $e $2 " "$OUT/$1.log" | head -1 | cut -d' ' -f4-
}
# evdts NAME: the dts of the packet the (last) events fired at, the position
evdts() { sed -n 's/^event [0-9]* at [0-9.-]* dts \([0-9.-]*\):.*/\1/p' "$OUT/$1.log" | tail -1; }
# gets NAME PATH: how many times the server was asked for PATH
gets() { grep -c "GET $2 " "$OUT/$1.server.log"; }
# keyed NAME STREAM REF REFSTREAM: the stream's first packet after the events
# is a keyframe, and its packets from there are those of the variant's own
# playlist read alone after a keyed seek to the same segment (byte for byte)
keyed() {
    f=$(first "$1" "$2"); want=$(field "$3" "crca$4"); got=$(field "$1" "crca$2")
    case "$f" in *key=1) ;; *) return 1;; esac
    [ -n "$want" ] && [ "$want" != 00000000 ] && [ "$got" = "$want" ]
}
# near NAME STREAM LO HI: the stream's first packet after the events has a
# dts in [LO, HI] s
near() {
    d=$(first "$1" "$2" | cut -d' ' -f2)
    awk -v d="$d" -v lo="$3" -v hi="$4" 'BEGIN { exit !(d != "" && d + 0 >= lo && d + 0 <= hi) }'
}
check_vswitch() { # 0113-0116: a video playlist needed anew starts at its segment's keyframe
    # media/mv: 6 s segments, a 6 s GOP; the timeline's segment 2 starts at
    # 13.48 (the video keyframe's PTS; its DTS is 13.40). At 16.12 a player
    # switches its video (v1 -> v2) or seeks to 16 (RMP: the discards are set
    # first, the seek follows, stream -1 is RMP's default video or audio).
    # Streams of master.m3u8: 0 a, 1 a2 (audio renditions), 2 v1, 3 v2.
    # Before 0113 the new video started on the P-frames at the position
    # (its playlist's catch-up was AVSEEK_FLAG_ANY), or after the keyframe
    # at 13.40 that the seek's cutoff at 13.48 dropped.
    for v in v1 v2 m2 f1 f2; do
        run "kf-ref-$v" "" "/mv/$v/index.m3u8" -q -ev 1.6:seek:16:0
    done
    # a seek on the audio stream: the video playlist is not the seek playlist
    run kf-seek-audio "" /mv/master.m3u8 -q -discard 1 -discard 3 -ev 16:seek:16:0
    keyed kf-seek-audio 2 kf-ref-v1 0 && near kf-seek-audio 2 13.3 13.5
    ok=$?
    result kf-seek-audio "a seek on the audio: the video from its segment's keyframe ($(first kf-seek-audio 2))" $ok
    # a switch, then a seek on the new video (it is the seek playlist, but
    # newly needed: its catch-up replaced the seek's cutoff)
    run kf-switch-seek "" /mv/master.m3u8 -q -discard 1 -discard 3 -ev 16:off:2 -ev 16:on:3 -ev 16:seek:16:3
    keyed kf-switch-seek 3 kf-ref-v2 0 && near kf-switch-seek 3 13.3 13.5
    ok=$?
    result kf-switch-seek "v1 -> v2 and a seek on v2: v2 from its segment's keyframe ($(first kf-switch-seek 3))" $ok
    run kf-switch-seek-audio "" /mv/master.m3u8 -q -discard 1 -discard 3 -ev 16:off:2 -ev 16:on:3 -ev 16:seek:16:0
    keyed kf-switch-seek-audio 3 kf-ref-v2 0 && near kf-switch-seek-audio 3 13.3 13.5
    ok=$?
    result kf-switch-seek-audio "v1 -> v2 and a seek on the audio: v2 from its segment's keyframe ($(first kf-switch-seek-audio 3))" $ok
    # a switch during playback, no seek
    run kf-switch "" /mv/master.m3u8 -q -discard 1 -discard 3 -ev 16:off:2 -ev 16:on:3
    keyed kf-switch 3 kf-ref-v2 0 && near kf-switch 3 13.3 13.5
    ok=$?
    result kf-switch "v1 -> v2 during playback: v2 from its segment's keyframe ($(first kf-switch 3))" $ok
    # the same in fMP4 (0114: stock read the probe's stale bytes, and the new
    # variant gave no packet at all)
    # (0115: f2's init section, buffered since the open, is served again,
    # not asked for a second time)
    run kf-switch-fmp4 "" /mv/fmp4.m3u8 -q -discard 2 -ev 16:off:1 -ev 16:on:2
    keyed kf-switch-fmp4 2 kf-ref-f2 0 && [ "$(gets kf-switch-fmp4 /mv/f2/init.mp4)" = 1 ]
    ok=$?
    result kf-switch-fmp4 "f1 -> f2 (fMP4) during playback: f2 from its segment's keyframe ($(first kf-switch-fmp4 2)), its init section asked for once ($(gets kf-switch-fmp4 /mv/f2/init.mp4))" $ok
    # 0115: a seek serves the buffered init section again (stock asked for
    # it again on every seek)
    run init-seek "" /mv/fmp4.m3u8 -q -discard 2 -ev 16:seek:16:1
    keyed init-seek 1 kf-ref-f1 0 && [ "$(gets init-seek /mv/f1/init.mp4)" = 1 ]
    ok=$?
    result init-seek "a seek on fMP4: f1 from its segment's keyframe ($(first init-seek 1)), its init section asked for once ($(gets init-seek /mv/f1/init.mp4))" $ok
    # muxed variants (streams 0 m1 video, 1 m1 audio, 2 m2 video, 3 m2
    # audio): the video from its keyframe, the audio still at the position
    # (not a segment back), and none of the stale probe data (0114)
    run kf-switch-mux "" /mv/mux.m3u8 -q -discard 2 -discard 3 -ev 16:off:0 -ev 16:off:1 -ev 16:on:2 -ev 16:on:3
    keyed kf-switch-mux 2 kf-ref-m2 0 && near kf-switch-mux 2 13.3 13.5 && near kf-switch-mux 3 15.8 16.6
    ok=$?
    result kf-switch-mux "m1 -> m2 during playback: the video from its segment's keyframe ($(first kf-switch-mux 2)), the audio at the position ($(first kf-switch-mux 3))" $ok
    # no keyframe flag before the position (n1 has one keyframe, at its
    # start): the video at the position, as before (not never)
    run kf-nokey "" /mv/nokey.m3u8 -q -discard 2 -ev 16:off:1 -ev 16:on:2
    near kf-nokey 2 15.8 16.3
    ok=$?
    result kf-nokey "v1 -> n1 (no keyframe): n1 at the position, as stock ($(first kf-nokey 2))" $ok
    # 0114: an audio rendition taken again during playback starts at the
    # position (its catch-up stays AVSEEK_FLAG_ANY): the same packets as the
    # rendition it replaces (the same media) from there, no stale ones from
    # the open's probe, none corrupt
    run afresh-ref "" /mv/master.m3u8 -q -discard 1 -discard 3 -ev 16:off:3
    run afresh-audio "" /mv/master.m3u8 -q -discard 1 -discard 3 -ev 16:off:0 -ev 16:on:1
    want=$(field afresh-ref crca0); got=$(field afresh-audio crca1)
    [ -n "$want" ] && [ "$got" = "$want" ] && near afresh-audio 1 15.8 16.3 &&
        ! grep -q 'hls.*Packet corrupt (stream = 1,' "$OUT/afresh-audio.log"
    ok=$?
    result afresh-audio "a -> a2 during playback: a2 at the position ($(first afresh-audio 1)), its packets a's (crc $got, $want)" $ok
    # the first segment (idx 0: the cutoff a segment before the playlist's
    # start): a switch and a seek to 2 s give v2 from its first keyframe
    run kf-ref0-v2 "" /mv/v2/index.m3u8 -q -ev 3:seek:2:0
    run kf-first-seg "" /mv/master.m3u8 -q -discard 1 -discard 3 -ev 3:off:2 -ev 3:on:3 -ev 3:seek:2:3
    keyed kf-first-seg 3 kf-ref0-v2 0 && near kf-first-seg 3 1.3 1.5
    ok=$?
    result kf-first-seg "v1 -> v2 and a seek to 2 s: v2 from the first segment's keyframe ($(first kf-first-seg 3))" $ok
    # an EXT-X-MAP from the fourth segment on (/mv/latemap: its init.ts holds
    # media packets from 30 s, so an init section served where none is mapped
    # shows): a seek back before the first MAP, the init section buffered,
    # serves none (0115 rewound the buffered one, and update_init_section()
    # forgot it without ending its serve: the 30 s packets came first); a
    # seek past it serves the buffered one again, as a fresh read fetches it
    run latemap-ref1 "" /mv/latemap/index.m3u8 -q -ev 0:seek:1:0
    run latemap-before "" /mv/latemap/index.m3u8 -q -ev 28:seek:1:0
    keyed latemap-before 0 latemap-ref1 0 && near latemap-before 0 1.3 1.5
    ok=$?
    result latemap-before "a seek before the first EXT-X-MAP, its init section buffered: none served ($(first latemap-before 0))" $ok
    run latemap-ref25 "" /mv/latemap/index.m3u8 -q -ev 0:seek:25:0
    run latemap-after "" /mv/latemap/index.m3u8 -q -ev 28:seek:25:0
    keyed latemap-after 0 latemap-ref25 0 && [ "$(gets latemap-after /mv/latemap/init.ts)" = 1 ]
    ok=$?
    result latemap-after "a seek past the first EXT-X-MAP: the buffered init section served again, as a fresh read's ($(first latemap-after 0)), asked for once ($(gets latemap-after /mv/latemap/init.ts))" $ok
    # live (/live/master.m3u8: two variants of the live TS, 1 s segments,
    # 0 video 1 audio, 2 video 3 audio), switched 7.5 s after the first
    # packet, no seek: the new variant's video starts at the position, as
    # stock's AVSEEK_FLAG_ANY catch-up does (0113 leaves live playlists
    # alone; it would start at the segment's keyframe, up to a segment
    # early), in both orders of the discards. 0116: the catch-up no longer
    # ended at the rest of an audio PES it had dropped (the video came up to
    # 0.5 s before the position); 0114: no stale probe data first
    for late in "" -late; do
        name=live-switch$late
        run $name "" /live/master.m3u8 -q -maxtime 16 $late -discard 2 -discard 3 \
            -ev +7.5:off:0 -ev +7.5:off:1 -ev +7.5:on:2 -ev +7.5:on:3
        pos=$(evdts $name)
        [ -n "$pos" ] &&
            near $name 2 "$(awk -v p="$pos" 'BEGIN { print p - 0.05 }')" "$(awk -v p="$pos" 'BEGIN { print p + 0.6 }')"
        ok=$?
        result $name "live${late:+ (late discards)}, variant switch at ${pos:-(no event fired)}: the new video at the position ($(first $name 2))" $ok
    done
    # RMP's order: avformat_find_stream_info() with every stream, the
    # discards after it (-late). hls reads the discarded playlists on until
    # they need a segment, and drops them there with that segment's early
    # open pending; before 0114 that connection was read in place of the
    # segment due when the playlist was needed again, and the next segments
    # were never asked for (the new video and audio came at 25.4 s)
    run kf-late-switch-seek "" /mv/master.m3u8 -q -late -discard 1 -discard 3 -ev 16:off:2 -ev 16:on:3 -ev 16:seek:16:3
    keyed kf-late-switch-seek 3 kf-ref-v2 0 && near kf-late-switch-seek 3 13.3 13.5
    ok=$?
    result kf-late-switch-seek "late discards, v1 -> v2 and a seek on v2: v2 from its segment's keyframe ($(first kf-late-switch-seek 3))" $ok
    run kf-late-switch "" /mv/master.m3u8 -q -late -discard 1 -discard 3 -ev 16:off:2 -ev 16:on:3
    keyed kf-late-switch 3 kf-ref-v2 0 && near kf-late-switch 3 13.3 13.5
    ok=$?
    result kf-late-switch "late discards, v1 -> v2 during playback: v2 from its segment's keyframe ($(first kf-late-switch 3))" $ok
    run kf-late-switch-fmp4 "" /mv/fmp4.m3u8 -q -late -discard 2 -ev 16:off:1 -ev 16:on:2
    keyed kf-late-switch-fmp4 2 kf-ref-f2 0 && [ "$(gets kf-late-switch-fmp4 /mv/f2/init.mp4)" = 1 ]
    ok=$?
    result kf-late-switch-fmp4 "late discards, f1 -> f2 (fMP4) during playback: f2 from its segment's keyframe ($(first kf-late-switch-fmp4 2)), its init section asked for once ($(gets kf-late-switch-fmp4 /mv/f2/init.mp4))" $ok
    run afresh-late-ref "" /mv/master.m3u8 -q -late -discard 1 -discard 3 -ev 16:off:3
    run afresh-late-audio "" /mv/master.m3u8 -q -late -discard 1 -discard 3 -ev 16:off:0 -ev 16:on:1
    want=$(field afresh-late-ref crca0); got=$(field afresh-late-audio crca1)
    [ -n "$want" ] && [ "$got" = "$want" ] && near afresh-late-audio 1 15.8 16.3
    ok=$?
    result afresh-late-audio "late discards, a -> a2 during playback: a2 at the position ($(first afresh-late-audio 1)), its packets a's (crc $got, $want)" $ok
}

CHECKS=${*:-b19 b20 trunc chunk_trailer sidx id3 i51 i52 bad_map vod_init init_dedup init_cut headers_origin i54 cut_body vswitch}
for c in $CHECKS; do "check_$(echo "$c" | tr - _)"; done
exit $FAIL
