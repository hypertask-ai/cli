#!/usr/bin/env python3
import base64
import json
import os
import socket
import struct
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
    strip_identity: bool = False,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = home
    # These writes target only the loopback fixture, not a Hypertask board.
    env.update(VCC_HELPER="0", VCC_HELPER_PROC_ROOT=str(Path(home) / "no-proc"))
    names = ["HT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL"]
    if strip_identity:
        # HTPR-6313: agent identity must come only from the caller so the
        # error path is deterministic regardless of the invoking shell.
        names += ["HT_AGENT_SLUG", "HT_AGENT_ID", "HT_AGENT_STATE_DIR",
                  "HT_CAPABILITY_AGENT_SLUG", "HT_CAPABILITY_TICKET", "HT_CAPABILITY_EXPIRES_AT"]
    for name in names:
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
    login_status = 200
    login_body = json.dumps({
        "success": True,
        "user": {"displayName": "Maria Lopez", "email": "m@example.com"},
        "agent": {"id": "agent-1", "displayName": "Claude Code"},
        "boards": [{"id": 9142, "title": "Product Launch", "boardUrl": "https://app.hypertask.ai/project?id=9142"}],
        "boardsTotal": 1,
    })
    login_authorization = None

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
            "accept_encoding": self.headers.get("Accept-Encoding"),
        }
        with self.lock:
            self.requests.append(request)

        route = (self.command, target.path)
        if route == ("GET", "/mcp/hello"):
            Handler.login_authorization = self.headers.get("Authorization")
            self.respond(Handler.login_status, Handler.login_body)
            return
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
        if route == ("GET", "/mcp/tasks/search"):
            name = "search-projected.json" if request["query"].get("fields") == ["title"] else "search-empty.json"
            self.respond(200, fixture(name))
            return
        if route == ("GET", "/mcp/tasks"):
            if request["query"].get("ticket_number") == ["HTPR-404"]:
                self.respond(404, '{"success":false,"error":"Task not found"}')
                return
            name = "task-get.json" if "ticket_number" in request["query"] else "task-list.json"
            self.respond(200, fixture(name))
            return
        if route == ("POST", "/mcp/tasks/move"):
            self.respond(200, '{"success":true,"task":{"id":49511,"projectId":339}}')
            return
        if route == ("POST", "/mcp/tasks/waiting-on"):
            self.respond(200, '{"success":true}')
            return
        if route == ("POST", "/mcp/assignees/assign"):
            self.respond(200, fixture("task-assign-self.json"))
            return
        if route == ("GET", "/mcp/projects/15/sections"):
            self.respond(200, json.dumps({
                "sections": [
                    {"id": 1, "section_title": "Bugs"},
                    {"id": 2, "section_title": "In Progress"},
                    {"id": 3, "section_title": "Done"},
                ],
            }, separators=(",", ":")))
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
        if route == ("POST", "/mcp/comments/216402/reactions"):
            self.respond(200, fixture("comment-react.json"))
            return
        if route == ("POST", "/mcp/comments/404/reactions"):
            self.respond(404, fixture("comment-reaction-not-found.json"))
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


class PaginationHandler(BaseHTTPRequestHandler):
    pages = {
        "0": json.dumps({
            "success": True,
            "tasks": [{"id": i, "description": "<p>Large page résumé</p>" * 200} for i in range(100)],
            "total": 100,
        }).encode(),
        "100": b"",
        "200": b" \r\n\t",
        "300": b'{"success":true,"tasks":[',
        "400": b'{"success":true,"tasks":[],"total":100}',
    }

    def do_GET(self) -> None:
        offset = parse_qs(urlsplit(self.path).query)["offset"][0]
        body = self.pages[offset]
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


