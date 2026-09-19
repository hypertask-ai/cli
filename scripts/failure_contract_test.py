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


class RedirectHandler(BaseHTTPRequestHandler):
    destination_port = 0
    requests: list[tuple[int, str, str | None]] = []

    def do_GET(self) -> None:
        self.requests.append((self.server.server_port, self.path, self.headers.get("Authorization")))
        if self.path == "/mcp/same-origin":
            self.redirect("/mcp/final")
        elif self.path == "/mcp/cross-port":
            self.redirect(f"http://127.0.0.1:{self.destination_port}/mcp/final")
        elif self.path == "/mcp/cross-host":
            self.redirect(f"http://localhost:{self.destination_port}/mcp/final")
        else:
            encoded = json.dumps({"ok": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    def redirect(self, location: str) -> None:
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:
        pass


class StubHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.startswith("/mcp/projects"):
            self.respond(200, {"projects": []})
        elif self.path.startswith("/mcp/comments"):
            self.respond(200, {"success": False, "error": "comment read did not run"})
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
        run("ai", "write", "text", "--project", "15", "--mode", "unexpected"),
        2,
        "valid modes: task-writer, write-with-ai",
    )
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

        manual_fetch_failure = run("comment", "list", "HTPR-1", api_url=api_url)
        assert_failure(manual_fetch_failure, 4, "comment read did not run")

        with_labels = run(
            "task", "create", "--project", "5156", "--title", "x", "--labels", "Infra",
            api_url=api_url,
        )
        assert_failure(with_labels, 4, "this token is not a member of project 5156", "ask the project owner to add it")
        assert "LabelNotFound" not in with_labels.stderr

        without_labels = run(
            "task", "create", "--project", "5156", "--title", "x",
            api_url=api_url,
        )
        assert_failure(without_labels, 4, "this token is not a member of project 5156", "ask the project owner to add it")
        assert "Internal server error" not in without_labels.stdout + without_labels.stderr
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    destination = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
    origin = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
    RedirectHandler.destination_port = destination.server_port
    destination_thread = threading.Thread(target=destination.serve_forever, daemon=True)
    origin_thread = threading.Thread(target=origin.serve_forever, daemon=True)
    destination_thread.start()
    origin_thread.start()
    redirect_api_url = f"http://127.0.0.1:{origin.server_port}"
    try:
        RedirectHandler.requests.clear()
        same_origin = run("raw", "GET", "/mcp/same-origin", api_url=redirect_api_url)
        assert same_origin.returncode == 0, same_origin.stderr
        assert RedirectHandler.requests == [
            (origin.server_port, "/mcp/same-origin", "Bearer test-token"),
            (origin.server_port, "/mcp/final", "Bearer test-token"),
        ]

        RedirectHandler.requests.clear()
        cross_port = run("raw", "GET", "/mcp/cross-port", api_url=redirect_api_url)
        assert cross_port.returncode == 0, cross_port.stderr
        assert RedirectHandler.requests == [
            (origin.server_port, "/mcp/cross-port", "Bearer test-token"),
            (destination.server_port, "/mcp/final", None),
        ]

        RedirectHandler.requests.clear()
        cross_host = run("raw", "GET", "/mcp/cross-host", api_url=redirect_api_url)
        assert cross_host.returncode == 0, cross_host.stderr
        assert RedirectHandler.requests == [
            (origin.server_port, "/mcp/cross-host", "Bearer test-token"),
            (destination.server_port, "/mcp/final", None),
        ]
    finally:
        origin.shutdown()
        origin.server_close()
        origin_thread.join()
        destination.shutdown()
        destination.server_close()
        destination_thread.join()

    print("failure contract checks passed")


if __name__ == "__main__":
    main()
