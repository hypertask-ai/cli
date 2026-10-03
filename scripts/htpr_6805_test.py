#!/usr/bin/env python3
"""Offline refactor proof: baseline bytes, connection reuse, and frozen Node parity."""

import argparse
import base64
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
BASELINE_REV = "85ad1a08ed65597157218d3789b0485296b491cb"
CLI = ROOT / "zig-out/bin/hypertask"
BASELINE = ROOT / "zig-out/bin/hypertask-6805-baseline"
NODE = ROOT / ".zig-cache/node-reference/node_modules/.bin/hypertask"


def source(path):
    return (ROOT / path).read_text()


def assert_absent(pattern, contents):
    assert re.search(pattern, contents, re.M) is None, pattern


def structure(kind):
    accessors = r"^(?:pub )?fn (?:stringField|integerField|objectField|jsonInteger\w*|arrayField)\("
    success = r"(?:\b\w+|@intFromEnum\([^\n]+\))\s*(?:<|>=)\s*(?:200|300)\b|\.status\.class\(\)\s*[!=]=\s*\.success"
    # Positive controls ensure both negative source checks can actually fail.
    for pattern, fixture in [(accessors, "fn stringField("), (success, "code < 200 or code >= 300")]:
        try:
            assert_absent(pattern, fixture)
        except AssertionError:
            pass
        else:
            raise AssertionError("negative checker missed its positive control")
    if kind == "json":
        for path in (ROOT / "src/commands").glob("*.zig"):
            assert_absent(accessors, path.read_text())
        assert_absent(accessors, source("src/resolve.zig"))
        utility = source("src/json_util.zig")
        for name in ["stringField", "integerField", "objectField", "arrayField"]:
            assert len(re.findall(r"pub fn " + name + r"\(", utility)) == 1
        assert "if (value != .object) return null;" in utility
        assert "string_fallback" in utility
        assert "appendRawField" not in utility
        assert "try self.key(name);" in utility.split("pub fn raw(")[1].split("\n    }")[0]
    elif kind == "http":
        for path in (ROOT / "src").rglob("*.zig"):
            if path.name != "http.zig":
                assert_absent(success, path.read_text())
        assert "pub fn isSuccess(" in source("src/http.zig")
        dev = source("src/commands/agent_dev.zig")
        assert dev.count("try requireSuccess(context, &response);") == 2
    elif kind == "reuse":
        assert "simpleProjectGet" not in source("src/commands/project.zig")
        task = source("src/commands/task.zig")
        assert task.count("try applyCommonFields(") == 2
        resolver = source("src/resolve.zig")
        assert resolver.count("fn addTaskIdentifier(sink:") == 1
        assert resolver.count("return addTaskIdentifier(.{") == 2
        assert "pub fn requireDeleteConfirmation(" in source("src/command_context.zig")
        for name in ["agents", "report", "decision", "webhook"]:
            contents = source(f"src/commands/{name}.zig")
            assert "common.requireDeleteConfirmation(" in contents
            assert_absent(r"fn requireDeleteConfirmation\(", contents)
            assert_absent(r"if .*has\(\"confirm\"\).*return error.ConfirmationRequired", contents)
        config = source("src/config.zig").split("pub fn saveToken(")[1].split("\n}")[0]
        assert "load(" not in config and "existing: *const Config" in config
        output = source("src/output.zig")
        assert "return errorInfo(err).code;" in output
        assert "const summary = errorInfo(err).summary;" in output
        assert "const error_info = [_]ErrorInfo{" in output
        original = subprocess.check_output(["git", "show", f"{BASELINE_REV}:src/output.zig"], cwd=ROOT).decode()
        def switch_entries(contents):
            entries = {}
            for errors, value in re.findall(r'((?:\s*error\.\w+\s*,?)+)\s*=>\s*("[^"\n]*"|\d+)', contents):
                for error in re.findall(r"error\.\w+", errors):
                    entries[error] = value
            return entries
        codes = switch_entries(original.split("pub fn exitCode(")[1].split("pub fn printFailure(")[0])
        summaries = switch_entries(original.split("const summary:")[1].split("if (summary)")[0])
        expected = {error: (codes.get(error, "1"), summaries.get(error)) for error in codes.keys() | summaries.keys()}
        actual = {}
        for error, code, summary in re.findall(r'\.err = (error\.\w+), \.code = (\d+)(?:, \.summary = ("[^"\n]*"))?', output):
            actual[error] = (code, summary or None)
        assert actual == expected, "error classification drift"
    elif kind == "split":
        agent = source("src/commands/agent.zig")
        store = source("src/state_store.zig")
        html = source("src/html_util.zig")
        for name in ["acquireFileLock", "readLines", "writeStateFile", "compactTicketState"]:
            assert_absent(r"fn " + name + r"\(", agent)
            assert "fn " + name + "(" in store
        assert "readOptionalFile(" in store
        assert "state_store.readOptionalFile(" in agent
        assert_absent(r"fn (?:addressesAgent|attributeValue)\(", agent)
        assert "html_util.addressesAgent(" in agent
        assert "fn attributeValue(" in html
        assert "try migrateLegacyState(context, state);" in agent
        original = subprocess.check_output(["git", "show", f"{BASELINE_REV}:src/commands/agent.zig"], cwd=ROOT).decode()
        for name in ["addressesAgent", "attributeValue"]:
            pattern = r"fn " + name + r"\([^\n]*\n[\s\S]*?\n}"
            assert re.search(pattern, original).group() == re.search(pattern, html).group()
    print(f"{kind} structure verified")


