#!/usr/bin/env python3
"""Exercise large task pages against fragmented local HTTP responses."""

import argparse
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit
import zlib


rng = random.Random(7024)
words = "pagination task review description résumé buffer HTTP JSON safe response".split()
PAGE = json.dumps({
    "success": True,
    "tasks": [{
        "id": index,
        "projectId": 339,
        "title": f"Fixture task {index}",
        "description": "<p>" + " ".join(rng.choices(words, k=500)) + "</p>",
        "assignees": [],
        "labels": [],
    } for index in range(201, 301)],
    "total": 431,
    "offset": 200,
    "limit": 100,
}, ensure_ascii=False).encode()


def compressed(wbits: int, strategy: int) -> bytes:
    compressor = zlib.compressobj(wbits=wbits, strategy=strategy)
    return compressor.compress(PAGE) + compressor.flush()


RESPONSES = {
    "identity": (None, PAGE),
    "gzip": ("gzip", gzip.compress(PAGE, mtime=0)),
    "gzip-fixed": ("gzip", compressed(31, zlib.Z_FIXED)),
    "deflate": ("deflate", compressed(15, zlib.Z_DEFAULT_STRATEGY)),
    "deflate-fixed": ("deflate", compressed(15, zlib.Z_FIXED)),
    "gzip-stored": ("gzip", gzip.compress(PAGE, compresslevel=0, mtime=0)),
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        target = urlsplit(self.path)
        mode, framing, _, _ = target.path.strip("/").split("/")
        query = parse_qs(target.query)
        if query != {"project_id": ["339"], "limit": ["100"], "offset": ["200"]}:
            self.send_error(400)
            return
        encoding, body = RESPONSES[mode]
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        if encoding:
            self.send_header("Content-Encoding", encoding)
        if framing == "chunked":
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            for offset in range(0, len(body), 1024):
                part = body[offset:offset + 1024]
                if framing == "chunked":
                    part = f"{len(part):x}\r\n".encode() + part + b"\r\n"
                # Split even chunk headers and briefly delay the initial reads.
                self.wfile.write(part[:3])
                self.wfile.flush()
                if offset < 4096:
                    time.sleep(0.001)
                self.wfile.write(part[3:])
                self.wfile.flush()
            if framing == "chunked":
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_: object) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--runs", type=int, default=1)
    options = parser.parse_args()
    if options.runs < 1:
        parser.error("--runs must be positive")
    binary = str(Path(options.binary).resolve())
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    count = 0
    try:
        with tempfile.TemporaryDirectory() as home:
            env = {"PATH": os.defpath, "HOME": home, "USERPROFILE": home,
                   "XDG_CONFIG_HOME": home, "XDG_CACHE_HOME": home}
            for _ in range(options.runs):
                for mode in RESPONSES:
                    for framing in ("length", "chunked"):
                        result = subprocess.run(
                            [binary, "--token", "offline-fixture", "--api-url",
                             f"http://127.0.0.1:{server.server_port}/{mode}/{framing}",
                             "--json", "tasks", "list", "--project", "339",
                             "--limit", "100", "--offset", "200"],
                            env=env, capture_output=True, timeout=20,
                        )
                        if result.returncode != 0 or result.stderr:
                            panic = b"panic:" in result.stderr
                            raise AssertionError(
                                f"{mode}/{framing}: exit={result.returncode}, "
                                f"stdout_bytes={len(result.stdout)}, safety_panic={panic}"
                            )
                        assert result.stdout == PAGE + b"\n", f"{mode}/{framing}: changed JSON"
                        assert json.loads(result.stdout) == json.loads(PAGE)
                        count += 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print(f"paged task list HTTP tests passed ({count} commands)")


if __name__ == "__main__":
    main()
