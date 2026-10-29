#!/usr/bin/env python3
"""Transport retries against loopback only, without real credentials."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import shutil
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
    bodies = []
    task_reset = False

    def log_message(self, *_):
        pass

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.bodies.append(body)
        self.requests.append((self.command, self.path, self.client_address))
        mode = self.path.strip("/")
        attempt = sum(path == self.path for _, path, _ in self.requests)
        if mode == "mcp/tasks/update" and self.task_reset:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.close()
            self.close_connection = True
            return
        if mode in ("connect-success", "mcp/tasks/update"):
            self.send_response(200)
            body = b'{"ok":true}'
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            return
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
        if mode == "limited-always" or (mode == "limited-once" and attempt == 1):
            self.send_response(429)
            self.send_header("Retry-After", "1")
            body = b'{"message":"Rate limit exceeded. Please slow down and try again shortly."}'
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
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
        elif mode.startswith("bodyreset") and (mode.endswith("always") or attempt == 1):
            self.send_response(200)
            self.send_header("Content-Length", "5000")
            self.end_headers()
            self.wfile.write(b'{"items":[' + b'1,' * 50)
            self.wfile.flush()
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.close()
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
            for mode in ("eof", "reset", "partial", "bodyreset"):
                methods = ("GET", "POST", "PATCH", "DELETE") if mode == "bodyreset" else ("GET", "POST", "PUT", "PATCH", "DELETE")
                for method in methods:
                    expected_error = {"eof": "HttpConnectionClosing", "reset": "ConnectionResetByPeer",
                                      "partial": "HttpRequestTruncated", "bodyreset": "ConnectionResetByPeer"}[mode]
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
                                if mode == "bodyreset":
                                    assert "HttpTransferFailed" not in result.stderr, result.stderr
                        except AssertionError as error:
                            failures.append(f"{method} {mode}-{suffix}: {error}")
            for mode, expected_error, attempts in (("body", "HttpRequestTruncated", 2),
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
            for method, mode, attempts, succeeds in (("GET", "limited-once", 2, True),
                                                     ("GET", "limited-always", 3, False),
                                                     ("POST", "limited-always", 1, False)):
                Handler.requests = []
                args = [str(CLI), "--token", "offline-fixture", "--api-url", base,
                        "--json", "raw", method, f"/{mode}"]
                if method == "POST":
                    args.append("{}")
                result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=10)
                cases += 1
                try:
                    assert len(Handler.requests) == attempts, (Handler.requests, result.stderr)
                    if succeeds:
                        assert result.returncode == 0, result.stderr
                        assert json.loads(result.stdout) == {"ok": True}, result.stdout
                        assert "waiting 1s before retrying" in result.stderr, result.stderr
                    else:
                        assert result.returncode == 4, (result.returncode, result.stderr)
                        assert "rate limiting this login" in result.stderr, result.stderr
                        assert "could not complete the command" not in result.stderr, result.stderr
                except AssertionError as error:
                    failures.append(f"{method} {mode}: {error}")
            if sys.platform.startswith("linux"):
                strace = shutil.which("strace")
                if not strace:
                    failures.append("Linux connection injection requires strace")
                else:
                    for method in ("GET", "POST", "PUT", "PATCH", "DELETE", "TASK"):
                        for scenario in ("once", "always", "refused"):
                            Handler.requests = []
                            Handler.bodies = []
                            Handler.task_reset = False
                            trace = Path(home) / "connect.trace"
                            injected = "ECONNREFUSED" if scenario == "refused" else "ETIMEDOUT"
                            when = "1+" if scenario == "always" else "1"
                            command = [str(CLI), "--token", "offline-fixture", "--api-url", base, "--json"]
                            if method == "TASK":
                                command += ["tasks", "update", "id:123", "--title", "retry fixture"]
                            else:
                                command += ["raw", method, "/connect-success"]
                                if method in ("POST", "PUT", "PATCH"):
                                    command.append('{"fixture":true}')
                            result = subprocess.run(
                                [strace, "-e", "trace=connect", "-e", f"inject=connect:error={injected}:when={when}",
                                 "-o", str(trace), *command], env=env, capture_output=True, text=True, timeout=6,
                            )
                            cases += 1
                            try:
                                connects = [line for line in trace.read_text().splitlines() if line.startswith("connect(")]
                                assert len(connects) == (2 if scenario != "refused" else 1), connects
                                assert sum("(INJECTED)" in line for line in connects) == (2 if scenario == "always" else 1), connects
                                if scenario == "once":
                                    assert result.returncode == 0, result.stderr
                                    assert json.loads(result.stdout) == {"ok": True}, result.stdout
                                    assert len(Handler.requests) == 1, Handler.requests
                                    received_method, path, _ = Handler.requests[0]
                                    assert received_method == ("POST" if method == "TASK" else method), Handler.requests
                                    assert path == ("/mcp/tasks/update" if method == "TASK" else "/connect-success"), Handler.requests
                                    if method == "TASK":
                                        assert json.loads(Handler.bodies[0]) == {"task_id": 123, "title": "retry fixture"}, Handler.bodies
                                    elif method in ("POST", "PUT", "PATCH"):
                                        assert json.loads(Handler.bodies[0]) == {"fixture": True}, Handler.bodies
                                    else:
                                        assert Handler.bodies == [b""], Handler.bodies
                                else:
                                    assert result.returncode != 0, result.stdout
                                    assert ("ConnectionTimedOut" if scenario == "always" else "ConnectionRefused") in result.stderr, result.stderr
                                    assert not Handler.requests, Handler.requests
                            except AssertionError as error:
                                failures.append(f"{method} connect-{scenario}: {error}; stderr={result.stderr.strip()}")

                    Handler.requests = []
                    Handler.bodies = []
                    trace = Path(home) / "connect-read-retry.trace"
                    result = subprocess.run(
                        [strace, "-e", "trace=connect", "-e", "inject=connect:error=ETIMEDOUT:when=1",
                         "-o", str(trace), str(CLI), "--token", "offline-fixture", "--api-url", base,
                         "--json", "raw", "GET", "/reset-once"],
                        env=env, capture_output=True, text=True, timeout=6,
                    )
                    cases += 1
                    try:
                        connects = [line for line in trace.read_text().splitlines() if line.startswith("connect(")]
                        assert len(connects) == 3 and "(INJECTED)" in connects[0], connects
                        assert result.returncode == 0 and json.loads(result.stdout) == {"ok": True}, result.stderr
                        assert len(Handler.requests) == 2 and all(row[:2] == ("GET", "/reset-once") for row in Handler.requests), Handler.requests
                        assert Handler.bodies == [b"", b""], Handler.bodies
                    except AssertionError as error:
                        failures.append(f"GET connect-once then read retry: {error}; stderr={result.stderr.strip()}")

                    Handler.requests = []
                    Handler.bodies = []
                    Handler.task_reset = True
                    trace = Path(home) / "connect-reset.trace"
                    result = subprocess.run(
                        [strace, "-e", "trace=connect", "-e", "inject=connect:error=ETIMEDOUT:when=1",
                         "-o", str(trace), str(CLI), "--token", "offline-fixture", "--api-url", base,
                         "--json", "tasks", "update", "id:123", "--title", "retry fixture"],
                        env=env, capture_output=True, text=True, timeout=6,
                    )
                    cases += 1
                    Handler.task_reset = False
                    try:
                        connects = [line for line in trace.read_text().splitlines() if line.startswith("connect(")]
                        assert len(connects) == 2 and "(INJECTED)" in connects[0], connects
                        assert result.returncode != 0 and "ConnectionResetByPeer" in result.stderr, result.stderr
                        assert len(Handler.requests) == 1 and Handler.requests[0][:2] == ("POST", "/mcp/tasks/update"), Handler.requests
                        assert json.loads(Handler.bodies[0]) == {"task_id": 123, "title": "retry fixture"}, Handler.bodies
                    except AssertionError as error:
                        failures.append(f"TASK connect-once then reset: {error}; stderr={result.stderr.strip()}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert not failures, f"{len(failures)} of {cases} cases failed:\n" + "\n".join(failures)
    print(f"HTTP retry integration passed ({cases} cases)")


if __name__ == "__main__":
    main()