def token():
    payload = base64.urlsafe_b64encode(b'{"agentId":"fixture-agent"}').decode().rstrip("=")
    return f"e30.{payload}.signature"


def environment(home, api):
    env = {key: value for key, value in os.environ.items() if not key.startswith(("HT_", "HYPERTASK", "WEBHOOK_SECRET"))}
    env.update(HOME=str(home), USERPROFILE=str(home), XDG_CONFIG_HOME=str(home / ".config"),
               XDG_CACHE_HOME=str(home / ".cache"), HT_TOKEN=token(), HYPERTASKS_JWT_TOKEN=token(),
               HYPERTASKS_API_URL=api, HT_AGENT_ID="fixture-agent", HT_AGENT_NAME="Fixture Agent")
    return env


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.records = []
        self.lock = threading.Lock()
        self.mode = "normal"
        self.barrier = None
        self.concurrent = 0
        self.max_concurrent = 0

    def reset(self, mode="normal", parallel=False):
        with self.lock:
            self.records = []
            self.mode = mode
            self.barrier = threading.Barrier(4) if parallel else None
            self.concurrent = self.max_concurrent = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def respond(self, body, status=200):
        raw = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_PATCH(self):
        self.handle_request()

    def do_PUT(self):
        self.handle_request()

    def do_DELETE(self):
        self.handle_request()

    def handle_request(self):
        parsed = urlsplit(self.path)
        path, query = parsed.path, parse_qs(parsed.query, keep_blank_values=True)
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw) if raw else None
        with self.server.lock:
            self.server.records.append((self.command, path, query, body, self.client_address[1], raw))
        mode = self.server.mode
        if mode.startswith("status-"):
            code = int(mode.split("-")[1])
            self.respond({"success": False, "error": "fixture rejection"}, code)
            return
        if mode == "api-failure":
            self.respond({"success": False, "error": "fixture failure"})
            return
        labels = [{"id": "11111111-2222-4333-8444-555555555555", "name": "CLI"}]
        project = {"id": 15, "title": "Fixture board", "labels": labels}
        task = {"id": 501, "projectId": 15, "ticketNumber": "HTPR-5783", "uniqueIndex": 5783,
                "title": "Fixture task", "description": "<p>Full description</p>", "section": "In Progress",
                "updatedAt": "2026-09-01T12:00:00.000Z", "assignees": [], "labels": labels}
        if self.command != "GET":
            if path == "/mcp/comments":
                self.respond({"success": True, "comment": {"id": 101, "text": body["text"]}})
            elif path == "/mcp/ai/task-writer":
                self.respond({"success": True, "mode": body["mode"], "html": "<p>Generated</p>", "priority": 2, "estimate": 3})
            elif path == "/mcp/ai/improve":
                self.respond({"success": True, "html": "<p>Improved</p>"})
            elif path.startswith("/mcp/tasks/"):
                self.respond({"success": True, "task": task, "request": body})
            else:
                self.respond({"success": True})
            return
        if path == "/mcp/tasks/search":
            if mode == "search-empty":
                rows = []
            elif mode == "search-full":
                rows = [task]
            else:
                rows = [{**task, "id": index, "ticketNumber": f"HTPR-{index}", "uniqueIndex": index,
                         "description": ""} for index in range(1, 11)]
                if mode == "search-mixed":
                    rows[0]["description"] = "<p>Already present</p>"
                    rows[4]["description"] = "<p>Already present</p>"
                if mode == "search-malformed":
                    rows[2] = {"description": "", "id": "invalid"}
            self.respond({"success": True, "tasks": rows, "total": len(rows), "limit": 10, "offset": 0})
        elif path == "/mcp/tasks":
            if "task_id" in query:
                id_value = int(query["task_id"][0])
                if self.server.barrier and 1 <= id_value <= 4:
                    with self.server.lock:
                        self.server.concurrent += 1
                        self.server.max_concurrent = max(self.server.max_concurrent, self.server.concurrent)
                    try:
                        self.server.barrier.wait(timeout=5)
                    finally:
                        with self.server.lock:
                            self.server.concurrent -= 1
                if mode == "search-detail-failure" and id_value in (2, 3):
                    self.respond({"success": False, "error": f"detail {id_value} failed"}, 404 if id_value == 2 else 500)
                    return
                if mode == "search-detail-api-failure" and id_value == 2:
                    self.respond({"success": False, "error": "detail 2 failed"})
                    return
                if id_value <= 10:
                    task.update(id=id_value, ticketNumber=f"HTPR-{id_value}", uniqueIndex=id_value)
            metadata = {} if any(key in query for key in ["task_id", "ticket_number", "unique_index"]) else {"total": 1, "limit": 10, "offset": 0, "nextCursor": None}
            self.respond({"success": True, "tasks": [task], **metadata})
        elif path == "/mcp/projects":
            rows = [] if mode == "project-101" else [project]
            self.respond({"success": True, "projects": rows, "total": len(rows)})
        elif path.endswith("/labels"):
            self.respond({"success": True, "labels": labels})
        elif path.endswith("/sections"):
            self.respond({"success": True, "sections": [{"id": 2, "section_title": "In Progress"}, {"id": 3, "section_title": "Done"}]})
        elif path == "/mcp/comments":
            self.respond({"success": True, "comments": [
                {"id": "100", "text": '<span data-type="mention" data-label="agent-fixture-agent">@Fixture</span>', "creator": {"displayName": "Author"}},
                {"id": 101, "text": "<p>Our comment</p>", "agent": {"id": "fixture-agent"}, "reactions": [{"id": "7", "emoji": ":)"}]},
            ], "total": 2, "limit": 10, "offset": 0})
        elif path == "/mcp/user/context":
            self.respond({"success": True, "user": {"id": 6, "displayName": "Fixture"}, "teams": [{"id": 1, "name": "Fixture"}]})
        elif path == "/mcp/inbox/list":
            self.respond({"success": True, "user_notifications": [], "agent_notifications": []})
        elif path == "/mcp/time/report":
            self.respond({"success": True, "entries": [{"id": 1, "seconds": 600, "endedAt": "2026-09-01T12:00:00.000Z"}]})
        elif path == "/mcp/tasks/tree":
            self.respond({"success": True, "task": task, "children": []})
        else:
            key = {"/mcp/tasks/relations": "relations", "/mcp/tasks/related": "tasks",
                   "/mcp/reports": "reports", "/mcp/report": "reports", "/mcp/pages": "pages",
                   "/mcp/skills": "skills", "/mcp/views": "views", "/mcp/view": "views", "/mcp/time/running": "entries"}.get(path)
            self.respond({"success": True, **({key: []} if key else {})})


