#!/usr/bin/env python3
"""HLS fixture server for the pack's hls/http patches 0098-0106 (check.sh).

usage: server.py PORT [options]
  --stall SEQ:BYTES:MS      VOD/live segment SEQ (TS, fMP4, AES-128, ID3 audio): send
                            BYTES, sleep MS, send the rest
  --chunked                 VOD TS segments in chunked transfer encoding (4 KiB chunks);
                            with --stall the stall falls inside the chunk-size line that
                            follows BYTES
  --live-404 SEQ[,SEQ]      live: these segments answer 404
  --init-fail N[:CODE]      live fMP4: the first N init section requests answer CODE (503)
  --second-port PORT2       also listen on PORT2: a second origin for /xo/
  --long-line LEN           /long/index.m3u8 names its first segment by an absolute
                            address of LEN chars; a cut one answers 400
  --long-tag LEN            /long/index.m3u8 has an EXT-X-DATERANGE line of LEN chars
                            (an X-ASSET-URI= this demuxer does not read)
  --ipv6                    listen on ::1, not 127.0.0.1
Paths:
  /vod/index.m3u8   VOD TS, 1 s segments s0..s19
  /vodfmp4/index.m3u8  the same in fMP4, with EXT-X-MAP init.mp4
  /aes/index.m3u8   the same TS, AES-128 encrypted (setup.sh's media/aes, key.bin)
  /id3/index.m3u8   audio-only ADTS, 1 s segments a0..a9, each led by an ID3 PRIV
                    timestamp (the HLS packed audio rule); a5's alone is 100 s on
  /live/index.m3u8  live TS, window of 6, 1 s target, started when the server started
  /livefmp4/index.m3u8  live fMP4 with EXT-X-MAP init.mp4
  /vtt/subs.m3u8    VOD WebVTT segments ending in a newline, none or a blank line
  /long/index.m3u8  VOD TS with a long first segment URL
  /xo/index.m3u8    VOD TS on either port: s0 here, s2 by a redirect to the
                    other port, s1 on the other port (a new request on the
                    connection that redirect left open), s3 by a redirect to
                    the other port that redirects back here, s4 here
Every request's log line says whether it carried "X-Token" (token=yes/no),
on which port it came and on which connection (the client's port).
Every request is logged with its time since start (seconds) to stdout.
"""
import sys, time, os, threading, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# the media setup.sh generates (WORKDIR/media)
D = os.environ.get("HLS_FIXTURE_MEDIA",
                   os.path.join(os.path.dirname(os.path.abspath(__file__)), "media"))
T0 = time.monotonic()
args = sys.argv[2:]
opt = {}
i = 0
while i < len(args):
    if args[i] in ("--chunked", "--ipv6"):
        i += 1
        continue
    opt[args[i]] = args[i + 1]
    i += 2

STALL = None
if "--stall" in opt:
    s, b, ms = opt["--stall"].split(":")
    STALL = (int(s), int(b), int(ms))
LIVE404 = set(int(x) for x in opt.get("--live-404", "").split(",") if x)
INIT_FAIL = 0
INIT_CODE = 503
if "--init-fail" in opt:
    p = opt["--init-fail"].split(":")
    INIT_FAIL = int(p[0])
    if len(p) > 1:
        INIT_CODE = int(p[1])
LONG = int(opt.get("--long-line", "0"))
LONG_TAG = int(opt.get("--long-tag", "0"))
CHUNKED = "--chunked" in sys.argv
IPV6 = "--ipv6" in sys.argv
PORTS = [int(sys.argv[1])] + ([int(opt["--second-port"])] if "--second-port" in opt else [])
init_requests = 0
lock = threading.Lock()
WINDOW = 6
NSEG = 60


def log(msg):
    print("%8.3f %s" % (time.monotonic() - T0, msg), flush=True)


def vtt_segment(n):
    # 1 s segments, one cue each; X-TIMESTAMP-MAP like Plex; the files end in
    # one newline, none, or a blank line (n % 3); segment 3 starts with a BOM
    start = n * 1.0
    end = ["\n", "", "\n\n"][n % 3]
    bom = "\ufeff" if n == 3 else ""
    return (bom + "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n"
            "%02d:%02d:%06.3f --> %02d:%02d:%06.3f\ncue %d" % (
                0, int(start) // 60, start % 60, 0, int(start + 0.5) // 60,
                (start + 0.5) % 60, n) + end).encode()


def id3_timestamp(ts):
    # ID3v2.4 with one PRIV frame: Apple's transport stream timestamp, 33 bits
    # in 90 kHz units, as packed audio segments start
    owner = b"com.apple.streaming.transportStreamTimestamp\0"
    data = owner + ts.to_bytes(8, "big")

    def syncsafe(n):
        return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
    frame = b"PRIV" + syncsafe(len(data)) + b"\0\0" + data
    return b"ID3\x04\0\0" + syncsafe(len(frame)) + frame