class TransportFailureHandler(BaseHTTPRequestHandler):
    """Sends malformed transport responses: a body shorter than the declared
    Content-Length, either closed cleanly (truncation) or reset mid-body."""

    def do_GET(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        if length:
            self.rfile.read(length)
        body = b'{"success":true,"tasks":[{"id":1}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body) * 2))
        self.end_headers()
        self.wfile.write(body[: len(body) // 2])
        if urlsplit(self.path).path.endswith("/reset"):
            self.connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
            )
        self.close_connection = True

    def log_message(self, format: str, *args: object) -> None:
        pass


def expect_transport_failure(
    binary: str,
    token: str,
    api_url: str,
    home: str,
    suffix: str,
    expected_errors: tuple[str, ...],
) -> None:
    # A mid-body reset races against the truncation check: depending on how
    # much the client already read before the RST lands, either error is a
    # correct "clean failure, no crash" outcome.
    result = run(binary, token, api_url + suffix, home, "tasks", "list", "--project", "15")
    expect(result.returncode == 1, (
        f"{suffix} exited {result.returncode}, expected clean error 1\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    ))
    expect(any(err in result.stderr for err in expected_errors), (
        f"{suffix} stderr missing one of {expected_errors}: {result.stderr!r}"
    ))
    expect(result.stdout == "", f"{suffix} leaked partial stdout: {result.stdout!r}")


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
    if exit_code == 0:
        expect(result.stderr == "", f"{' '.join(args)} wrote stderr: {result.stderr!r}")
    else:
        expect("Next:" in result.stderr, f"{' '.join(args)} omitted next-step guidance: {result.stderr!r}")

    with Handler.lock:
        requests = Handler.requests[before:]
    expected_count = 0 if expected_request is None else 1
    expect(len(requests) == expected_count, (
        f"{' '.join(args)} made {len(requests)} requests, expected {expected_count}: {requests}"
    ))
    if expected_request is not None:
        actual_request = dict(requests[0])
        expect(actual_request.pop("accept_encoding") == "identity", (
            f"{' '.join(args)} requested response compression: {requests[0]}"
        ))
        expect(actual_request == expected_request, (
            f"{' '.join(args)} request mismatch\n"
            f"actual: {actual_request}\nexpected: {expected_request}"
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
                ("login",), "login-guidance.json", 0,
                {"method": "GET", "path": "/mcp/hello", "query": {}, "body": None},
            )
            expect(Handler.login_authorization == f"Bearer {token}", "login hello used wrong token")
            saved = json.loads((Path(home) / ".hypertask" / "config.json").read_text())
            expect(saved["token"] == token and saved["apiUrl"] == api_url, saved)
            human_login = run(binary, token, api_url, home, "login", "--human")
            expect(human_login.returncode == 0 and human_login.stderr == "", human_login)
            expect(human_login.stdout == (
                "Signed in as Claude Code (agent of Maria Lopez)\n"
                "Board: Product Launch\nhttps://app.hypertask.ai/project?id=9142\n\n"
                "Next steps your agent can run now:\n"
                "  1. See the board:          hypertask task list --project 9142\n"
                '  2. Create a first task:    hypertask task create --project 9142 --title "My first task"\n'
                "  3. Read the board rules:   hypertask project playbook 9142\n\n"
                'Or just ask your agent: "What\'s on my Hypertask board?"\n'
            ), human_login.stdout)
            for status, body in ((500, '{}'), (200, 'not JSON'), (200, 'null'), (200, '{"success":false,"user":{"email":"m@example.com"},"boards":[]}')):
                Handler.login_status, Handler.login_body = status, body
                for mode in ((), ("--human",)):
                    fallback = run(binary, token, api_url, home, "login", *mode)
                    expect(fallback.returncode == 0 and fallback.stderr == "", fallback)
                    expected = (
                        "success: true\nsaved: true\nconfigPath: ~/.hypertask/config.json\n" if mode else
                        '{"success":true,"saved":true,"configPath":"~/.hypertask/config.json"}\n'
                    )
                    expect(fallback.stdout == expected, fallback.stdout)
                    expect(json.loads((Path(home) / ".hypertask" / "config.json").read_text())["token"] == token, "login token not saved")

            # A refused connection must not undo a successful local token save.
            offline = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            offline_url = f"http://127.0.0.1:{offline.server_port}"
            offline.server_close()
            for mode in ((), ("--human",)):
                fallback = run(binary, token, offline_url, home, "login", *mode)
                expect(fallback.returncode == 0 and fallback.stderr == "", fallback)
                expect(fallback.stdout == (
                    "success: true\nsaved: true\nconfigPath: ~/.hypertask/config.json\n" if mode else
                    '{"success":true,"saved":true,"configPath":"~/.hypertask/config.json"}\n'
                ), fallback.stdout)
                expect(json.loads((Path(home) / ".hypertask" / "config.json").read_text())["token"] == token, "offline login token not saved")

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

            expect_command(
                binary, token, api_url, home,
                ("search", "HTPR-5783", "--project", "15"),
                "search-empty.json", 0,
                {
                    "method": "GET",
                    "path": "/mcp/tasks/search",
                    "query": {
                        "q": ["HTPR-5783"],
                        "limit": ["10"],
                        "project_id": ["15"],
                    },
                    "body": None,
                },
            )

            expect_command(
                binary, token, api_url, home,
                ("search", "search", "--project", "15", "--limit", "1", "--fields", "title"),
                "search-projected.json", 0,
                {
                    "method": "GET",
                    "path": "/mcp/tasks/search",
                    "query": {
                        "q": ["search"],
                        "project_id": ["15"],
                        "fields": ["title"],
                        "limit": ["1"],
                    },
                    "body": None,
                },
            )

            projected_human = run(
                binary, token, api_url, home,
                "search", "search", "--fields", "title", "--human",
            )
            expect(projected_human.returncode == 0, projected_human.stderr)
            expect(projected_human.stderr == "", projected_human.stderr)
            expect(projected_human.stdout == (
                "success: true\ntasks:\n  title\n  Search\ntotal: 1\nboardId: 15\nnextCursor: 32507\n"
            ), projected_human.stdout)

            missing = run(binary, token, api_url, home, "tasks", "get", "HTPR-404")
            expect(missing.returncode == 4, f"not-found exit was {missing.returncode}")
            expect(missing.stderr == (
                "hypertask: the requested item was not found\n"
                "Next: check the requested identifier and retry.\n"
            ), f"not-found guidance was {missing.stderr!r}")
            expect(json.loads(missing.stdout)["error"] == "Task not found", missing.stdout)

            with Handler.lock:
                before = len(Handler.requests)
            bad_section = run(
                binary, token, api_url, home,
                "task", "move", "HTPR-5787", "--section", "Totally Not A Section",
            )
            expect(bad_section.returncode == 4, f"bad section exit was {bad_section.returncode}")
            expect(bad_section.stdout == "", f"bad section wrote stdout: {bad_section.stdout!r}")
            expect(bad_section.stderr == (
                "section not found: Totally Not A Section\n"
                "sections may only contain: Bugs, In Progress, Done\n"
                "Next: retry with one of the sections listed above.\n"
            ), f"bad section stderr was {bad_section.stderr!r}")
            with Handler.lock:
                requests = Handler.requests[before:]
            expect([request["path"] for request in requests] == [
                "/mcp/tasks", "/mcp/projects/15/sections",
            ], f"bad section requests were {requests}")

            # HTPR-6813: --to <project> is a cross-board move, not a section on
            # the current board. One request to the move endpoint, exit 0.
            with Handler.lock:
                before = len(Handler.requests)
            cross_board = run(
                binary, token, api_url, home,
                "task", "move", "49511", "--to", "339", "--to-section", "1176",
            )
            expect(cross_board.returncode == 0, f"cross-board move exit was {cross_board.returncode}: {cross_board.stderr!r}")
            expect(json.loads(cross_board.stdout)["task"]["projectId"] == 339, cross_board.stdout)
            with Handler.lock:
                requests = Handler.requests[before:]
            expect([(r["method"], r["path"], r["body"]) for r in requests] == [
                ("POST", "/mcp/tasks/move", {"task_id": 49511, "target_project_id": 339, "target_section_id": 1176}),
            ], f"cross-board move requests were {requests}")

            # HTPR-7723: resolve to numeric ids, never confuse a user with an agent,
            # and send explicit null when clearing the blocked-by person.
            saved_hello = Handler.login_status, Handler.login_body
            Handler.login_status = 200
            Handler.login_body = '{"user":{"id":6},"agent":{"id":"agent-test"}}'
            try:
                for root, user, expected_user in (("task", "6", 6), ("tasks", "me", 6), ("tasks", "none", None)):
                    for mode in ((), ("--human",)):
                        with Handler.lock:
                            before = len(Handler.requests)
                        waiting = run(
                            binary, token, api_url, home,
                            root, "waiting-on", "HTPR-5787", "--user", user, *mode,
                        )
                        expect(waiting.returncode == 0 and waiting.stderr == "", waiting)
                        expect(waiting.stdout == (
                            "success: true\n" if mode else '{"success":true}\n'
                        ), waiting.stdout)
                        with Handler.lock:
                            requests = Handler.requests[before:]
                        expected_reads = [
                            ("GET", "/mcp/hello", {}, None),
                        ] if user == "me" else []
                        expect([(r["method"], r["path"], r["query"], r["body"]) for r in requests] == [
                            *expected_reads,
                            ("GET", "/mcp/tasks", {"ticket_number": ["HTPR-5787"]}, None),
                            ("POST", "/mcp/tasks/waiting-on", {}, {"taskId": 35007, "userId": expected_user, **({"blockerCommentId": None} if expected_user is None else {})}),
                        ], f"waiting-on requests were {requests}")
            finally:
                Handler.login_status, Handler.login_body = saved_hello

            with Handler.lock:
                before = len(Handler.requests)
            for options in ((), ("--user", "invalid"), ("--user", "0")):
                invalid_waiting = run(
                    binary, token, api_url, home,
                    "task", "waiting-on", "HTPR-5787", *options,
                )
                expect(invalid_waiting.returncode == 2, invalid_waiting)
                expect(invalid_waiting.stdout == "", invalid_waiting.stdout)
                expect("Next:" in invalid_waiting.stderr, invalid_waiting.stderr)
            with Handler.lock:
                expect(len(Handler.requests) == before, "invalid waiting-on made network requests")

            for root, comment, expected_comment in (("task", "101", 101), ("tasks", "none", None)):
                for mode in ((), ("--human",)):
                    with Handler.lock:
                        before = len(Handler.requests)
                    marked = run(binary, token, api_url, home, root, "blocker-comment", "HTPR-5787", "--comment-id", comment, *mode)
                    expect(marked.returncode == 0 and marked.stderr == "", marked)
                    expect(marked.stdout == ("success: true\n" if mode else '{"success":true}\n'), marked.stdout)
                    with Handler.lock:
                        requests = Handler.requests[before:]
                    expect([(r["method"], r["path"], r["query"], r["body"]) for r in requests] == [
                        ("GET", "/mcp/tasks", {"ticket_number": ["HTPR-5787"]}, None),
                        ("POST", "/mcp/tasks/waiting-on", {}, {"taskId": 35007, "blockerCommentId": expected_comment}),
                    ], f"blocker-comment requests were {requests}")

            with Handler.lock:
                before = len(Handler.requests)
            for value in ("invalid", "0", "-1"):
                refused = run(binary, token, api_url, home, "task", "blocker-comment", "HTPR-5787", "--comment-id", value)
                expect(refused.returncode == 2 and refused.stdout == "", refused)
            with Handler.lock:
                expect(len(Handler.requests) == before, "invalid blocker-comment made network requests")

            # HTPR-6313: an agent command run without any agent identity must
            # fail loudly, non-zero exit, error on stderr, nothing on stdout,
            # no network call, so a caller checking $? never sees success.
            identity_args = ("agent", "new-tickets", "--project", "4874"), ("agent", "poll", "--project", "4874")
            with Handler.lock:
                before = len(Handler.requests)
            for args in identity_args:
                result = run(binary, token, api_url, home, *args, strip_identity=True)
                expect(result.returncode != 0, f"{' '.join(args)} exited 0 without agent identity")
                expect(result.stdout == "", f"{' '.join(args)} printed to stdout: {result.stdout!r}")
                expect(result.stderr == (
                    "hypertask: required command input is missing\n"
                    "Next: pass --agent-id or set HT_AGENT_ID, then retry.\n"
                ), f"{' '.join(args)} identity guidance was {result.stderr!r}")
            with Handler.lock:
                expect(len(Handler.requests) == before, "identity error made network requests")

            expect_command(
                binary, token, api_url, home,
                ("task", "assign", "HTPR-5787", "--self"),
                "task-assign-self.json", 0,
                {
                    "method": "POST",
                    "path": "/mcp/assignees/assign",
                    "query": {},
                    "body": {
                        "ticket_number": "HTPR-5787",
                        "assign_self": True,
                        "intent": "assign",
                    },
                },
            )
            expect_command(
                binary, token, api_url, home,
                ("tasks", "get", "HTPR-5787", "--project", "15"),
                "task-get.json", 0,
                {
                    "method": "GET",
                    "path": "/mcp/tasks",
                    "query": {"ticket_number": ["HTPR-5787"], "project_id": ["15"]},
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
                ("comment", "react", "216402", "--emoji", "✅"),
                "comment-react.json", 0,
                {
                    "method": "POST",
                    "path": "/mcp/comments/216402/reactions",
                    "query": {},
                    "body": {"emoji": "✅", "active": True},
                },
            )
            expect_command(
                binary, token, api_url, home,
                ("comment", "unreact", "404", "--emoji", "✅"),
                "comment-reaction-not-found.json", 4,
                {
                    "method": "POST",
                    "path": "/mcp/comments/404/reactions",
                    "query": {},
                    "body": {"emoji": "✅", "active": False},
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
            pagination = ThreadingHTTPServer(("127.0.0.1", 0), PaginationHandler)
            pagination_thread = threading.Thread(target=pagination.serve_forever, daemon=True)
            pagination_thread.start()
            pagination_url = f"http://127.0.0.1:{pagination.server_port}"
            try:
                for offset in PaginationHandler.pages:
                    page = run(
                        binary, token, pagination_url, home,
                        "tasks", "list", "--project", "339", "--offset", offset, "--limit", "100",
                    )
                    if offset in ("0", "400"):
                        expect(page.returncode == 0, f"offset {offset}: {page.stderr}")
                        expect(
                            page.stdout == PaginationHandler.pages[offset].decode() + "\n",
                            f"offset {offset} changed the valid JSON page",
                        )
                        json.loads(page.stdout)
                    else:
                        expect(page.returncode == 4, (
                            f"offset {offset} exited {page.returncode}, expected invalid response 4\n"
                            f"stdout: {page.stdout!r}\nstderr: {page.stderr}"
                        ))
                        expect(page.stdout == "", f"offset {offset} leaked invalid JSON")
                        expect("response the CLI could not use" in page.stderr, page.stderr)
                        expect("Next:" in page.stderr, page.stderr)
            finally:
                pagination.shutdown()
                pagination.server_close()
                pagination_thread.join()

            transport = ThreadingHTTPServer(("127.0.0.1", 0), TransportFailureHandler)
            transport_thread = threading.Thread(target=transport.serve_forever, daemon=True)
            transport_thread.start()
            transport_url = f"http://127.0.0.1:{transport.server_port}"
            try:
                expect_transport_failure(
                    binary, token, transport_url, home, "/trunc", ("HttpRequestTruncated",)
                )
                expect_transport_failure(
                    binary, token, transport_url, home, "/reset",
                    ("HttpTransferFailed", "HttpRequestTruncated"),
                )
            finally:
                transport.shutdown()
                transport.server_close()
                transport_thread.join()
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    print("golden-file HTTP stub tests passed")


if __name__ == "__main__":
    main()