@contextmanager
def fixture_server():
    server = Server()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def baseline():
    if BASELINE.is_file():
        return
    directory = ROOT / ".zig-cache/htpr6805-baseline"
    directory.mkdir(parents=True, exist_ok=True)
    names = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", BASELINE_REV], cwd=ROOT).decode().splitlines()
    for name in names:
        if name.startswith("src/") or name in ("build.zig", "build.zig.zon"):
            destination = directory / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(subprocess.check_output(["git", "show", f"{BASELINE_REV}:{name}"], cwd=ROOT))
    subprocess.run(["zig", "build", "--prefix", str(ROOT / "zig-out/htpr6805-baseline")], cwd=directory, check=True)
    BASELINE.write_bytes((ROOT / "zig-out/htpr6805-baseline/bin/hypertask").read_bytes())
    BASELINE.chmod(0o755)


def run(binary, args, home, api):
    return subprocess.run([str(binary), *args], env=environment(home, api), cwd=ROOT,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)


def compare(server, api, args, mode="normal", repeat=False):
    with tempfile.TemporaryDirectory(dir=ROOT / ".zig-cache", prefix="htpr6805-") as directory:
        home = Path(directory)
        results, states, requests = [], [], []
        for binary in (BASELINE, CLI):
            state = home / "state"
            state.mkdir()
            command = [*args, "--state-dir", str(state)] if args[:2] == ["agent", "poll"] else args
            server.reset(mode)
            process = run(binary, command, home, api)
            if repeat:
                second = run(binary, command, home, api)
                assert second.returncode == 0 and second.stdout == b"", "poll must not re-emit seen events"
            results.append((process.returncode, process.stdout, process.stderr))
            states.append({p.name: sorted(p.read_text().splitlines()) for p in state.iterdir() if not p.name.endswith(".lock")})
            requests.append([(r[0], r[1], r[5]) for r in server.records if r[0] != "GET"])
            for path in state.iterdir():
                path.unlink()
            state.rmdir()
        assert results[0] == results[1], f"byte mismatch: {' '.join(args)} ({mode})"
        assert states[0] == states[1], "poll state mismatch"
        assert requests[0] == requests[1], "mutation request bytes changed"
        return results[0][0]


