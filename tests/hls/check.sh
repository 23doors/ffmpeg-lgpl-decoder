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
#   checks: b19 b20 trunc chunk-trailer sidx id3 i51 i52 bad-map vod-init init-dedup init-cut
#           headers-origin i54 cut-body vswitch conn-host cookies status-line
#           bad-range crlf http-reply
#   (default: all)
set -u
W=$(cd "$1" && pwd); shift
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$W/out"; mkdir -p "$OUT"
# a harness older than hlsread.c reports less (no CRCs before round 3's):
# setup.sh builds it again
for tool in hlsread httpread; do
    if [ "$HERE/$tool.c" -nt "$W/$tool" ]; then
        echo "FAIL harness: $W/$tool is older than $HERE/$tool.c (run setup.sh $W)"
        exit 1
    fi
done
export HLS_FIXTURE_MEDIA="$W/media"
PORT=${PORT:-18790}
FAIL=0
# each run capped at 60 s (CAPS: other seconds): timeout (GNU coreutils, Linux) or gtimeout (its
# Homebrew name on macOS); without either the runs go uncapped
CAP=$(command -v timeout || command -v gtimeout || true)
[ -n "$CAP" ] || echo "note: no timeout or gtimeout, runs are not capped"
cap() { if [ -n "$CAP" ]; then "$CAP" "${CAPS:-60}" "$@"; else "$@"; fi; }
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

