#!/usr/bin/env python3
"""Error telemetry contracts against loopback only, without real credentials."""
import json
import os
import re
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLI = Path(sys.argv[1]).resolve()
PRIVATE = "FAKE PRIVATE TICKET TITLE"
REPORT = "/mcp/cli-error"


class Handler(BaseHTTPRequestHandler):
    status = 503
    body = '{"success":false,"error":"fixture failure"}'
    report_mode = "ok"
    drop_command = False
    requests = []
    release = threading.Event()

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.requests.append((self.command, self.path, raw, self.headers.get("Authorization")))
        if self.path == REPORT:
            if self.report_mode == "stall":
                self.release.wait(5)
            if self.report_mode == "drop":
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            if self.report_mode == "redirect":
                self.send_response(307)
                self.send_header("Location", "/must-not-retry")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status, body = (500, "report failed") if self.report_mode == "fail" else (204, "")
        else:
            if self.drop_command:
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            status, body = self.status, self.body
        encoded = body.encode()
        try:
            self.send_response(status)
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    cases = 0
    try:
        with tempfile.TemporaryDirectory(prefix="hypertask-reports-") as directory:
            home = Path(directory)
            cfg = home / ".hypertask" / "config.json"
            env = os.environ.copy()
            for name in ("HT_TOKEN", "HT_AGENT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL", "HYPERTASK_NO_ERROR_REPORTS"):
                env.pop(name, None)
            env.update(HOME=str(home), VCC_HELPER="0", VCC_HELPER_PROC_ROOT=str(home / "no-proc"))
            base = f"http://127.0.0.1:{server.server_port}"
            default_args = ("task", "create", "--project", "12345", "--title", PRIVATE)

            def run(*args, opt_out=None, token="test-token", helper=False):
                nonlocal cases
                cases += 1
                Handler.requests = []
                current = env.copy()
                if opt_out is not None:
                    current["HYPERTASK_NO_ERROR_REPORTS"] = opt_out
                if helper:
                    current["VCC_HELPER"] = "1"
                command = [str(CLI), "--api-url", base]
                if token is not None:
                    command += ["--token", token]
                command += list(args or default_args)
                start = time.monotonic()
                result = subprocess.run(command, env=current, capture_output=True, text=True, timeout=6)
                elapsed = time.monotonic() - start
                reports = [entry for entry in Handler.requests if entry[1] == REPORT]
                return result, reports, elapsed

            baseline, reports, _ = run(opt_out="1")
            assert baseline.returncode == 4 and not reports
            for value in (None, "", "0"):
                result, reports, _ = run(opt_out=value)
                assert (result.returncode, result.stdout, result.stderr) == (baseline.returncode, baseline.stdout, baseline.stderr)
                assert len(reports) == 1, reports
                assert PRIVATE in Handler.requests[0][2].decode()  # positive privacy control
                method, path, raw, authorization = reports[0]
                body = json.loads(raw)
                assert method == "POST" and path == REPORT and authorization == "Bearer test-token"
                assert set(body) == {"command", "error", "status", "version", "os"}
                assert body["command"] == "task create" and body["error"] == "ApiFailure" and body["status"] == 503
                assert body["os"] == "linux" and re.fullmatch(r"\d+\.\d+\.\d+", body["version"]), body  # app schema: bare semver
                assert all(value not in raw.decode() for value in (PRIVATE, "12345", "test-token"))
            for value in ("1", "true", "false", "anything"):
                result, reports, _ = run(opt_out=value)
                assert not reports and result.returncode == 4
            for status in (400, 401, 403, 404, 409, 422, 429):
                Handler.status = status
                result, reports, _ = run()
                assert not reports and result.returncode != 0, (status, reports)
            Handler.status = 200
            result, reports, _ = run()
            assert result.returncode != 0 and not reports  # logical input rejection
            Handler.body = "not JSON"
            result, reports, _ = run()
            assert result.returncode != 0 and len(reports) == 1
            assert json.loads(reports[0][2])["error"] == "SyntaxError"
            Handler.drop_command = True
            result, reports, _ = run("raw", "GET", "/fixture-private-path")
            assert result.returncode != 0 and len(reports) == 1
            network_payload = json.loads(reports[0][2])
            assert "status" not in network_payload and network_payload["command"] == "raw"
            Handler.drop_command = False
            Handler.status, Handler.body = 503, '{"success":false,"error":"fixture failure"}'
            for mode in ("fail", "drop", "redirect", "stall"):
                Handler.report_mode = mode
                result, reports, elapsed = run()
                assert (result.returncode, result.stdout, result.stderr) == (baseline.returncode, baseline.stdout, baseline.stderr)
                assert len(reports) == 1 and len(Handler.requests) == 2, Handler.requests
                assert elapsed < 1.9, elapsed
                if mode == "stall":
                    assert elapsed >= 1.4, elapsed
                    Handler.release.set()
            Handler.report_mode = "ok"
            result, reports, _ = run("feedback", PRIVATE)
            assert result.returncode != 0 and not reports
            result, reports, _ = run(token=None)
            assert result.returncode == 2 and not reports and not Handler.requests
            for args in (("task", "create", "--project", "bad", "--title", PRIVATE), ("unknown-private-command",), ("fields", "create", "--project", "1", "--name", "test", "--options", "not JSON")):
                result, reports, _ = run(*args)
                assert result.returncode != 0 and not reports and not Handler.requests
            result, reports, _ = run("raw", "GET", "/fixture", helper=True)
            assert result.returncode == 4 and not reports
            Handler.requests = []
            read_end, write_end = os.pipe()
            os.close(read_end)
            try:
                broken_pipe = subprocess.run([str(CLI), "--token", "test-token", "--api-url", base, "raw", "GET", "/fixture"], env=env, stdout=write_end, stderr=subprocess.PIPE, text=True, timeout=6)
                cases += 1
                assert broken_pipe.returncode == 141 and not broken_pipe.stderr
                assert len(Handler.requests) == 1 and Handler.requests[0][1] != REPORT
            finally:
                os.close(write_end)
            cfg.parent.mkdir()
            cfg.write_text(json.dumps({"token": "saved-test-token", "apiUrl": base, "error_reports": False}))
            result, reports, _ = run(token=None)
            assert result.returncode == 4 and not reports
            result, reports, _ = run("login", token="replacement-test-token")
            assert result.returncode == 0 and not reports
            assert json.loads(cfg.read_text())["error_reports"] is False
            result, reports, _ = run(token=None, opt_out="0")
            assert result.returncode == 4 and not reports
            help_result, _, _ = run("--help")
            assert "command name and error type only, no task content" in help_result.stdout
            assert "HYPERTASK_NO_ERROR_REPORTS=1" in help_result.stdout and "error_reports=false" in help_result.stdout
            # A TLS handshake stalls before an HTTP response exists. The deadline
            # must cover connection setup as well as the response tested above.
            class TLSHandler(socketserver.BaseRequestHandler):
                connections = 0
                lock = threading.Lock()
                stalled = threading.Event()
                release = threading.Event()

                def handle(self):
                    with self.lock:
                        type(self).connections += 1
                        number = type(self).connections
                    self.request.recv(4096)
                    if number == 1:
                        self.request.sendall(b"HTTP/1.1 503 Not TLS\r\n\r\n")
                    else:
                        self.stalled.set()
                        self.release.wait(5)

            class TLSServer(socketserver.ThreadingTCPServer):
                daemon_threads = True

            tls_server = TLSServer(("127.0.0.1", 0), TLSHandler)
            tls_thread = threading.Thread(target=tls_server.serve_forever, daemon=True)
            tls_thread.start()
            try:
                # Use an explicit token and no persisted opt-out for these runs.
                cfg.unlink()
                command = [str(CLI), "--token", "test-token", "--api-url", f"https://127.0.0.1:{tls_server.server_address[1]}", "raw", "GET", "/fixture"]
                baseline_env = env.copy()
                baseline_env["HYPERTASK_NO_ERROR_REPORTS"] = "1"
                tls_baseline = subprocess.run(command, env=baseline_env, capture_output=True, text=True, timeout=6)
                assert tls_baseline.returncode != 0 and TLSHandler.connections == 1
                TLSHandler.connections = 0
                start = time.monotonic()
                tls_result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=6)
                elapsed = time.monotonic() - start
                cases += 2
                assert TLSHandler.stalled.wait(1) and TLSHandler.connections == 2
                assert 1.4 <= elapsed < 1.9, elapsed
                assert (tls_result.returncode, tls_result.stdout, tls_result.stderr) == (tls_baseline.returncode, tls_baseline.stdout, tls_baseline.stderr)
            finally:
                TLSHandler.release.set()
                tls_server.shutdown()
                tls_server.server_close()
                tls_thread.join()
            print(f"CLI error report integration passed ({cases} cases)")
    finally:
        Handler.release.set()
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