def smoke():
    baseline()
    cases = [
        (["tasks", "get", "HTPR-5783"], "normal"),
        (["tasks", "get", "id:501"], "normal"),
        (["tasks", "get", "501", "--project", "15"], "normal"),
        (["tasks", "update", "HTPR-5783", "--section", "In Progress", "--labels", "CLI"], "normal"),
        (["tasks", "update", "501", "--project", "15", "--section", "Done", "--labels", "CLI"], "normal"),
        (["tasks", "update", "HTPR-5783", "--title", "Updated", "--description", "plain text", "--priority", "high", "--estimate", "3", "--due", "2026-12-01", "--status", "Normal", "--parent-task", "HTPR-5783", "--assignee", "6"], "normal"),
        (["tasks", "update", "HTPR-5783", "--clear-due", "--clear-parent", "--description", "raw", "--markdown"], "normal"),
        (["tasks", "create", "--project", "15", "--title", "Created", "--description", "plain", "--section", "Done", "--labels", "CLI", "--priority", "low", "--estimate", "5", "--due", "2026-12-01", "--parent-task", "HTPR-5783", "--assignee", "6"], "normal"),
        (["comment", "add", "HTPR-5783", "--text", "plain text"], "normal"),
        (["comment", "add", "id:501", "--text", "**markdown**", "--markdown"], "normal"),
        (["agent", "poll", "--project", "15"], "normal"),
        (["ai", "write", "prompt", "--task", "HTPR-5783", "--apply"], "normal"),
        (["time", "log", "HTPR-5783", "-2"], "normal"),
    ]
    for mode in ["normal", "search-empty", "search-full", "search-mixed", "search-malformed", "search-detail-failure", "search-detail-api-failure"]:
        cases.append((["tasks", "search", "fixture"], mode))
    for status in [200, 299, 300, 400, 401, 403, 404, 422, 500]:
        for command in [["tasks", "get", "HTPR-5783"], ["comment", "add", "HTPR-5783", "--text", "<p>Test</p>"], ["tasks", "search", "fixture"]]:
            cases.append((command, f"status-{status}"))
    for command in [["project", "manifest", "15"], ["tasks", "get"], ["tasks", "update", "invalid", "--priority", "high"], ["report", "delete", "1"], ["decision", "delete", "1"], ["webhook", "delete", "1"], ["agents", "delete", "1"]]:
        cases.append((command, "normal"))
    with fixture_server() as (server, api):
        for args, mode in cases:
            for human in [False, True]:
                compare(server, api, [*args, "--human" if human else "--json"], mode, repeat=args[:2] == ["agent", "poll"])
        # Exercise every catalogue leaf's help output, including aliases handled by the router.
        catalog = json.loads(source("src/capabilities.json"))
        def leaves(commands, parents=()):
            for command in commands:
                path = (*parents, command["name"])
                if command.get("commands"):
                    yield from leaves(command["commands"], path)
                else:
                    yield list(path)
        paths = list(leaves(catalog["commands"]))
        for path in paths:
            compare(server, api, [*path, "--help"])
    print(f"byte-identical smoke verification passed ({len(cases) * 2} response cases, {len(paths)} leaf help cases)")


