#!/usr/bin/env python3
"""Process-level checks for actionable CLI failures."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CLI = Path(sys.argv[1]).resolve()


def run(*args: str, api_url: str | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    with tempfile.TemporaryDirectory() as home:
        env["HOME"] = home
        env.pop("HT_AGENT_TOKEN", None)
        env.pop("HT_TOKEN", None)
        env.pop("HYPERTASKS_JWT_TOKEN", None)
        command = [str(CLI), "--token", "test-token"]
        if api_url:
            command.extend(("--api-url", api_url))
        command.extend(args)
        return subprocess.run(command, text=True, capture_output=True, env=env, check=False)


def assert_failure(process: subprocess.CompletedProcess[str], expected_code: int, *messages: str) -> None:
    output = process.stdout + process.stderr
    assert process.returncode == expected_code, (process.returncode, output)
    assert "Next:" in process.stderr, process.stderr
    for message in messages:
        assert message in output, (message, output)


class StubHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.startswith("/mcp/projects"):
            self.respond(200, {"projects": []})
        elif self.path.startswith("/mcp/tasks"):
            self.respond(200, {"success": False, "error": "task read did not run"})
        else:
            self.respond(500, {"success": False, "error": "server broke"})

    def do_POST(self) -> None:
        self.respond(500, {"success": False, "error": "Internal server error", "message": "Forbidden"})

    def respond(self, status: int, body: dict[str, object]) -> None:
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    assert_failure(run("not-a-command"), 1, "valid commands:")
    assert_failure(run("task"), 2, "valid commands:")
    assert_failure(run("status", "ignored"), 2, "unexpected argument: ignored", "accepted arguments: (none)")
    assert_failure(run("pages", "create"), 2, "required option: --task")
    assert_failure(run("raw", "CONNECT", "/mcp/tasks"), 2, "valid methods: GET, POST, PUT, PATCH, DELETE")
    assert_failure(run("ai", "improve", "text", "--project", "15", "--command", "summarise"), 2, "valid improve commands:")
    assert_failure(
        run("task", "assign", "HTPR-1", "--self", "--assignee", "1"),
        2,
        "use either --self or --assignee",
    )
    assert_failure(
        run("task", "get", "HTPR-1", "--not-a-flag", "1"),
        2,
        "unknown option: --not-a-flag",
        "accepted flags:",
    )

    server = ThreadingHTTPServer(("127.0.0.1", 0), StubHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    api_url = f"http://127.0.0.1:{server.server_port}"
    try:
        success_false = run("task", "get", "HTPR-1", api_url=api_url)
        assert_failure(success_false, 4, "task read did not run")

        with_labels = run(
            "task", "create", "--project", "5156", "--title", "x", "--labels", "Infra",
            api_url=api_url,
        )
        assert_failure(with_labels, 4, "cannot access project 5156", "ask the project owner")
        assert "LabelNotFound" not in with_labels.stderr

        without_labels = run(
            "task", "create", "--project", "5156", "--title", "x",
            api_url=api_url,
        )
        assert_failure(without_labels, 4, "cannot access project 5156", "ask the project owner")
        assert "Internal server error" not in without_labels.stdout + without_labels.stderr
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    print("failure contract checks passed")


if __name__ == "__main__":
    main()
