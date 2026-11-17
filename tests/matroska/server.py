#!/usr/bin/env python3
"""A Range-capable file server whose network goes away at the Matroska cue read
(check.sh).

usage: server.py PORT FILE [--down-at-cues SECONDS:MODE]
  --down-at-cues SECONDS:MODE  from the first request for the file's Cues on
                               (a Range starting at their element), every
                               request fails for SECONDS: MODE 503 answers
                               503; cut sends a 206's headers and closes
                               without the body (the request succeeds, the
                               reads fail); close closes unanswered
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
            srv.down_since = now
        down = srv.down_since is not None and now - srv.down_since < srv.down[0]
        mode = srv.down[1] if down else None
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
    args = sys.argv[3:]
    if args[:1] == ["--down-at-cues"]:
        seconds, mode = args[1].split(":")
        srv.down = (float(seconds), mode)
    print("cues at %d of %d" % (srv.cues, len(srv.body)), flush=True)
    print("listening", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
