#!/usr/bin/env python3
"""A Range-capable file server whose network goes away at the Matroska cue read
(check.sh).

usage: server.py PORT FILE [--down-at-cues SECONDS:MODE[:DELAY]]
  --down-at-cues SECONDS:MODE[:DELAY]
                 DELAY seconds (default 0) after the first request for the
                 file's Cues (a Range starting at their element), every
                 request fails for SECONDS: MODE 503 answers 503; cut sends
                 a 206's headers and closes without the body (the request
                 succeeds, the reads fail); close closes unanswered; mid
                 sends the first MID bytes (env, default 40) of the Cues
                 request and closes, then answers 503
Each request is logged as "GET START -> STATUS"; the Cues offset at the start.
"""
import os
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CUES_ID = bytes.fromhex("1c53bb6b")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        srv = self.server
        size = len(srv.body)
        start = 0
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0] or 0)
        now = time.monotonic()
        if srv.down and start == srv.cues and srv.down_since is None:
            srv.down_since = now + srv.down[2]
        down = srv.down_since is not None and 0 <= now - srv.down_since < srv.down[0]
        mode = srv.down[1] if down else None
        if mode == "mid":
            mode = "503" if srv.mid_done or start != srv.cues else "mid"
            srv.mid_done = True
        print("GET %d -> %s" % (start, mode or ("206" if rng else "200")), flush=True)
        if mode == "close":
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if mode == "503":
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            return
        if start >= size:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % size)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(206 if rng else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "video/x-matroska")
        if rng:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, size - 1, size))
        self.send_header("Content-Length", str(size - start))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if mode == "cut":
            return
        if mode == "mid":
            self.wfile.write(srv.body[start:start + srv.mid])
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        try:
            self.wfile.write(srv.body[start:])
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    port, path = int(sys.argv[1]), sys.argv[2]
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.body = open(path, "rb").read()
    srv.cues = srv.body.rfind(CUES_ID)
    srv.down, srv.down_since = None, None
    srv.mid, srv.mid_done = int(os.environ.get("MID", "40")), False
    args = sys.argv[3:]
    if args[:1] == ["--down-at-cues"]:
        seconds, mode, *delay = args[1].split(":")
        srv.down = (float(seconds), mode, float(delay[0]) if delay else 0.0)
    print("cues at %d of %d" % (srv.cues, len(srv.body)), flush=True)
    print("listening", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