# runh NAME "server args" PATH [httpread args]: httpread on PATH of origin A,
# server.py on two ports (A_PORT, B_PORT: origins A and B); the logs as run's;
# HOST: the address asked for (127.0.0.1); URL: the whole URL instead (the
# ports are PORT + 1 and PORT + 2 before the call)
runh() {
    name=$1; sargs=$2; path=$3; shift 3
    PORT=$((PORT + 2)); A_PORT=$((PORT - 1)); B_PORT=$PORT
    python3 -I "$HERE/server.py" $A_PORT --second-port $B_PORT $sargs > "$OUT/$name.server.log" 2>&1 &
    srv=$!
    i=0
    until grep -q listening "$OUT/$name.server.log" 2>/dev/null || [ $i -ge 50 ]; do
        sleep 0.1; i=$((i + 1))
    done
    url=${URL:-http://${HOST:-127.0.0.1}:$A_PORT$path}
    cap "$W/httpread" "$url" "$@" > "$OUT/$name.log" 2>&1
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
}
# readcrc NAME K: the CRC of httpread's K-th read
readcrc() { grep '^read ' "$OUT/$1.log" | sed -n "$2s/.* crc=\([0-9a-f]*\) .*/\1/p"; }
check_conn_host() { # 0122 (b66d2aca0f): a kept-alive connection serves only its own host
    # A redirects to B (/rd/ -> /range/, ranged replies); a seek back inside
    # a ranged reply drains its rest and keeps the connection (a soft seek)
    # and asks for the opened URL again: before b66d2aca0f that request, with
    # A's Host and headers (0104 sends them: it is A's URL), went out on the
    # connection to B
    runh conn-host-ref "" /rd/file.ts -direct r:1000 r:1000
    runh conn-host "" /rd/file.ts -direct -o multiple_requests=1 -o request_size=100000 \
        -o short_seek_size=1000000 -o "headers=X-Token: secret" r:50000 s:1000 r:1000
    log="$OUT/conn-host.server.log"
    on_a=$(grep -c "GET /rd/file.ts port=$A_PORT " "$log")
    on_b=$(grep -c "GET /rd/file.ts port=$B_PORT " "$log")
    leak=$(grep "port=$B_PORT " "$log" | grep -c 'token=yes')
    want=$(readcrc conn-host-ref 2); got=$(readcrc conn-host 2)
    [ "$on_a" = 2 ] && [ "$on_b" = 0 ] && [ "$leak" = 0 ] && [ -n "$want" ] && [ "$got" = "$want" ]
    result conn-host "A's URL asked of A after the seek ($on_a on A, $on_b on B's connection), the token never to B ($leak), the bytes after the seek right ($got, $want)" $?
}

# cookie NAME PORT PATH: the Cookie of the (first) request for PATH on PORT
# ("-" without one, nothing when there was no such request)
cookie() {
    grep "GET $3 port=$2 " "$OUT/$1.server.log" | head -1 |
        sed -n 's/.* cookie=\([^ ]*\) .*/\1/p; t; s/.*GET .*/-/p'
}
NL='
'
check_cookies() { # 0123-0134: the cookie series (88fbd111ea ... de6fb646f7)
    # 0123: a Domain is matched against the host, not host:port (a cookie
    # with a Domain never went to a URL with a port)
    runh ck-port "" /range/file.ts -direct -o "cookies=d=1; Domain=127.0.0.1; Path=/" r:1000
    c=$(cookie ck-port $A_PORT /range/file.ts)
    [ "$c" = d=1 ]; result cookie-port "Domain=127.0.0.1 goes to 127.0.0.1:port ($c)" $?
    # 0124: a Domain matches only at a label boundary (Domain=calhost went
    # to localhost)
    HOST=localhost
    runh ck-label "" /range/file.ts -direct \
        -o "cookies=l=1; Domain=calhost; Path=/${NL}m=1; Domain=localhost; Path=/" r:1000
    HOST=
    c=$(cookie ck-label $A_PORT /range/file.ts)
    [ "$c" = m=1 ]; result cookie-label "Domain=calhost not to localhost, Domain=localhost to it ($c)" $?
    # 0125: a Path matches only at a segment boundary (Path=/ran went to /range/)
    runh ck-segment "" /range/file.ts -direct -o "cookies=p=1; Path=/ran${NL}q=1; Path=/range" r:1000
    c=$(cookie ck-segment $A_PORT /range/file.ts)
    [ "$c" = q=1 ]; result cookie-segment "Path=/ran not to /range/, Path=/range to it ($c)" $?
    # 0126: a cookie a reply sets without a Domain goes back only to its host
    # (127.0.0.1's session cookie went to localhost after its redirect there;
    # cookies are scoped by host, not port)
    runh ck-set-hostonly "" "/rdc/file.ts?c=sess%3Dabc%3B%20Path%3D%2F&h=localhost" -direct r:1000
    c=$(cookie ck-set-hostonly $B_PORT /range/file.ts)
    [ "$c" = - ]; result cookie-set-hostonly "127.0.0.1's Set-Cookie without a Domain not sent to localhost ($c)" $?
    # 0127: a reply's cookie for a Domain that does not cover its host is
    # ignored (127.0.0.1 set one for localhost, which got it)
    runh ck-foreign "" "/rdc/file.ts?c=inj%3D1%3B%20Domain%3Dlocalhost%3B%20Path%3D%2F&h=localhost" -direct r:1000
    c=$(cookie ck-foreign $B_PORT /range/file.ts)
    [ "$c" = - ]; result cookie-foreign "127.0.0.1's Set-Cookie for Domain=localhost ignored ($c at localhost)" $?
    # 0128: paths match case-sensitively (Path=/RANGE went to /range/)
    runh ck-case "" /range/file.ts -direct -o "cookies=c=1; Path=/RANGE${NL}k=1; Path=/range" r:1000
    c=$(cookie ck-case $A_PORT /range/file.ts)
    [ "$c" = k=1 ]; result cookie-case "Path=/RANGE not to /range/, Path=/range to it ($c)" $?
    # 0129: behind a proxy the Path is matched against the request's path,
    # not the whole URL the proxy is asked for (no cookie with a Path went);
    # the proxy is B (runh's second port)
    runh ck-proxy "" /range/file.ts -direct -o "http_proxy=http://127.0.0.1:$((PORT + 2))" \
        -o "cookies=pp=1; Path=/range" r:1000
    c=$(grep 'GET /range/file.ts .* proxied' "$OUT/ck-proxy.server.log" | head -1 | sed -n 's/.* cookie=\([^ ]*\) .*/\1/p')
    [ "$c" = pp=1 ]; result cookie-proxy "Path=/range sent through the proxy (${c:--})" $?
    # 0130: a Domain matches an IP address only exactly (Domain=0.0.1 went
    # to 127.0.0.1)
    runh ck-ip "" /range/file.ts -direct -o "cookies=ip=1; Domain=0.0.1; Path=/${NL}ok=1; Domain=127.0.0.1; Path=/" r:1000
    c=$(cookie ck-ip $A_PORT /range/file.ts)
    [ "$c" = ok=1 ]; result cookie-ip "Domain=0.0.1 not to 127.0.0.1, Domain=127.0.0.1 to it ($c)" $?
    # 0131, 0133: a Secure cookie goes over https only (0131 keeps the bare
    # Secure attribute, which parse_set_cookie() dropped; 0133 checks it)
    runh ck-secure "" /range/file.ts -direct -o "cookies=s=1; Secure; Path=/${NL}n=1; Path=/" r:1000
    c=$(cookie ck-secure $A_PORT /range/file.ts)
    [ "$c" = n=1 ]; result cookie-secure "a Secure cookie not over http, a plain one sent ($c)" $?
    # 0132: an attribute name is trimmed ("Path =/other" was no Path)
    runh ck-attr-space "" /range/file.ts -direct -o "cookies=w=1; Path =/other${NL}v=1; Path=/" r:1000
    c=$(cookie ck-attr-space $A_PORT /range/file.ts)
    [ "$c" = v=1 ]; result cookie-attr-space "\"Path =/other\" not to /range/, Path=/ to it ($c)" $?
    # 0134: a cookie given without a Domain goes only to the opened URL's
    # host (it went to localhost after 127.0.0.1's redirect); 127.0.0.1 gets it
    runh ck-given-hostonly "" "/rdc/file.ts?h=localhost" -direct -o "cookies=g=1; Path=/" r:1000
    a=$(cookie ck-given-hostonly $A_PORT /rdc/file.ts); b=$(cookie ck-given-hostonly $B_PORT /range/file.ts)
    [ "$a" = g=1 ] && [ "$b" = - ]; result cookie-given-hostonly "a given cookie without a Domain to 127.0.0.1 ($a), not to localhost after its redirect ($b)" $?
    # 0134 in hls (RMP's case: the cookies option copied to every playlist
    # and segment request): /xo/'s playlist on 127.0.0.1 names s1 on
    # localhost; s0 and s4 on 127.0.0.1 get the cookie, s1 does not
    run2h() {
        PORT=$((PORT + 2)); A_PORT=$((PORT - 1)); B_PORT=$PORT
        python3 -I "$HERE/server.py" $A_PORT --second-port $B_PORT > "$OUT/$1.server.log" 2>&1 &
        srv=$!
        i=0
        until grep -q listening "$OUT/$1.server.log" 2>/dev/null || [ $i -ge 50 ]; do
            sleep 0.1; i=$((i + 1))
        done
        cap "$W/hlsread" "http://127.0.0.1:$A_PORT/xo/index.m3u8?h=localhost" -q -o http_multiple=0 \
            -o "cookies=hc=1; Path=/" > "$OUT/$1.log" 2>&1
        kill $srv 2>/dev/null; wait $srv 2>/dev/null
    }
    run2h ck-hls
    s0=$(cookie ck-hls $A_PORT /xo/s0.ts); s1=$(cookie ck-hls $B_PORT /xo/s1.ts); s4=$(cookie ck-hls $A_PORT /xo/s4.ts)
    segs=$(grep -c 'GET /xo/s[0-9]' "$OUT/ck-hls.server.log")
    [ "$s0" = hc=1 ] && [ "$s4" = hc=1 ] && [ "$s1" = - ] && [ "$segs" = 5 ]
    result cookie-hls "hls: a given cookie to the playlist's host (s0 $s0, s4 $s4), not to a segment on localhost (s1 $s1; $segs segments)" $?
}

check_status_line() { # 0136 (e48a073d7e), 0137: malformed status lines fail the open
    # before e48a073d7e they read as status 0, a success: the body (of an
    # error, or of no http server) went to the demuxer
    for kind in nocode short plus badver; do
        runh st-$kind "" /status/$kind -direct r:100
        line=$(grep -E '^(open failed|read )' "$OUT/st-$kind.log" | head -1)
        grep -q '^open failed: Invalid data' "$OUT/st-$kind.log"
        result status-$kind "the status line of /status/$kind fails the open ($line)" $?
    done
    # 0137: SHOUTcast's "ICY 200 OK" still opens (e48a073d7e rejects it;
    # upstream reads ICY through libcurl, which the pack does not build) and
    # "ICY 404" is an error now (it read as status 0 before e48a073d7e)
    runh st-icy "" /status/icy -direct ra
    runh st-icy404 "" /status/icy404 -direct ra
    a=$(grep -E '^(open failed|read )' "$OUT/st-icy.log" | head -1)
    b=$(grep -E '^(open failed|read )' "$OUT/st-icy404.log" | head -1)
    # (a body without a length, ended by the close, reads as cut: EIO, as
    # stock http has it since 1306e5c7d3 so that a live stream reconnects)
    grep -q '^read -1 got 4096 ' "$OUT/st-icy.log" &&
        grep -q '^open failed: Server returned 404' "$OUT/st-icy404.log"
    result status-icy "ICY 200 reads its 4096 bytes ($a), ICY 404 fails ($b)" $?
    # a bare "HTTP/1.1 200" (no reason) still opens
    runh st-bare "" /status/bare -direct ra
    grep -q '^read -1 got 4096 ' "$OUT/st-bare.log"
    result status-bare "HTTP/1.1 200 without a reason reads its body" $?
}
check_bad_range() { # 0138 (2ff5405601): a Content-Range ending before its start fails the open
    # (before, http asked again and again for the rest: capped at 10 s here)
    CAPS=10
    runh badrange "" /badrange/file.ts -direct ra
    CAPS=
    req=$(grep -c 'GET /badrange/' "$OUT/badrange.server.log")
    grep -q '^open failed: Invalid data' "$OUT/badrange.log" && [ "$req" = 1 ]
    result bad-range "Content-Range 100-50 fails the open with INVALIDDATA, one request ($req)" $?
}
check_crlf() { # 0139, 0140: CR/LF in a proxied host or a CONNECT target is no request
    # 0140 (6d898e0c17): a host with CR LF through a proxy (B): the Host line
    # carried the injected header; now the open fails and B gets nothing
    a=$((PORT + 1)); b=$((PORT + 2))
    URL=$(printf 'http://h\r\nX-Injected: yes\r\nx/range/file.ts')
    runh crlf-host "" - -direct -o "http_proxy=http://127.0.0.1:$b" r:100
    URL=
    req=$(grep -c -E '^ *[0-9.]+ (GET|CONNECT) ' "$OUT/crlf-host.server.log")
    grep -q '^open failed: Invalid argument' "$OUT/crlf-host.log" && [ "$req" = 0 ]
    result crlf-host "a host with CR LF through a proxy: no request ($req), the open fails" $?
    # 0139 (1bdc17e2c8): the httpproxy protocol's CONNECT target (not in the
    # pack's build: tests/hls enables it for this check)
    a=$((PORT + 1))
    URL=$(printf 'httpproxy://127.0.0.1:%d/h:80\r\nX-Injected: yes' $a)
    runh crlf-connect "" - r:1
    URL=
    req=$(grep -c 'CONNECT ' "$OUT/crlf-connect.server.log")
    grep -q '^open failed: Invalid argument' "$OUT/crlf-connect.log" && [ "$req" = 0 ]
    result crlf-connect "a CONNECT target with CR LF: no request ($req), the open fails" $?
}

# hread NAME K: httpread's K-th read line ("read N got M crc=C end=E")
hread() { grep '^read ' "$OUT/$1.log" | sed -n "$2p"; }
check_http_reply() { # 0141-0154: seeks, ends and ranged replies (June and October upstream series)
    runh rr-ref "" /range/file.ts -direct r:1000 r:1000
    runh rr-full "" /range/file.ts -direct ra
    at1000=$(readcrc rr-ref 2); full=$(readcrc rr-full 1)
    # 0141 (557ab6f2ab): a seek when the connection's short seek size is an
    # error (ENOSYS: Windows' tcp, tls over a proxy's tunnel; here https
    # through this server as the proxy) is no soft seek: one compared the
    # error as unsigned, so any seek drained the whole rest of the reply first
    runh short-seek-ref "" /range/file.ts -direct r:50000 r:1000
    a=$((PORT + 1))
    URL=https://localhost:$a/range/file.ts
    runh short-seek "--tls" - -direct -debug -o http_proxy=http://127.0.0.1:$a \
        -o multiple_requests=1 r:1000 s:50000 r:1000
    URL=
    tunnels=$(grep -c 'CONNECT ' "$OUT/short-seek.server.log")
    ! grep -q 'Soft-seeking' "$OUT/short-seek.log" && [ "$tunnels" = 2 ] &&
        [ "$(readcrc short-seek 2)" = "$(readcrc short-seek-ref 2)" ]
    ok=$?
    result short-seek "https through a proxy, a seek on: no drain, a new tunnel ($tunnels; $(grep -o 'draining [0-9]* ' "$OUT/short-seek.log"))" $ok
    # a seek back inside a reply on a connection the server closes after it:
    # the soft seek drained it and asked again on the dead connection, the
    # seek failed with EOF and the input ended (0143 f87323a359: a new
    # connection then; 0144 bd51105806: no soft seek when "Connection:
    # close" was sent, whatever the reply says; 0145 e5a3c5e409: "Close"
    # is close)
    runh seek-closed "" "/range/file.ts?close=1" -direct -o multiple_requests=1 r:140000 s:1000 r:1000
    got=$(readcrc seek-closed 2)
    grep -q '^seek 1000 ret=1000' "$OUT/seek-closed.log" && [ -n "$at1000" ] && [ "$got" = "$at1000" ]
    ok=$?
    result seek-closed "keep-alive asked, the server closes: a seek back reads on a new connection ($(hread seek-closed 2))" $ok
    runh seek-close-sent "" /range/file.ts -direct -debug r:140000 s:1000 r:1000
    got=$(readcrc seek-close-sent 2)
    ! grep -q 'Soft-seeking' "$OUT/seek-close-sent.log" && [ "$got" = "$at1000" ]
    ok=$?
    result seek-close-sent "Connection: close sent, none in the reply: a seek back is no soft seek ($(hread seek-close-sent 2))" $ok
    runh seek-Close "" "/range/file.ts?conn=Close" -direct -debug -o multiple_requests=1 r:140000 s:1000 r:1000
    got=$(readcrc seek-Close 2)
    ! grep -q 'Soft-seeking' "$OUT/seek-Close.log" && [ "$got" = "$at1000" ]
    ok=$?
    result seek-Close "\"Connection: Close\" in the reply: a seek back is no soft seek ($(hread seek-Close 2))" $ok
    # 0142 (62006041cc): a read with no connection before the end is an
    # error, not the end (a soft seek found the connection closed and the
    # new one's request failed, 503: no connection is left)
    runh io-not-eof "" "/range/file.ts?close=1&fail=1" -direct -o multiple_requests=1 r:140000 s:1000 r:100
    hread io-not-eof 2 | grep -q 'got 0 .* end=Input/output error'
    ok=$?
    result io-not-eof "after a failed seek, a read is EIO, not EOF ($(hread io-not-eof 2))" $ok
    # 0147 (17afe2331a): a seek past the end drops the old reply (its
    # buffered bytes, which came with the headers, were read at the new
    # offset)
    runh past-end "" "/range/file.ts?onewrite=1" -direct r:1000 s:151600 r:100
    hread past-end 2 | grep -q 'got 0 .* end=eof'
    ok=$?
    result past-end "a read after a seek past the end gets nothing ($(hread past-end 2))" $ok
    # 0148 (5db1e097dc): a read up to end_offset ends with EOF (it was EIO)
    runh end-offset "" /range/file.ts -direct -o end_offset=5000 ra
    hread end-offset 1 | grep -q 'got 5000 .* end=eof'
    ok=$?
    result end-offset "end_offset=5000: 5000 bytes, then EOF ($(hread end-offset 1))" $ok
    # 0153 (461f48ece8): an end_offset past the file's end asks for nothing
    # past it (a request for the bytes past the end got 416, the read's end)
    runh end-past-file "" /range/file.ts -direct -o multiple_requests=1 -o end_offset=200000 ra
    req=$(grep -c 'GET /range/' "$OUT/end-past-file.server.log")
    hread end-past-file 1 | grep -q 'got 151528 .* end=eof' && [ "$req" = 1 ]
    ok=$?
    result end-past-file "end_offset past the end: the file, EOF, one request ($req; $(hread end-past-file 1))" $ok
    # 0149 (ca5300c9f4): a chunked partial reply (request_size) is continued
    # with the next request (it ended at the first range's end)
    runh chunk-range "" "/range/file.ts?chunked=1" -direct -o multiple_requests=1 -o request_size=10000 ra
    got=$(readcrc chunk-range 1)
    [ -n "$full" ] && [ "$got" = "$full" ]
    ok=$?
    result chunk-range "chunked 10000-byte ranges read on to the end ($(hread chunk-range 1))" $ok
    # 0150 (faab9c8e56): "Content-Range: bytes A-B/*" is no size of 0 (the
    # read got nothing); its end is the 416 past it
    runh star-total "" "/range/file.ts?star=1" -direct ra
    runh star-parts "" "/range/file.ts?star=1" -direct -o multiple_requests=1 -o request_size=50000 ra
    a=$(readcrc star-total 1); b=$(readcrc star-parts 1)
    [ "$a" = "$full" ] && [ "$b" = "$full" ] && hread star-parts 1 | grep -q 'end=eof'
    ok=$?
    result star-total "a total of * reads the whole file, in one reply ($(hread star-total 1)) and in 50000-byte ones ($(hread star-parts 1))" $ok
    # 0151 (b77de7cb6f): a chunked reply after one read to its end (a seek
    # on the same context, a Plex transcode's) is read (it was taken as ended)
    runh chunk-seek "" "/range/file.ts?chunked=1" -direct -o multiple_requests=1 ra s:1000 r:1000
    got=$(readcrc chunk-seek 2)
    [ "$got" = "$at1000" ]
    ok=$?
    result chunk-seek "a chunked reply read to its end, a seek back: the next chunked reply is read ($(hread chunk-seek 2))" $ok
    # 0152 (8e9ce80c62): a reply with a Location header is checked against
    # the range asked for (a 200 from byte 0 was handed on as byte 5000's)
    runh range-checked "" "/range/file.ts?noranges=1&loc=1" -direct r:1000 s:5000 r:100
    ! grep -q '^seek 5000 ret=5000' "$OUT/range-checked.log" && grep -q 'Unexpected offset: expected 5000, got 0' "$OUT/range-checked.log"
    ok=$?
    result range-checked "a 200 with a Location to a Range from 5000: the seek fails ($(grep '^seek' "$OUT/range-checked.log"))" $ok
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
check_disp() { # 0155 (3ed7bc6580), 0156: rendition dispositions and metadata on their streams
    # the DEFAULT=YES audio rendition's codec changes in its fourth segment
    # (a new PMT: AC-3): hls copied the new stream's parameters and replaced
    # the dispositions from EXT-X-MEDIA with the subdemuxer's (none)
    run disp "" /mv/disp.m3u8 -q -maxtime 10
    at_open=$(grep '^disp 0 ' "$OUT/disp.log" | head -1)
    at_end=$(grep '^disp 0 ' "$OUT/disp.log" | tail -1)
    [ "$at_open" = "disp 0 aac default lang=en" ] && [ "$at_end" = "disp 0 ac3 default lang=en" ]
    result disp "the audio rendition's DEFAULT kept after its codec changed ($at_open; $at_end)" $?
    # 0156: a Media Playlist's two in-stream audio renditions (en DEFAULT=YES,
    # de) are its two audio streams', in order (the first took both: de,
    # default; the second none); two variants share the playlist and its
    # group (listed twice): still one stream each
    run disp-instream "" /mv2a/master.m3u8 -q -maxtime 10
    got=$(grep '^disp ' "$OUT/disp-instream.log" | head -3 | tr '\n' ';')
    [ "$got" = "disp 0 h264 none lang=-;disp 1 aac default lang=en;disp 2 aac none lang=de;" ] &&
        grep -q '^opened at .*, 3 streams' "$OUT/disp-instream.log"
    result disp-instream "in-stream renditions en (default), de on streams 1, 2 ($got)" $?
}

check_deselect() { # 0157: a playlist no longer needed is closed at once
    # RMP's order (tracks picked after avformat_find_stream_info()), v1 to v2
    # at 2.12 s, replies paced at 100 KiB/s: v1's s1, opened early with s0,
    # was read on to its end for nothing (the playlist was dropped only at
    # its next buffer refill, its inputs left open)
    run deselect "--pace 100" /mv/master.m3u8 -q -late -discard 1 -discard 3 -ev 2:off:2 -ev 2:on:3 -maxtime 15
    s1=$(grep '/mv/v1/s1.ts$' "$OUT/deselect.server.log" | grep -E '  (sent|closed after) ' | sed 's/^ *[0-9.]* *//')
    v2=$(field deselect s3)
    case "$s1" in "closed after "*) ok=0;; *) ok=1;; esac
    [ "$ok" = 0 ] && [ "$v2" = 900 ]
    result deselect "v1 dropped at the switch: its early-opened s1 closed ($s1), v2's 900 packets ($v2)" $?
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

CHECKS=${*:-b19 b20 trunc chunk_trailer sidx id3 i51 i52 bad_map vod_init init_dedup init_cut headers_origin i54 cut_body vswitch deselect disp conn_host cookies status_line bad_range crlf http_reply}
for c in $CHECKS; do "check_$(echo "$c" | tr - _)"; done
exit $FAIL