def network():
    baseline()
    with fixture_server() as (server, api), tempfile.TemporaryDirectory(dir=ROOT / ".zig-cache", prefix="htpr6805-network-") as directory:
        home = Path(directory)
        command = ["tasks", "update", "HTPR-5783", "--section", "In Progress", "--labels", "CLI", "--json"]
        counts, connections = [], []
        for binary in (BASELINE, CLI):
            server.reset()
            process = run(binary, command, home, api)
            assert process.returncode == 0, process.stderr
            counts.append(sum(r[1] == "/mcp/tasks" for r in server.records))
            connections.append(len({r[4] for r in server.records}))
            if binary == CLI:
                assert any(r[1] == "/mcp/projects/15/labels" for r in server.records)
                assert not any(r[1] == "/mcp/projects" for r in server.records)
        assert counts == [2, 1], counts
        assert connections[0] > connections[1] == 1, connections
        server.reset("project-101")
        process = run(CLI, ["tasks", "create", "--project", "101", "--title", "Test", "--labels", "CLI"], home, api)
        assert process.returncode == 0, process.stderr
        assert any(r[1] == "/mcp/projects/101/labels" for r in server.records)
        server.reset(parallel=True)
        process = run(CLI, ["tasks", "search", "fixture", "--json"], home, api)
        assert process.returncode == 0, process.stderr
        assert server.max_concurrent == 4, server.max_concurrent
        assert sum(r[1] == "/mcp/tasks" for r in server.records) == 10
        assert len({r[4] for r in server.records}) <= 4
        # Login persistence keeps the already-loaded management metadata.
        saved = home / ".hypertask/config.json"
        saved.parent.mkdir(exist_ok=True)
        saved.write_text(json.dumps({"token": "saved-fixture", "managementKey": "saved-management", "apiUrl": api}))
        process = run(CLI, ["login", "--token", "login-fixture"], home, api)
        assert process.returncode == 0, process.stderr
        assert json.loads(saved.read_text())["managementKey"] == "saved-management"
    print(f"network verification passed (task lookups {counts[0]} -> {counts[1]}, connections {connections[0]} -> {connections[1]}, 4 parallel detail reads)")


def parity():
    assert NODE.is_file(), "Install @hypertask/hypertask_cli@2.0.6 into .zig-cache/node-reference"
    with fixture_server() as (_, api), tempfile.TemporaryDirectory(dir=ROOT / ".zig-cache", prefix="htpr6805-parity-") as directory:
        env = environment(Path(directory), api)
        env["HYPERTASK_NODE_BIN"] = str(NODE)
        env["TMPDIR"] = directory
        process = subprocess.run(["python3", "scripts/parity_test.py"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=180)
        print(process.stdout, end="")
        print(process.stderr, end="")
        assert process.returncode == 0, "read-only fixture parity failed"
        print("read-only parity passed (isolated API fixtures, no board writes)")


def hygiene():
    diff = subprocess.check_output(["git", "diff", BASELINE_REV, "--", "src", "scripts/htpr_6805_test.py", "GATES.md"], cwd=ROOT).decode()
    for line in diff.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            assert "\u2014" not in line, "added em dash"
    for name in ["src/state_store.zig", "src/html_util.zig", "scripts/htpr_6805_test.py"]:
        assert "\u2014" not in source(name)
    names = subprocess.check_output(["git", "diff", BASELINE_REV, "--name-only", "--", "src"], cwd=ROOT).decode().splitlines()
    names += ["src/state_store.zig", "src/html_util.zig"]
    subprocess.run(["zig", "fmt", "--check", *sorted(set(names))], cwd=ROOT, check=True)
    subprocess.run(["git", "diff", "--check"], cwd=ROOT, check=True)
    assert subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT).decode().strip() == "htpr-6805"
    print("hygiene verification passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--structure", choices=["json", "http", "reuse", "split"])
    for name in ["network", "smoke", "parity", "hygiene"]:
        modes.add_argument("--" + name, action="store_true")
    options = parser.parse_args()
    if options.structure:
        structure(options.structure)
    elif options.network:
        network()
    elif options.smoke:
        smoke()
    elif options.parity:
        parity()
    else:
        hygiene()
