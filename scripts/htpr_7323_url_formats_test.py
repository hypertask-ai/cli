#!/usr/bin/env python3
"""HTPR-7323: offline URL discovery and loopback-only context contract checks."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

ROOT = Path(__file__).resolve().parents[1]
# Copied from HELLO_URL_FORMATS in the app's src/lib/mcp/hello/getHelloPayload.ts.
EXPECTED_URL_FORMATS = {
    "ticket": "https://app.hypertask.ai/detail/project-{boardId}/{taskNumber}",
    "comment": "https://app.hypertask.ai/detail/project-{boardId}/{taskNumber}#comment-{commentId}",
    "board": "https://app.hypertask.ai/project?id={boardId}",
    "boardView": "https://app.hypertask.ai/project?id={boardId}&view={viewSlug}",
    "inboxSplit": "https://app.hypertask.ai/inbox?split={splitName}&projectId={boardId}",
    "page": "https://app.hypertask.ai/page/{pagePublicId}",
    "rules": "taskNumber is the number after the ticket prefix (HTPR-7321 is 7321) on the board the task is on now, never the global task id. boardId is the numeric board id. Prefer the url or link field a tool returns over building one.",
}
CONTEXT_PATH = "/mcp/user/context"
PROJECTS_PATH = "/mcp/projects?status=Normal&limit=100"
USER_CONTEXT = {
    "user": {"id": 42, "name": "Test user"},
    "teams": [{"id": 3, "name": "Test team"}],
    "projects": [{"id": 1, "title": "Old project list"}],
    "unknown": {"nested": [1, False, None, "preserved"]},
}
PROJECTS = [{"id": 15, "title": "Current board", "extra": "preserved"}]


class Handler(BaseHTTPRequestHandler):
    requests = []
    responses = {}

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.requests.append(("GET", self.path))
        status, response = self.responses.get(self.path, (404, {"error": "Unexpected request"}))
        raw = json.dumps(response).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        self.requests.append(("POST", self.path))
        self.send_error(405)


def main():
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out/bin/hypertask"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    passed = 0
    try:
        with tempfile.TemporaryDirectory(prefix="hypertask-url-formats-") as home:
            env = {
                "PATH": os.environ.get("PATH", ""), "HOME": home,
                "HYPERTASKS_API_URL": f"http://127.0.0.1:{server.server_port}",
                "HYPERTASK_NO_ERROR_REPORTS": "1",
                "VCC_HELPER": "0", "VCC_HELPER_PROC_ROOT": str(Path(home) / "no-proc"),
            }

            def run(*args):
                return subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=30)

            for command in ("capabilities", "commands"):
                result = run(command, "--json")
                assert result.returncode == 0, result.stderr
                catalog = json.loads(result.stdout)
                assert catalog["urlFormats"] == EXPECTED_URL_FORMATS, catalog.get("urlFormats")
                assert catalog["commands"], catalog
                assert Handler.requests == [], Handler.requests
                passed += 1

                for flags in ((), ("--human",)):
                    result = run(command, *flags)
                    assert result.returncode == 0, result.stderr
                    assert "## URL formats" in result.stdout, result.stdout
                    for value in EXPECTED_URL_FORMATS.values():
                        assert value in result.stdout, value
                    assert "## Commands" in result.stdout and "`task get`" in result.stdout, result.stdout
                    assert Handler.requests == [], Handler.requests
                    passed += 1

            expected_requests = [("GET", CONTEXT_PATH), ("GET", PROJECTS_PATH)]
            for flags in ((), ("--json",)):
                Handler.requests = []
                Handler.responses = {
                    CONTEXT_PATH: (200, USER_CONTEXT),
                    PROJECTS_PATH: (200, {"projects": PROJECTS}),
                }
                result = run("--token", "test-token", "context", *flags)
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout) == {
                    **USER_CONTEXT, "projects": PROJECTS, "urlFormats": EXPECTED_URL_FORMATS,
                }, result.stdout
                assert Handler.requests == expected_requests, Handler.requests
                passed += 1

            for failed_path in (CONTEXT_PATH, PROJECTS_PATH):
                for status in (403, 200):
                    Handler.requests = []
                    Handler.responses = {
                        CONTEXT_PATH: (200, USER_CONTEXT),
                        PROJECTS_PATH: (200, {"projects": PROJECTS}),
                        failed_path: (status, {"success": False, "error": "Context access denied"}),
                    }
                    result = run("--token", "test-token", "context", "--json")
                    assert result.returncode == 4, (result.returncode, result.stderr)
                    assert "Context access denied" in result.stdout + result.stderr, result
                    assert "urlFormats" not in result.stdout, result.stdout
                    assert Handler.requests == expected_requests[:1 if failed_path == CONTEXT_PATH else 2], Handler.requests
                    passed += 1

            Handler.requests = []
            Handler.responses = {CONTEXT_PATH: (200, USER_CONTEXT), PROJECTS_PATH: (200, {})}
            result = run("--token", "test-token", "context", "--json")
            assert result.returncode != 0, result
            assert "urlFormats" not in result.stdout, result.stdout
            assert Handler.requests == expected_requests, Handler.requests
            passed += 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print(f"URL format tests passed: {passed} passed, 0 failed")


if __name__ == "__main__":
    main()
