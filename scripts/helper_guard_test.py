#!/usr/bin/env python3
"""Offline helper guard integration tests using only a loopback HTTP server."""

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out/bin/hypertask"
REFUSAL = "hypertask: helpers never write to the board; report to your runner\n"


def main():
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def respond(self):
            requests.append((self.command, self.path))
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = json.dumps({"success": True, "tasks": [], "token": "refreshed-token"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = respond

        def log_message(self, *args):
            pass

    with tempfile.TemporaryDirectory(prefix="hypertask-helper-") as directory:
        home = Path(directory)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            api = f"http://127.0.0.1:{server.server_port}/api"
            env = os.environ.copy()
            for key in ("HT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL"):
                env.pop(key, None)
            env.update(HOME=str(home), VCC_HELPER="1", VCC_HELPER_PROC_ROOT=str(home / "missing-proc"))

            def run(*args, custom_env=None, saved=False):
                flags = [] if saved else ["--token", "offline-test-token", "--api-url", api]
                return subprocess.run([str(CLI), *flags, *args], env=custom_env or env,
                                      capture_output=True, text=True, timeout=10, cwd=ROOT)

            def blocked(*args, custom_env=None):
                before = len(requests)
                result = run(*args, custom_env=custom_env)
                assert (result.returncode, result.stdout, result.stderr) == (3, "", REFUSAL), result
                assert len(requests) == before, requests

            blocked("comment", "add", "TEST-1", "--text", "blocked")
            blocked("task", "create", "--project", "15", "--title", "blocked", "--description", "bare text")
            blocked("task", "update", "TEST-1", "--description", "bare text")
            blocked("raw", "POST", "/mcp/token/refresh", "--api-url", api + "/mcp/tasks/update?x=")
            for method in ("POST", "PUT", "PATCH", "DELETE"):
                blocked("raw", method, "/mcp/tasks/update", "{}")
            blocked("raw", "POST", "/mcp/token/refresh?x=1")

            for args in (("task", "list", "--project", "15"),
                         ("search", "test", "--project", "15"),
                         ("raw", "POST", "/mcp/ai/improve", "{}"),
                         ("raw", "POST", "/mcp/ai/task-writer", "{}"),
                         ("token", "refresh")):
                before = len(requests)
                result = run(*args)
                assert result.returncode == 0, result
                assert len(requests) == before + 1, requests

            # A positive control proves the server observes unguarded writes.
            normal_env = dict(env, VCC_HELPER="0")
            before = len(requests)
            result = run("raw", "POST", "/mcp/tasks/update", "{}", custom_env=normal_env)
            assert result.returncode == 0 and len(requests) == before + 1, result

            if os.name == "posix" and Path("/proc/self/stat").exists():
                proc = home / "proc"
                parent = proc / str(os.getpid())
                ancestor_pid = os.getpid() + 1
                ancestor = proc / str(ancestor_pid)
                parent.mkdir(parents=True)
                ancestor.mkdir()
                (parent / "comm").write_text("shell (with spaces)\n")
                (parent / "stat").write_text(f"{os.getpid()} (shell (with ) spaces)) S {ancestor_pid} 0 0\n")
                (ancestor / "comm").write_text("hax\n")
                (ancestor / "stat").write_text(f"{ancestor_pid} (hax) S 1 0 0\n")
                tree_env = dict(env, VCC_HELPER="0", VCC_HELPER_PROC_ROOT=str(proc))
                for option in ("-p", "--prompt", "--print"):
                    (ancestor / "cmdline").write_bytes(f"hax\0{option}\0prompt\0".encode())
                    blocked("raw", "POST", "/mcp/tasks/update", "{}", custom_env=tree_env)
                (ancestor / "cmdline").write_bytes(b"hax\0--prompt=not-exact\0")
                before = len(requests)
                result = run("raw", "POST", "/mcp/tasks/update", "{}", custom_env=tree_env)
                assert result.returncode == 0 and len(requests) == before + 1, result

            payload = base64.urlsafe_b64encode(json.dumps({"exp": int(time.time()) + 60, "jti": "offline"}).encode()).decode().rstrip("=")
            config = home / ".hypertask"
            config.mkdir()
            (config / "config.json").write_text(json.dumps({"token": f"e30.{payload}.sig", "apiUrl": api}))
            before = len(requests)
            result = run("task", "list", "--project", "15", saved=True)
            assert result.returncode == 0, result
            assert requests[before:] == [("POST", "/api/mcp/token/refresh"),
                                         ("GET", "/api/mcp/tasks?project_id=15&limit=10&offset=0")], requests[before:]
            assert json.loads((config / "config.json").read_text())["token"] == "refreshed-token"
        finally:
            server.shutdown()
            thread.join()
            server.server_close()
    print("helper guard integration passed")


if __name__ == "__main__":
    main()
