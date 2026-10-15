#!/usr/bin/env python3
"""Pre-head transport retries against loopback only, without real credentials."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading


CLI = Path(sys.argv[1]).resolve()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = []

    def log_message(self, *_):
        pass

    def handle_request(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.requests.append((self.command, self.path, self.client_address))
        mode = self.path.strip("/")
        attempt = sum(path == self.path for _, path, _ in self.requests)
        if mode == "continue":
            self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            return
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "/eof-once")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if mode == "status":
            self.send_response(503)
        elif mode == "body":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.wfile.write(b"{")
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
            self.close_connection = True
            return
        elif mode.endswith("always") or attempt == 1:
            self.close_connection = True
            if mode.startswith("reset"):
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                self.connection.close()
            else:
                if mode.startswith("partial"):
                    self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length:")
                    self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
            return
        else:
            self.send_response(200)
        body = b'{"ok":true}'
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_request


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    cases = 0
    failures = []
    try:
        with tempfile.TemporaryDirectory(prefix="hypertask-http-retry-") as home:
            env = {"PATH": os.defpath, "HOME": home, "USERPROFILE": home,
                   "XDG_CONFIG_HOME": home, "XDG_CACHE_HOME": home,
                   "HYPERTASK_NO_ERROR_REPORTS": "1", "VCC_HELPER": "0",
                   "VCC_HELPER_PROC_ROOT": str(Path(home) / "no-proc")}
            base = f"http://127.0.0.1:{server.server_port}"
            for mode in ("eof", "reset", "partial"):
                for method in ("GET", "POST", "PUT", "PATCH", "DELETE"):
                    expected_error = {"eof": "HttpConnectionClosing", "reset": "ConnectionResetByPeer",
                                      "partial": "HttpRequestTruncated"}[mode]
                    for suffix in ("once", "always"):
                        Handler.requests = []
                        args = [str(CLI), "--token", "offline-fixture", "--api-url", base,
                                "--json", "raw", method, f"/{mode}-{suffix}"]
                        if method in ("POST", "PUT", "PATCH"):
                            args.append("{}")
                        result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=6)
                        cases += 1
                        try:
                            expected_attempts = 2 if method == "GET" else 1
                            assert len(Handler.requests) == expected_attempts, (Handler.requests, result.stderr)
                            assert len({peer for _, _, peer in Handler.requests}) == expected_attempts, Handler.requests
                            if method == "GET" and suffix == "once":
                                assert result.returncode == 0 and not result.stderr, result.stderr
                                assert json.loads(result.stdout) == {"ok": True}, result.stdout
                            else:
                                assert result.returncode != 0, result.stdout
                                assert expected_error in result.stderr, result.stderr
                                assert "ReadFailed" not in result.stderr, result.stderr
                        except AssertionError as error:
                            failures.append(f"{method} {mode}-{suffix}: {error}")
            for mode, expected_error, attempts in (("body", "HttpRequestTruncated", 1),
                                                   ("continue", "HttpConnectionClosing", 1),
                                                   ("status", "the server could not complete the command", 1),
                                                   ("redirect", "HttpConnectionClosing", 2)):
                Handler.requests = []
                result = subprocess.run(
                    [str(CLI), "--token", "offline-fixture", "--api-url", base,
                     "--json", "raw", "GET", f"/{mode}"],
                    env=env, capture_output=True, text=True, timeout=6,
                )
                cases += 1
                try:
                    assert result.returncode != 0, result.stdout
                    assert expected_error in result.stderr, result.stderr
                    assert len(Handler.requests) == attempts, Handler.requests
                except AssertionError as error:
                    failures.append(f"GET {mode}: {error}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert not failures, "\n".join(failures)
    print(f"HTTP retry integration passed ({cases} cases)")


if __name__ == "__main__":
    main()
