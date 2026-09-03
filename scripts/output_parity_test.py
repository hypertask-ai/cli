#!/usr/bin/env python3
import base64
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "golden"


def jwt(claims: dict) -> str:
    payload = base64.urlsafe_b64encode(
        json.dumps(claims, separators=(",", ":")).encode()
    ).decode().rstrip("=")
    return f"e30.{payload}.signature"


def fixture(name: str, replacements: dict[str, str] | None = None) -> str:
    contents = (GOLDEN / name).read_text()
    for old, new in (replacements or {}).items():
        contents = contents.replace(old, new)
    return contents


def run(
    binary: str,
    token: str,
    api_url: str,
    home: str,
    *args: str,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = home
    for name in ("HT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL"):
        env.pop(name, None)
    return subprocess.run(
        [binary, "--token", token, "--api-url", api_url, *args, "--json"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


class Handler(BaseHTTPRequestHandler):
    requests: list[dict] = []
    lock = threading.Lock()

    def do_GET(self) -> None:
        self.handle_request()

    def do_POST(self) -> None:
        self.handle_request()

    def handle_request(self) -> None:
        target = urlsplit(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length) if length else b""
        request = {
            "method": self.command,
            "path": target.path,
            "query": parse_qs(target.query, keep_blank_values=True),
            "body": json.loads(raw_body) if raw_body else None,
        }
        with self.lock:
            self.requests.append(request)

        route = (self.command, target.path)
        if route == ("GET", "/mcp/inbox/list"):
            self.respond(200, json.dumps({
                "success": True,
                "user_notifications": [{"id": 101, "type": "Mentioned"}],
                "agent_notifications": [
                    {"id": "13", "type": "Assigned"},
                    {"id": 10, "type": "Mentioned"},
                    {"id": "-35688", "type": "Synthetic"},
                    {"id": 12, "type": "Comment"},
                ],
            }, separators=(",", ":")))
            return
        if route == ("GET", "/mcp/comments"):
            overflow_case = request["query"].get("ticket_number") == ["HTPR-2"]
            maximum = 9_223_372_036_854_775_807
            self.respond(200, json.dumps({
                "success": True,
                "comments": [{"id": 1, "text": "first"}],
                "total": maximum if overflow_case else 2,
                "limit": 1,
                "offset": maximum if overflow_case else 0,
            }, separators=(",", ":")))
            return
        if route == ("GET", "/mcp/tasks"):
            if request["query"].get("ticket_number") == ["HTPR-404"]:
                self.respond(404, '{"success":false,"error":"Task not found"}')
                return
            name = "task-get.json" if "ticket_number" in request["query"] else "task-list.json"
            self.respond(200, fixture(name))
            return
        if route == ("GET", "/mcp/projects/15/labels"):
            self.respond(200, fixture("labels-list.json"))
            return
        if route == ("POST", "/mcp/tasks/create"):
            self.respond(422, fixture("task-create-error.json"))
            return
        if route == ("POST", "/mcp/comments"):
            self.respond(400, fixture("comment-add-error.json"))
            return
        if route == ("POST", "/mcp/agents/00000000-0000-0000-0000-000000000000/archive"):
            self.respond(404, fixture("agent-archive-not-found.json"))
            return
        self.respond(500, json.dumps({
            "success": False,
            "error": f"unexpected request: {self.command} {self.path}",
        }))

    def respond(self, status: int, body: str) -> None:
        encoded = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        pass


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def expect_command(
    binary: str,
    token: str,
    api_url: str,
    home: str,
    args: tuple[str, ...],
    output_fixture: str,
    exit_code: int,
    expected_request: dict | None,
) -> None:
    with Handler.lock:
        before = len(Handler.requests)
    result = run(binary, token, api_url, home, *args)
    expect(result.returncode == exit_code, (
        f"{' '.join(args)} exited {result.returncode}, expected {exit_code}\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    ))
    replacements = {
        "{{API_URL}}": api_url,
        "{{HOME}}": home,
    }
    expect(result.stdout == fixture(output_fixture, replacements), (
        f"{' '.join(args)} output differs from {output_fixture}\n"
        f"actual: {result.stdout!r}"
    ))
    expect(result.stderr == "", f"{' '.join(args)} wrote stderr: {result.stderr!r}")

    with Handler.lock:
        requests = Handler.requests[before:]
    expected_count = 0 if expected_request is None else 1
    expect(len(requests) == expected_count, (
        f"{' '.join(args)} made {len(requests)} requests, expected {expected_count}: {requests}"
    ))
    if expected_request is not None:
        expect(requests[0] == expected_request, (
            f"{' '.join(args)} request mismatch\n"
            f"actual: {requests[0]}\nexpected: {expected_request}"
        ))


def main() -> None:
    binary = str(Path(sys.argv[1]).resolve())
    token = jwt({
        "agentId": "agent-test",
        "exp": 1_788_614_666,
    })
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    api_url = f"http://127.0.0.1:{server.server_port}"

    try:
        with tempfile.TemporaryDirectory() as home:
            expect_command(
                binary, token, api_url, home,
                ("status",), "status.json", 0, None,
            )

            expect_command(
                binary, token, api_url, home,
                ("messages", "poll", "--since", "10"),
                "messages-poll.json", 0,
                {
                    "method": "GET",
                    "path": "/mcp/inbox/list",
                    "query": {},
                    "body": None,
                },
            )

            huge_expiry = run(
                binary,
                jwt({"exp": 9_223_372_036_854_775_807}),
                api_url,
                home,
                "status",
            )
            expect(huge_expiry.returncode == 0, f"huge expiry crashed: {huge_expiry.stderr}")
            expect(json.loads(huge_expiry.stdout).get("expiresAt") is None, huge_expiry.stdout)

            comments = run(binary, token, api_url, home, "comment", "list", "HTPR-1")
            expect(comments.returncode == 0, f"comment list failed: {comments.stderr}")
            expect(json.loads(comments.stdout).get("has_more") is True, comments.stdout)

            overflow_comments = run(binary, token, api_url, home, "comment", "list", "HTPR-2")
            expect(overflow_comments.returncode == 0, f"large offset crashed: {overflow_comments.stderr}")
            expect(json.loads(overflow_comments.stdout).get("has_more") is False, overflow_comments.stdout)

            missing = run(binary, token, api_url, home, "tasks", "get", "HTPR-404")
            expect(missing.returncode == 4, f"not-found exit was {missing.returncode}")
            expect(missing.stderr == "", f"error leaked to stderr: {missing.stderr!r}")
            expect(json.loads(missing.stdout)["error"] == "Task not found", missing.stdout)

            expect_command(
                binary, token, api_url, home,
                ("tasks", "get", "HTPR-5787", "--project", "15"),
                "task-get.json", 0,
                {
                    "method": "GET",
                    "path": "/mcp/tasks",
                    "query": {"ticket_number": ["HTPR-5787"]},
                    "body": None,
                },
            )
            expect_command(
                binary, token, api_url, home,
                (
                    "tasks", "list", "--project", "15", "--created-by", "6",
                    "--sort-by", "dueDate", "--sort-order", "asc", "--status", "Normal",
                    "--assigned-to", "6,agent-test", "--priority", "1,2",
                    "--has-due-date", "--limit", "2", "--offset", "3",
                ),
                "task-list.json", 0,
                {
                    "method": "GET",
                    "path": "/mcp/tasks",
                    "query": {
                        "project_id": ["15"],
                        "created_by": ["6"],
                        "sort_by": ["dueDate"],
                        "sort_order": ["asc"],
                        "status": ["Normal"],
                        "assigned_to": ["6", "agent-test"],
                        "priority": ["1", "2"],
                        "has_due_date": ["true"],
                        "limit": ["2"],
                        "offset": ["3"],
                    },
                    "body": None,
                },
            )
            expect_command(
                binary, token, api_url, home,
                ("labels", "list", "--project", "15"),
                "labels-list.json", 0,
                {
                    "method": "GET",
                    "path": "/mcp/projects/15/labels",
                    "query": {},
                    "body": None,
                },
            )
            expect_command(
                binary, token, api_url, home,
                (
                    "tasks", "create", "--project", "15", "--title", "Offline task",
                    "--description", "<p>Fixture body</p>", "--markdown", "--priority", "urgent",
                    "--estimate", "30", "--due", "2026-09-07", "--assignee", "6,7",
                ),
                "task-create-error.json", 2,
                {
                    "method": "POST",
                    "path": "/mcp/tasks/create",
                    "query": {},
                    "body": {
                        "project_id": 15,
                        "title": "Offline task",
                        "description": "<p>Fixture body</p>",
                        "content_type": "markdown",
                        "priority": 1,
                        "estimate": 30,
                        "due_date": "2026-09-07",
                        "assignee": [6, 7],
                    },
                },
            )
            expect_command(
                binary, token, api_url, home,
                (
                    "comment", "add", "HTPR-5787", "--text",
                    "<p>Offline comment</p>", "--markdown",
                ),
                "comment-add-error.json", 2,
                {
                    "method": "POST",
                    "path": "/mcp/comments",
                    "query": {},
                    "body": {
                        "ticket_number": "HTPR-5787",
                        "text": "<p>Offline comment</p>",
                        "content_type": "markdown",
                    },
                },
            )
            expect_command(
                binary, token, api_url, home,
                (
                    "agents", "archive", "--id",
                    "00000000-0000-0000-0000-000000000000",
                ),
                "agent-archive-not-found.json", 4,
                {
                    "method": "POST",
                    "path": "/mcp/agents/00000000-0000-0000-0000-000000000000/archive",
                    "query": {},
                    "body": None,
                },
            )
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    print("golden-file HTTP stub tests passed")


if __name__ == "__main__":
    main()