def vod_playlist(seg, n=20, head=""):
    pl = "#EXTM3U\n#EXT-X-VERSION:%d\n#EXT-X-TARGETDURATION:1\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n" % (
        7 if head.startswith("#EXT-X-MAP") else 3)
    pl += head
    for k in range(n):
        pl += "#EXTINF:1.000000,\n" + seg % k + "\n"
    return (pl + "#EXT-X-ENDLIST\n").encode()


def live_head():
    # live edge: the segment that finished last; the window ends there
    now = time.monotonic() - T0
    last = min(int(now) + WINDOW - 1, NSEG - 1)
    return max(0, last - WINDOW + 1), last


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/octet-stream", stall=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if stall and stall[0] == 0:
            # headers only, then the stall: the segment's first read waits
            self.wfile.flush()
            log("  stall %d ms before the body" % stall[1])
            time.sleep(stall[1] / 1000.0)
            self.wfile.write(body)
        elif stall:
            b, ms = stall
            self.wfile.write(body[:b])
            self.wfile.flush()
            log("  stall %d ms after %d of %d bytes" % (ms, b, len(body)))
            time.sleep(ms / 1000.0)
            self.wfile.write(body[b:])
        else:
            self.wfile.write(body)

    def send_chunked(self, body, ctype, stall=None):
        # chunked transfer encoding; a stall after BYTES falls between the two
        # halves of the next chunk-size line
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        sent = 0
        for k in range(0, len(body), 4096):
            chunk = body[k:k + 4096]
            size = b"%X\r\n" % len(chunk)
            if stall and sent >= stall[0]:
                self.wfile.write(size[:1])
                self.wfile.flush()
                log("  stall %d ms inside the chunk-size line after %d bytes" % (stall[1], sent))
                time.sleep(stall[1] / 1000.0)
                stall = None
                size = size[1:]
            self.wfile.write(size + chunk + b"\r\n")
            sent += len(chunk)
        self.wfile.write(b"0\r\n\r\n")

    def redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        p = self.path.split("?")[0]
        port = self.server.server_address[1]
        log("GET %s port=%d token=%s conn=%d" % (p if len(p) < 200 else p[:60] + "...(%d)" % len(p),
                                                 port, "yes" if self.headers.get("X-Token") else "no",
                                                 self.client_address[1]))
        try:
            self.route(p)
        except (BrokenPipeError, ConnectionResetError):
            log("  client closed")

    def route(self, p):
        global init_requests
        mpegurl = "application/vnd.apple.mpegurl"
        if p == "/vod/index.m3u8":
            return self.send(200, vod_playlist("s%d.ts"), mpegurl)
        if p == "/vodfmp4/index.m3u8":
            return self.send(200, vod_playlist("s%d.m4s", head='#EXT-X-MAP:URI="init.mp4"\n'), mpegurl)
        if p == "/aes/index.m3u8":
            return self.send(200, vod_playlist(
                "s%d.ts", head='#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090a0b0c0d0e0f\n'),
                mpegurl)
        if p == "/id3/index.m3u8":
            return self.send(200, vod_playlist("a%d.aac", n=10), mpegurl)
        stall = None
        if STALL and p.rsplit("/", 1)[-1].split(".")[0][1:] == str(STALL[0]):
            stall = (STALL[1], STALL[2])
        if p == "/vodfmp4/init.mp4":
            return self.send(200, open(os.path.join(D, "fmp4", "init.mp4"), "rb").read(), "video/mp4")
        if p.startswith("/vodfmp4/s"):
            n = int(p[len("/vodfmp4/s"):].split(".")[0])
            return self.send(200, open(os.path.join(D, "fmp4", "s%d.m4s" % n), "rb").read(), "video/iso.segment", stall)
        if p == "/aes/key.bin":
            return self.send(200, open(os.path.join(D, "aes", "key.bin"), "rb").read())
        if p.startswith("/aes/s"):
            n = int(p[len("/aes/s"):].split(".")[0])
            return self.send(200, open(os.path.join(D, "aes", "s%d.ts" % n), "rb").read(), "video/mp2t", stall)
        if p.startswith("/id3/a"):
            n = int(p[len("/id3/a"):].split(".")[0])
            ts = 900000 + n * 90000 + (100 * 90000 if n == 5 else 0)
            body = id3_timestamp(ts) + open(os.path.join(D, "id3", "a%d.aac" % n), "rb").read()
            return self.send(200, body, "audio/aac", stall)
        if p.startswith("/xo/"):
            me = self.server.server_address[1]
            other = [x for x in PORTS if x != me][0] if len(PORTS) > 1 else me
            o = "http://%s:%d/xo/" % ("[::1]" if IPV6 else "127.0.0.1", other)
            if p == "/xo/index.m3u8":
                pl = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
                for u in ["s0.ts", "r2.ts", o + "s1.ts", "rb3.ts", "s4.ts"]:
                    pl += "#EXTINF:1.000000,\n%s\n" % u
                pl += "#EXT-X-ENDLIST\n"
                return self.send(200, pl.encode(), "application/vnd.apple.mpegurl")
            if p == "/xo/r2.ts":
                return self.redirect(o + "s2.ts")
            if p == "/xo/rb3.ts":
                return self.redirect(o + "back3.ts")
            if p == "/xo/back3.ts":
                return self.redirect(o + "s3.ts")
            n = int(p[len("/xo/s"):].split(".")[0])
            return self.send(200, open(os.path.join(D, "ts", "s%d.ts" % n), "rb").read(), "video/mp2t")
        if p == "/long/index.m3u8":
            pl = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
            # an absolute address, like a signed CDN URL: a relative one cut
            # makes ff_make_absolute_url() fail visibly
            base = "http://%s/long/" % self.headers["Host"]
            name = base + "s0.ts"
            if LONG:
                name += "?pad="
                name += "x" * (LONG - len(name))
            if LONG_TAG:
                tag = '#EXT-X-DATERANGE:ID="ad",START-DATE="2026-01-01T00:00:00Z",X-ASSET-URI="http://ads.example/?pad='
                pl += tag + "x" * (LONG_TAG - len(tag) - 1) + '"\n'
            pl += "#EXTINF:1.000000,\n%s\n" % name
            for n in range(1, 5):
                pl += "#EXTINF:1.000000,\ns%d.ts\n" % n
            pl += "#EXT-X-ENDLIST\n"
            return self.send(200, pl.encode(), "application/vnd.apple.mpegurl")
        if p == "/long/s0.ts" and LONG and len("http://%s%s" % (self.headers["Host"], self.path)) != LONG:
            # the address was cut: like a signed URL, it names nothing
            return self.send(400, b"bad request", "text/plain")
        if p.startswith("/vod/s") or p.startswith("/long/s") or p.startswith("/live/s"):
            n = int(p.rsplit("/s", 1)[1].split(".")[0])
            if p.startswith("/live/") and n in LIVE404:
                return self.send(404, b"gone", "text/plain")
            body = open(os.path.join(D, "ts", "s%d.ts" % n), "rb").read()
            if CHUNKED and p.startswith("/vod/"):
                return self.send_chunked(body, "video/mp2t", stall)
            return self.send(200, body, "video/mp2t", stall)
        if p == "/live/index.m3u8" or p == "/livefmp4/index.m3u8":
            first, last = live_head()
            fmp4 = p.startswith("/livefmp4")
            pl = "#EXTM3U\n#EXT-X-VERSION:%d\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:%d\n" % (
                7 if fmp4 else 3, first)
            if fmp4:
                pl += '#EXT-X-MAP:URI="init.mp4"\n'
            for n in range(first, last + 1):
                pl += "#EXTINF:1.000000,\ns%d.%s\n" % (n, "m4s" if fmp4 else "ts")
            if last == NSEG - 1:
                pl += "#EXT-X-ENDLIST\n"
            return self.send(200, pl.encode(), "application/vnd.apple.mpegurl")
        if p == "/livefmp4/init.mp4":
            with lock:
                init_requests += 1
                k = init_requests
            if k <= INIT_FAIL:
                return self.send(INIT_CODE, b"busy", "text/plain")
            return self.send(200, open(os.path.join(D, "fmp4", "init.mp4"), "rb").read(), "video/mp4")
        if p.startswith("/livefmp4/s"):
            n = int(p.rsplit("/s", 1)[1].split(".")[0])
            return self.send(200, open(os.path.join(D, "fmp4", "s%d.m4s" % n), "rb").read(), "video/iso.segment")
        if p == "/vtt/subs.m3u8":
            pl = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
            for n in range(5):
                pl += "#EXTINF:1.000000,\nc%d.vtt\n" % n
            pl += "#EXT-X-ENDLIST\n"
            return self.send(200, pl.encode(), "application/vnd.apple.mpegurl")
        if p.startswith("/vtt/c"):
            n = int(p[len("/vtt/c"):].split(".")[0])
            return self.send(200, vtt_segment(n), "text/vtt")
        return self.send(404, b"no", "text/plain")


ThreadingHTTPServer.daemon_threads = True
class Server6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


servers = [Server6(("::1", port), H) if IPV6 else ThreadingHTTPServer(("127.0.0.1", port), H) for port in PORTS]
for extra in servers[1:]:
    threading.Thread(target=extra.serve_forever, daemon=True).start()
log("listening")
servers[0].serve_forever()
